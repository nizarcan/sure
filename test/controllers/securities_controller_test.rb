require "test_helper"

class SecuritiesControllerTest < ActionDispatch::IntegrationTest
  include CustomInstrumentTestHelper

  setup { sign_in users(:family_admin) }

  test "index shows the ISIN of a search result when the provider returns one" do
    with_isin = Security.new(ticker: "SGLD", name: "Invesco Physical Gold", exchange_operating_mic: "XLON",
                             country_code: "GB", price_provider: "eodhd")
    with_isin.search_isin = "IE00B579F325"
    without_isin = Security.new(ticker: "PHYM", name: "Another fund", exchange_operating_mic: "XLON",
                                country_code: "GB", price_provider: "yahoo_finance")
    Security.stubs(:search_provider).returns([ with_isin, without_isin ])

    get securities_url(q: "gold"), as: :turbo_stream

    assert_response :success
    assert_equal 1, response.body.scan("IE00B579F325").size
    assert_includes response.body, "Another fund"
  end

  # The combobox loads its first page with no query at all, so a family's
  # instruments have to appear there; otherwise the list is empty until the
  # user types one of their own symbols.
  test "index lists the family's custom instruments first on a blank query" do
    instrument = create_custom_instrument(family: families(:dylan_family))
    provider_security = Security.new(ticker: "SGLD", name: "Invesco Physical Gold", price_provider: "eodhd")
    Security.stubs(:search_provider).returns([ provider_security ])

    get securities_url, as: :turbo_stream

    assert_response :success
    assert_operator response.body.index(instrument.security.to_combobox_option.id), :<,
                    response.body.index("SGLD"), "custom instrument should be listed before provider results"
    assert_includes response.body, "GRAU"
    assert_includes response.body, instrument.formula
    assert_includes response.body, I18n.t("securities.combobox.custom")
  end

  test "index matches custom instruments by symbol and name ignoring case" do
    create_custom_instrument(family: families(:dylan_family), name: "Gram gold", symbol: "GRAU")
    Security.stubs(:search_provider).returns([])

    get securities_url(q: "gra"), as: :turbo_stream
    assert_response :success
    assert_includes response.body, "GRAU"

    get securities_url(q: "GRAM"), as: :turbo_stream
    assert_response :success
    assert_includes response.body, "GRAU"

    get securities_url(q: "silver"), as: :turbo_stream
    assert_response :success
    assert_not_includes response.body, "GRAU"
  end

  test "index leaves custom instruments out when asked to" do
    create_custom_instrument(family: families(:dylan_family))
    Security.stubs(:search_provider).returns([])

    get securities_url(q: "GRAU", exclude_custom: 1), as: :turbo_stream

    assert_response :success
    assert_not_includes response.body, "GRAU"
  end

  test "index hides archived instruments and other families' instruments" do
    archived = create_custom_instrument(family: families(:dylan_family), symbol: "OLDG")
    archived.archive!
    foreign = create_custom_instrument(family: families(:empty), symbol: "FOREIGN")
    Security.stubs(:search_provider).returns([])

    get securities_url, as: :turbo_stream

    assert_response :success
    assert_not_includes response.body, archived.security.ticker
    assert_not_includes response.body, foreign.security.ticker
  end

  test "index caps custom results at ten" do
    11.times { |index| create_custom_instrument(family: families(:dylan_family), symbol: "CAP#{index}") }
    Security.stubs(:search_provider).returns([])

    get securities_url, as: :turbo_stream

    assert_response :success
    assert_equal 10, response.body.scan(/CUSTOM-[0-9a-f-]{36}\|\|custom/i).uniq.size
  end

  test "guests can read the instrument list" do
    sign_in users(:intro_user)

    get securities_url, as: :turbo_stream

    assert_response :success
  end
end
