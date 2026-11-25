require "test_helper"
require "ostruct"

class TradeImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  setup do
    @subject = @import = imports(:trade)
    @provider = mock
    Security.stubs(:provider).returns(@provider)
  end

  test "csv_template uses ISO dates" do
    first_row = @import.csv_template.first

    assert_equal "2024-05-15", first_row["date*"]
  end

  test "generates rows from legacy quantity header with template labels" do
    import_csv = <<~CSV
      date,ticker,quantity,price,account_name
      2024-05-15,AAPL,10,150.00,Trading Account
    CSV

    @import.update!(
      raw_file_str: import_csv,
      date_col_label: "date*",
      ticker_col_label: "ticker*",
      qty_col_label: "qty*",
      price_col_label: "price*",
      account_col_label: "account",
      date_format: "%Y-%m-%d",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    row = @import.rows.reload.first

    assert row.valid?
    assert_equal "Trading Account", row.account
    assert_equal "10", row.qty
    assert_equal BigDecimal("1500"), row.signed_amount
  end

  test "imports trades and accounts" do
    aapl_resolver = mock
    googl_resolver = mock

    Security::Resolver.expects(:new)
                      .with("AAPL", exchange_operating_mic: nil)
                      .returns(aapl_resolver)
                      .once

    Security::Resolver.expects(:new)
                      .with("GOOGL", exchange_operating_mic: "XNAS")
                      .returns(googl_resolver)
                      .once

    aapl = securities(:aapl)
    googl = Security.create!(ticker: "GOOGL", exchange_operating_mic: "XNAS")

    aapl_resolver.stubs(:resolve).returns(aapl)
    googl_resolver.stubs(:resolve).returns(googl)

    import = <<~CSV
      date,ticker,qty,price,currency,account,name,exchange_operating_mic
      01/01/2024,AAPL,10,150.00,USD,TestAccount1,Apple Purchase,
      01/02/2024,GOOGL,5,2500.00,USD,TestAccount1,Google Purchase,XNAS
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      exchange_operating_mic_col_label: "exchange_operating_mic",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv

    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"

    @import.reload

    assert_difference -> { Entry.count } => 2,
                      -> { Trade.count } => 2,
                      -> { Account.count } => 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
  end

  test "auto-assigns investment activity labels to buy and sell trades" do
    aapl = securities(:aapl)
    aapl_resolver = mock
    aapl_resolver.stubs(:resolve).returns(aapl)
    Security::Resolver.stubs(:new).returns(aapl_resolver)

    account = accounts(:depository)

    import = <<~CSV
      date,ticker,qty,price,currency,name
      01/01/2024,AAPL,10,150.00,USD,Apple Buy
      01/02/2024,AAPL,-5,160.00,USD,Apple Sell
    CSV

    @import.update!(
      account: account,
      raw_file_str: import,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    @import.reload

    assert_difference -> { Trade.count } => 2 do
      @import.publish
    end

    # Find trades created by this import
    imported_trades = Trade.joins(:entry).where(entries: { import_id: @import.id })
    buy_trade = imported_trades.find { |t| t.qty.positive? }
    sell_trade = imported_trades.find { |t| t.qty.negative? }

    assert_not_nil buy_trade, "Buy trade should have been created"
    assert_not_nil sell_trade, "Sell trade should have been created"
    assert_equal "Buy", buy_trade.investment_activity_label, "Buy trade should have 'Buy' activity label"
    assert_equal "Sell", sell_trade.investment_activity_label, "Sell trade should have 'Sell' activity label"
  end

  test "imports a trade for the family's own custom instrument by its symbol" do
    instrument = @import.family.custom_instruments.create!(
      name: "Gram gold", symbol: "GRAU", currency: "USD", formula: "2 * USD"
    )

    import_csv = <<~CSV
      date,ticker,qty,price,currency,account,name
      01/01/2024,GRAU,10,150.00,USD,TestAccount1,Gram gold purchase
    CSV

    @import.update!(
      account: nil,
      raw_file_str: import_csv,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      currency_col_label: "currency",
      account_col_label: "account",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )
    @import.generate_rows_from_csv
    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"
    @import.reload

    Security::Resolver.any_instance.expects(:resolve).never

    @import.publish

    assert_equal "complete", @import.status
    trade = Trade.joins(:entry).where(entries: { import_id: @import.id }).sole
    assert_equal instrument.security, trade.security
    assert_equal "GRAU", trade.security.display_ticker
  end

  test "imports a trade for the family's own custom instrument by its CUSTOM- ticker" do
    instrument = @import.family.custom_instruments.create!(
      name: "Gram gold", symbol: "GRAU", currency: "USD", formula: "2 * USD"
    )

    import_csv = <<~CSV
      date,ticker,qty,price,currency,account,name
      01/01/2024,#{instrument.security.ticker},10,150.00,USD,TestAccount1,Gram gold purchase
    CSV

    @import.update!(
      account: nil,
      raw_file_str: import_csv,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      currency_col_label: "currency",
      account_col_label: "account",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )
    @import.generate_rows_from_csv
    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"
    @import.reload

    @import.publish

    assert_equal "complete", @import.status
    assert_equal instrument.security, Trade.joins(:entry).where(entries: { import_id: @import.id }).sole.security
  end

  test "fails clearly on another family's CUSTOM- ticker instead of attaching to it" do
    foreign = families(:empty).custom_instruments.create!(
      name: "Foreign gram", symbol: "FOREIGN", currency: "USD", formula: "2 * USD"
    )

    import_csv = <<~CSV
      date,ticker,qty,price,currency,account,name
      01/01/2024,#{foreign.security.ticker},10,150.00,USD,TestAccount1,Foreign purchase
    CSV

    @import.update!(
      account: nil,
      raw_file_str: import_csv,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      currency_col_label: "currency",
      account_col_label: "account",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )
    @import.generate_rows_from_csv
    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"
    @import.reload

    assert_no_difference [ "Trade.count", "Entry.count" ] do
      @import.publish
    end

    assert_equal "failed", @import.status
    assert_includes @import.error, "Could not resolve security"
    assert_equal foreign.security, foreign.security.reload
    assert_empty foreign.security.trades
  end
end
