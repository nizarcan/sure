require "test_helper"

class CustomInstrument::PriceImporterTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @family = families(:dylan_family)
    Security.any_instance.stubs(:import_provider_prices).returns([ 0, nil ])
  end

  test "returns the tuple contract and writes the computed series" do
    stock = Security.create!(ticker: "IMPORT", exchange_operating_mic: "XNAS")
    start_date = 5.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 10, currency: "USD")
    Security::Price.create!(security: stock, date: start_date + 2, price: 20, currency: "USD")

    instrument = create_custom_instrument(family: @family, symbol: "IMPORTI", formula: "1 * [IMPORT]")
    count, error = instrument.import_prices(start_date: start_date, end_date: start_date + 2)

    assert_equal 3, count
    assert_nil error
    assert_equal [ 10, 10, 20 ], instrument.security.prices.order(:date).pluck(:price).map(&:to_i)
    assert_equal [ "USD" ], instrument.security.prices.distinct.pluck(:currency)
  end

  test "imports nested instruments before computing the parent" do
    stock = Security.create!(ticker: "NESTED", exchange_operating_mic: "XNAS")
    start_date = 5.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 10, currency: "USD")

    child = create_custom_instrument(family: @family, symbol: "CHILDIN", formula: "1 * [NESTED]")
    parent = create_custom_instrument(family: @family, symbol: "PARENTIN", formula: "1 * CHILDIN")

    count, error = parent.import_prices(start_date: start_date, end_date: start_date)

    assert_equal 1, count
    assert_nil error
    assert_equal BigDecimal("10"), child.security.prices.find_by(date: start_date).price
    assert_equal BigDecimal("10"), parent.security.prices.find_by(date: start_date).price
  end

  test "removes rows in another currency inside the window" do
    stock = Security.create!(ticker: "RECURR", exchange_operating_mic: "XNAS")
    start_date = 3.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 10, currency: "USD")
    instrument = create_custom_instrument(family: @family, symbol: "RECURRI", formula: "1 * [RECURR]")
    Security::Price.create!(security: instrument.security, date: start_date, price: 99, currency: "EUR")

    instrument.import_prices(start_date: start_date, end_date: start_date)

    assert_equal [ "USD" ], instrument.security.prices.distinct.pluck(:currency)
  end

  test "removes dates inside the window the formula no longer produces" do
    stock = Security.create!(ticker: "GAPPY", exchange_operating_mic: "XNAS")
    start_date = 10.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date + 5, price: 10, currency: "USD")
    instrument = create_custom_instrument(family: @family, symbol: "GAPPYI", formula: "1 * [GAPPY]")
    Security::Price.create!(security: instrument.security, date: start_date, price: 99, currency: "USD")

    instrument.import_prices(start_date: start_date, end_date: start_date + 5)

    assert_nil instrument.security.prices.find_by(date: start_date)
    assert_not_nil instrument.security.prices.find_by(date: start_date + 5)
  end

  test "an unpriced component is named in the error" do
    Security.create!(ticker: "NOPRICE", exchange_operating_mic: "XNAS")
    instrument = create_custom_instrument(family: @family, symbol: "NOPRICEI", formula: "1 * [NOPRICE]")

    count, error = instrument.import_prices(start_date: 3.days.ago.to_date, end_date: Date.current)

    assert_equal 0, count
    assert_includes error, "NOPRICE"
  end

  test "imports the rates a foreign price currency needs" do
    stock = Security.create!(ticker: "EURSTOCK", exchange_operating_mic: "XNAS")
    start_date = 3.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 100, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: start_date, rate: 1.5)
    instrument = create_custom_instrument(family: @family, symbol: "EURSTOCKI", formula: "1 * [EURSTOCK]")

    CustomInstrument::RateSource.expects(:import)
                                .with(from: "EUR", to: "USD", start_date: start_date, end_date: start_date, clear_cache: false)
                                .once

    count, error = instrument.import_prices(start_date: start_date, end_date: start_date)

    assert_equal 1, count
    assert_nil error
    assert_equal BigDecimal("150"), instrument.security.prices.find_by(date: start_date).price
  end

  test "captures unexpected import errors and still returns the tuple" do
    instrument = create_custom_instrument(family: @family, symbol: "ERRIMP", formula: "1 * USD")
    CustomInstrument::PriceSeries.any_instance.stubs(:calculate).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.where(category: "custom_instruments", level: "error").count }, 1 do
      count, error = instrument.import_prices(start_date: Date.current, end_date: Date.current)

      assert_equal 0, count
      assert_equal "boom", error
    end

    entry = DebugLogEntry.where(category: "custom_instruments", level: "error").last
    assert_equal @family, entry.family
    assert_equal instrument.id, entry.metadata["custom_instrument_id"]
  end

  test "captures missing component prices as a warning" do
    Security.create!(ticker: "MISSIMP", exchange_operating_mic: "XNAS")
    instrument = create_custom_instrument(family: @family, symbol: "MISSIMPI", formula: "1 * [MISSIMP]")

    assert_difference -> { DebugLogEntry.where(category: "custom_instruments", level: "warn").count }, 1 do
      count, error = instrument.import_prices(start_date: 3.days.ago.to_date, end_date: Date.current)

      assert_equal 0, count
      assert_includes error, "MISSIMP"
    end

    entry = DebugLogEntry.where(category: "custom_instruments", level: "warn").last
    assert_equal @family, entry.family
  end

  test "does not ask a provider for an offline security" do
    offline = Security.create!(ticker: "OFFIMPORT", exchange_operating_mic: "XNAS", offline: true)
    Security::Price.create!(security: offline, date: Date.current, price: 10, currency: "USD")
    instrument = create_custom_instrument(family: @family, symbol: "OFFIMPORTI", formula: "1 * [OFFIMPORT]")

    Security.any_instance.expects(:import_provider_prices).never

    count, error = instrument.import_prices(start_date: Date.current, end_date: Date.current)

    assert_equal 1, count
    assert_nil error
  end
end
