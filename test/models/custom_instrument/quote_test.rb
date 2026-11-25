require "test_helper"

class CustomInstrument::QuoteTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "values a single stock reference with unit price, value, share and inverse" do
    stock = Security.create!(ticker: "QUOTED", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: Date.current, price: 10, currency: "USD")

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "2 * [QUOTED]", currency: "USD")

    assert quote.valid?
    assert_nil quote.error
    assert_equal BigDecimal("20"), quote.price
    line = quote.lines.sole
    assert_equal "QUOTED", line.label
    assert_equal BigDecimal("2"), line.weight
    assert_equal BigDecimal("10"), line.unit_price.amount
    assert_equal BigDecimal("20"), line.value.amount
    assert_equal BigDecimal("100"), line.share
    assert_equal Date.current, line.date
    assert_equal BigDecimal("0.5"), quote.inverse
    assert_equal Date.current, quote.as_of
    assert_not quote.stale?
    assert_empty quote.unpriced
  end

  test "prices currency components through RateSource.current" do
    CustomInstrument::RateSource.expects(:current).with(from: "XAU", to: "USD").returns({ rate: BigDecimal("3000"), date: Date.current })

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * XAU + 2 * USD", currency: "USD")

    assert_equal BigDecimal("3002"), quote.price
    assert_equal %w[XAU USD], quote.lines.map(&:label)
    assert_equal BigDecimal("1"), quote.lines.second.unit_price.amount
    assert_nil quote.inverse
  end

  test "marks a quote stale when its oldest observation is older than five days" do
    stock = Security.create!(ticker: "OLDQUOTE", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: 10.days.ago.to_date, price: 10, currency: "USD")

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * [OLDQUOTE]", currency: "USD")

    assert quote.stale?
    assert_equal 10.days.ago.to_date, quote.as_of
  end

  test "uses a nested instrument's newest stored price" do
    stock = Security.create!(ticker: "NESTQ", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: Date.current, price: 10, currency: "USD")
    child = create_custom_instrument(family: @family, symbol: "CHILDQ", formula: "1 * [NESTQ]")
    Security::Price.create!(security: child.security, date: Date.current, price: 12, currency: "USD")

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * CHILDQ", currency: "USD")

    assert_equal BigDecimal("12"), quote.price
    assert_equal "CHILDQ", quote.lines.sole.label
  end

  test "recursively quotes a nested instrument with no stored price" do
    stock = Security.create!(ticker: "NESTR", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: Date.current, price: 10, currency: "USD")
    create_custom_instrument(family: @family, symbol: "CHILDR", formula: "1 * [NESTR]")

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * CHILDR", currency: "USD")

    assert_equal BigDecimal("10"), quote.price
  end

  test "reports formula errors without raising" do
    quote = CustomInstrument::Quote.new(family: @family, formula_text: "XAU * XAG", currency: "USD")

    assert_not quote.valid?
    assert_includes quote.error, "Cannot multiply two assets"
    assert_nil quote.price
    assert_empty quote.lines
  end

  test "lists unpriced components without failing the formula" do
    Security.create!(ticker: "OFFLINEQ", exchange_operating_mic: "XNAS", offline: true)
    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * [OFFLINEQ]", currency: "USD")

    assert quote.valid?
    assert_nil quote.price
    assert_equal [ "OFFLINEQ" ], quote.unpriced
  end

  test "never writes securities, prices, rates or pairs" do
    stock = Security.create!(ticker: "NOWRITE", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: Date.current, price: 10, currency: "USD")
    create_custom_instrument(family: @family, symbol: "NOWRITEI", formula: "1 * [NOWRITE]")

    assert_no_difference [ "Security.count", "Security::Price.count", "ExchangeRate.count", "ExchangeRatePair.count" ] do
      quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * [NOWRITE] + 1 * NOWRITEI", currency: "USD")

      assert quote.valid?
    end
  end

  test "exposes its family and whether the price is positive" do
    stock = Security.create!(ticker: "POSITIVE", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: Date.current, price: 10, currency: "USD")

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * [POSITIVE]", currency: "USD")

    assert_equal @family, quote.family
    assert quote.positive?
    assert_not quote.nonpositive?
  end

  test "reports a non-positive price for a formula that subtracts too much" do
    stock = Security.create!(ticker: "NONPOS", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: Date.current, price: 10, currency: "USD")

    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * [NONPOS] - 100 * [NONPOS:XNAS]", currency: "USD")

    assert quote.valid?
    assert_operator quote.price, :<=, 0
    assert_not quote.positive?
    assert quote.nonpositive?
  end

  test "an unpriced quote is neither positive nor non-positive" do
    Security.create!(ticker: "NOPOS", exchange_operating_mic: "XNAS", offline: true)
    quote = CustomInstrument::Quote.new(family: @family, formula_text: "1 * [NOPOS]", currency: "USD")

    assert_nil quote.price
    assert_not quote.positive?
    assert_not quote.nonpositive?
  end
end
