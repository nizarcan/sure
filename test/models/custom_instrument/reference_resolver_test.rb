require "test_helper"

class CustomInstrument::ReferenceResolverTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  Error = CustomInstrument::ReferenceResolver::Error
  Resolved = CustomInstrument::ReferenceResolver::Resolved

  setup do
    @family = families(:dylan_family)
  end

  test "resolves an instrument, a currency and a stored security in formula order" do
    gold = create_custom_instrument(family: @family, symbol: "GOLDU")
    stock = Security.create!(ticker: "AAPLU", exchange_operating_mic: "XNAS")

    resolved = resolver.resolve("1 * GOLDU + 2 * TRY + 3 * [AAPLU:XNAS]")

    assert_equal [ "GOLDU", "TRY", "AAPLU" ], resolved.map { |item| item.reference.symbol }
    assert_equal [ :identifier, :identifier, :security ], resolved.map { |item| item.reference.kind }
    assert_equal [ Rational(1), Rational(2), Rational(3) ], resolved.map(&:weight)
    assert_equal gold.security, resolved[0].security
    assert_equal "TRY", resolved[1].currency
    assert_nil resolved[1].security
    assert_equal stock, resolved[2].security
  end

  test "merges references that resolve to the same asset" do
    stock = Security.create!(ticker: "AAPLU", exchange_operating_mic: "XNAS")

    resolved = resolver.resolve("1 * [AAPLU] + 2 * [AAPLU:XNAS]")

    assert_equal 1, resolved.size
    assert_equal Rational(3), resolved.first.weight
    assert_equal stock, resolved.first.security
    assert_equal "[AAPLU]", resolved.first.reference.to_s
  end

  test "returns an unsaved provider match when create_securities is false" do
    match = Security.new(ticker: "ZZZA", name: "Provider Co", exchange_operating_mic: "XNAS", price_provider: "yahoo_finance")
    Security.expects(:search_provider).with("ZZZA").returns([ match ])

    resolved = resolver.resolve("[ZZZA]")

    assert_equal match, resolved.first.security
    assert_not resolved.first.security.persisted?
  end

  test "persists an exact provider match when create_securities is true" do
    match = Security.new(ticker: "ZZZB", name: "Provider Co", exchange_operating_mic: "XNAS", price_provider: "yahoo_finance")
    Security.expects(:search_provider).with("ZZZB").returns([ match ])

    assert_difference "Security.count", 1 do
      resolved = resolver(create_securities: true).resolve("[ZZZB]")

      assert resolved.first.security.persisted?
      assert_equal "yahoo_finance", resolved.first.security.price_provider
    end
  end

  test "a duplicate provider match is rescued and keeps the search result's name" do
    stored = Security.create!(ticker: "ZZZD", exchange_operating_mic: "XNAS", name: nil)
    duplicate = Security.new(ticker: "ZZZD", name: "Provider Co", exchange_operating_mic: "XNAS")

    resolved = resolver(create_securities: true).send(:persist_security, duplicate)

    assert_equal stored, resolved
    assert_equal "Provider Co", stored.reload.name
  end

  test "provider search only accepts an exact ticker and an exact MIC" do
    near = Security.new(ticker: "ZZZX", exchange_operating_mic: "XNAS")
    exact = Security.new(ticker: "ZZZC", exchange_operating_mic: "XNYS")

    Security.expects(:search_provider).with("ZZZC", exchange_operating_mic: "XNYS").returns([ near, exact ])

    assert_equal exact, resolver.resolve("[ZZZC:XNYS]").first.security
  end

  test "unknown symbols and securities raise localized errors" do
    error = assert_raises(Error) { resolver.resolve("NOT_A_THING") }
    assert_equal :unknown_symbol, error.code
    assert_includes error.message, "NOT_A_THING"

    Security.expects(:search_provider).returns([])
    error = assert_raises(Error) { resolver.resolve("[NOPE]") }
    assert_equal :unknown_security, error.code
    assert_includes error.message, "[NOPE]"

    I18n.with_locale(:tr) do
      assert_includes error.message, "eşleşen"
    end
  end

  test "another family cannot reference my instrument symbol" do
    create_custom_instrument(family: @family, symbol: "SECRET")
    other = Family.create!(name: "Other")

    error = assert_raises(Error) do
      CustomInstrument::ReferenceResolver.new(family: other).resolve("1 * SECRET")
    end

    assert_equal :unknown_symbol, error.code
  end

  test "rejects a self reference" do
    instrument = create_custom_instrument(family: @family, symbol: "SELFY", formula: "XAU")

    error = assert_raises(Error) do
      CustomInstrument::ReferenceResolver.new(family: @family, instrument: instrument).resolve("1 * SELFY")
    end

    assert_equal :self_reference, error.code
  end

  test "rejects a cycle" do
    base = create_custom_instrument(family: @family, symbol: "BASEA", formula: "XAU")
    child = create_custom_instrument(family: @family, symbol: "CHILDA", formula: "1 * BASEA")

    error = assert_raises(Error) do
      CustomInstrument::ReferenceResolver.new(family: @family, instrument: base).resolve("1 * CHILDA")
    end

    assert_equal :cycle, error.code
    assert child.persisted?
  end

  test "rejects archived instruments unless the editing instrument already uses them" do
    archived = create_custom_instrument(family: @family, symbol: "OLD")
    existing = create_custom_instrument(family: @family, symbol: "USESOLD", formula: "1 * OLD")
    archived.archive!

    error = assert_raises(Error) do
      CustomInstrument::ReferenceResolver.new(family: @family).resolve("1 * OLD")
    end
    assert_equal :archived_instrument, error.code

    # Editing the instrument that already references it stays legal so an
    # existing formula can still be saved.
    resolved = CustomInstrument::ReferenceResolver.new(family: @family, instrument: existing).resolve("1 * OLD")
    assert_equal archived.security, resolved.first.security
  end

  test "rejects nesting deeper than five" do
    current = create_custom_instrument(family: @family, symbol: "NT1", formula: "XAU")
    (2..5).each do |level|
      current = create_custom_instrument(family: @family, symbol: "NT#{level}", formula: "1 * NT#{level - 1}")
    end

    error = assert_raises(Error) do
      CustomInstrument::ReferenceResolver.new(family: @family).resolve("1 * NT5")
    end
    assert_equal :nesting_too_deep, error.code
  end

  test "excludes cash and custom securities from bracket lookups" do
    Security.create!(ticker: "CASHY", kind: "cash")
    instrument = create_custom_instrument(family: @family, symbol: "CUSTOMY")
    Security.expects(:search_provider).twice.returns([])

    assert_raises(Error) { resolver.resolve("[CASHY]") }
    assert_raises(Error) { resolver.resolve("[#{instrument.security.ticker}]") }
  end

  test "looks up a stored security without upgrading a legacy MIC" do
    legacy = Security.create!(ticker: "KTYA", exchange_operating_mic: "XWAR")
    legacy.update_columns(exchange_operating_mic: "WAR")

    resolved = resolver.resolve("[KTYA:XWAR]")

    assert_equal legacy, resolved.first.security
    assert_equal "WAR", legacy.reload.exchange_operating_mic
  end

  test "prefers an online row with recent prices, then a blank MIC, then the lowest id" do
    blank = Security.create!(ticker: "MULTI", offline: false)
    Security::Price.create!(security: blank, date: Date.current, price: 10, currency: "USD")
    listed = Security.create!(ticker: "MULTI", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: listed, date: Date.current, price: 11, currency: "USD")

    assert_equal blank, resolver.resolve("[MULTI]").first.security

    blank.prices.delete_all
    listed.prices.delete_all
    Security::Price.create!(security: listed, date: Date.current, price: 11, currency: "USD")

    assert_equal listed, resolver.resolve("[MULTI]").first.security
  end

  private
    def resolver(create_securities: false)
      CustomInstrument::ReferenceResolver.new(family: @family, create_securities: create_securities)
    end
end
