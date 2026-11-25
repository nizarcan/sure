require "test_helper"

class CustomInstrument::PriceSeriesTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "carries the last observation before the window and between prices forward" do
    stock = Security.create!(ticker: "CARRY", exchange_operating_mic: "XNAS")
    start_date = 20.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date - 5, price: 10, currency: "USD")
    Security::Price.create!(security: stock, date: start_date + 2, price: 20, currency: "USD")

    instrument = create_custom_instrument(family: @family, symbol: "CARRYI", formula: "1 * [CARRY]")
    rows = CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date + 4)

    assert_equal [ 10, 10, 20, 20, 20 ], rows.map { |row| row[:price].to_i }
    assert_equal (start_date..start_date + 4).to_a, rows.map { |row| row[:date] }
    assert rows.none? { |row| row[:provisional] }
  end

  test "marks recent carried prices provisional but not a price on its own date" do
    stock = Security.create!(ticker: "PROV", exchange_operating_mic: "XNAS")
    start_date = Date.current - 3
    Security::Price.create!(security: stock, date: start_date - 2, price: 10, currency: "USD")
    Security::Price.create!(security: stock, date: start_date + 1, price: 20, currency: "USD")

    instrument = create_custom_instrument(family: @family, symbol: "PROVI", formula: "1 * [PROV]")
    rows = CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date + 1)

    assert_equal [ true, false ], rows.map { |row| row[:provisional] }
  end

  test "converts each price row in its own currency using a rate carried forward" do
    stock = Security.create!(ticker: "FOREIGN", exchange_operating_mic: "XNAS")
    start_date = 15.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 100, currency: "EUR")
    Security::Price.create!(security: stock, date: start_date + 2, price: 200, currency: "GBP")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: start_date, rate: 1.5)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: start_date, rate: 2)

    instrument = create_custom_instrument(family: @family, symbol: "FOREIGNI", formula: "1 * [FOREIGN]")
    rows = CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date + 3)

    assert_equal [ 150, 150, 400, 400 ], rows.map { |row| row[:price].to_i }
  end

  test "a price with no usable rate on or before its date gives no observation" do
    stock = Security.create!(ticker: "NOFX", exchange_operating_mic: "XNAS")
    start_date = 10.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 100, currency: "GBP")
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: start_date + 2, rate: 2)

    instrument = create_custom_instrument(family: @family, symbol: "NOFXI", formula: "1 * [NOFX]")

    assert_empty CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date + 4)
  end

  test "skips dates whose total is not positive" do
    stock = Security.create!(ticker: "NEG", exchange_operating_mic: "XNAS")
    start_date = 10.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 10, currency: "USD")

    instrument = create_custom_instrument(family: @family, symbol: "NEGI", formula: "-1 * [NEG]")

    assert_empty CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date + 2)
  end

  test "a same-currency component is constant and never provisional" do
    instrument = create_custom_instrument(family: @family, symbol: "CONST", formula: "1 * USD")
    start_date = Date.current - 2
    rows = CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date + 2)

    assert_equal [ 1, 1, 1 ], rows.map { |row| row[:price].to_i }
    assert rows.none? { |row| row[:provisional] }
  end

  test "returns nothing when a component has no observations at all" do
    Security.create!(ticker: "EMPTY", exchange_operating_mic: "XNAS")
    instrument = create_custom_instrument(family: @family, symbol: "EMPTYI", formula: "1 * [EMPTY]")

    assert_empty CustomInstrument::PriceSeries.new(instrument).calculate(10.days.ago.to_date, Date.current)
  end

  test "rounds to four places and skips prices that round to zero" do
    stock = Security.create!(ticker: "ROUND", exchange_operating_mic: "XNAS")
    start_date = 10.days.ago.to_date
    Security::Price.create!(security: stock, date: start_date, price: 0.12345, currency: "USD")

    instrument = create_custom_instrument(family: @family, symbol: "ROUNDI", formula: "1 * [ROUND]")
    rows = CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date)

    assert_equal BigDecimal("0.1235"), rows.first[:price]

    stock.prices.update_all(price: 0.00001)
    assert_empty CustomInstrument::PriceSeries.new(instrument).calculate(start_date, start_date)
  end

  test "picks one price per date, preferring the instrument currency" do
    stock = Security.create!(ticker: "TWOCUR", exchange_operating_mic: "XNAS")
    date = 5.days.ago.to_date
    Security::Price.create!(security: stock, date: date, price: 100, currency: "USD")
    Security::Price.create!(security: stock, date: date, price: 200, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 2)

    instrument = create_custom_instrument(family: @family, symbol: "TWOCURI", formula: "1 * [TWOCUR]")

    assert_equal BigDecimal("100"), CustomInstrument::PriceSeries.new(instrument).calculate(date, date).first[:price]
  end

  test "picks the alphabetically first currency when none is the instrument currency" do
    stock = Security.create!(ticker: "TWOFX", exchange_operating_mic: "XNAS")
    date = 5.days.ago.to_date
    Security::Price.create!(security: stock, date: date, price: 100, currency: "EUR")
    Security::Price.create!(security: stock, date: date, price: 100, currency: "GBP")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.5)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: date, rate: 2)

    instrument = create_custom_instrument(family: @family, symbol: "TWOFXI", formula: "1 * [TWOFX]")

    assert_equal BigDecimal("150"), CustomInstrument::PriceSeries.new(instrument).calculate(date, date).first[:price]
  end
end
