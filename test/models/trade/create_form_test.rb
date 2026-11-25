require "test_helper"

class Trade::CreateFormTest < ActiveSupport::TestCase
  include GoalPledgeTestHelper
  include CustomInstrumentTestHelper

  setup do
    @account = accounts(:investment)
  end

  # The API runs the form inside its own transaction, so a pledge must wait
  # for that to commit rather than resolve inside it.
  test "an unlinked deposit resolves its pledge only once the caller's transaction commits" do
    pledge = open_transfer_pledge(@account, amount: 250)

    ApplicationRecord.transaction do
      Trade::CreateForm.new(account: @account, type: "deposit", date: Date.current, amount: 250, currency: "USD").create

      assert_equal "open", pledge.reload.status
    end

    assert_equal "matched", pledge.reload.status
  end

  test "adding units already owned books a Transfer at price zero" do
    instrument = create_custom_instrument(family: @account.family)

    entry = Trade::CreateForm.new(
      account: @account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: 10,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal "Added 10 units of GRAU", entry.name
    assert_equal BigDecimal("0"), entry.amount.to_d

    trade = entry.trade
    assert_equal instrument.security, trade.security
    assert_equal BigDecimal("10"), trade.qty
    assert_equal BigDecimal("0"), trade.price.to_d
    assert_equal BigDecimal("0"), trade.fee.to_d
    assert_equal Trade::TRANSFER_LABEL, trade.investment_activity_label
    assert trade.internal_movement?
  end

  test "adding units already owned falls back to the account currency" do
    instrument = create_custom_instrument(family: @account.family)

    entry = Trade::CreateForm.new(
      account: @account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: "2.5",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal @account.currency, entry.currency
    assert_equal @account.currency, entry.trade.currency
    assert_equal "Added 2.5 units of GRAU", entry.name
  end

  test "adding units already owned requires a positive quantity" do
    instrument = create_custom_instrument(family: @account.family)

    entry = Trade::CreateForm.new(
      account: @account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: 0,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert_not entry.persisted?
    assert_includes entry.errors[:base], I18n.t("trades.form.qty_must_be_positive")
  end

  test "adding units already owned works for an ordinary security" do
    entry = Trade::CreateForm.new(
      account: @account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: 3,
      currency: "USD",
      manual_ticker: "AAPL"
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal securities(:aapl), entry.trade.security
    assert_equal Trade::TRANSFER_LABEL, entry.trade.investment_activity_label
    assert_equal "Added 3 units of AAPL", entry.name
  end

  test "an archived instrument cannot be used for a new trade" do
    instrument = create_custom_instrument(family: @account.family)
    instrument.archive!

    entry = Trade::CreateForm.new(
      account: @account,
      type: "buy",
      date: Date.current,
      qty: 1,
      price: 10,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert_not entry.persisted?
    assert_includes entry.errors[:base], I18n.t("trades.form.trade_requires_security")
  end

  test "an archived instrument can be sold when the account holds it" do
    instrument = create_custom_instrument(family: @account.family, symbol: "ARCHD")
    @account.holdings.create!(
      security: instrument.security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    instrument.archive!

    entry = Trade::CreateForm.new(
      account: @account,
      type: "sell",
      date: Date.current,
      qty: 2,
      price: 50,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal instrument.security, entry.trade.security
    assert_equal "Sell 2.0 shares of ARCHD", entry.name
    assert_equal(-2, entry.trade.qty.to_i)
  end

  test "an archived instrument can be sold by its typed symbol when the account holds it" do
    instrument = create_custom_instrument(family: @account.family, symbol: "ARCHD")
    @account.holdings.create!(
      security: instrument.security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    instrument.archive!

    entry = Trade::CreateForm.new(
      account: @account,
      type: "sell",
      date: Date.current,
      qty: 2,
      price: 50,
      currency: "USD",
      manual_ticker: "archd"
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal instrument.security, entry.trade.security
  end

  test "an archived instrument cannot be bought or sold when the account has no position" do
    instrument = create_custom_instrument(family: @account.family, symbol: "ARCHD")
    instrument.archive!

    %w[buy sell].each do |type|
      entry = Trade::CreateForm.new(
        account: @account,
        type: type,
        date: Date.current,
        qty: 1,
        price: 10,
        currency: "USD",
        ticker: instrument.security.to_combobox_option.id
      ).create

      assert_not entry.persisted?, "#{type} of an unheld archived instrument must be refused"
      assert_includes entry.errors[:base], I18n.t("trades.form.trade_requires_security")
    end
  end

  test "a dividend on an archived instrument the account holds is still recordable" do
    instrument = create_custom_instrument(family: @account.family, symbol: "ARCHD")
    @account.holdings.create!(
      security: instrument.security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    instrument.archive!

    entry = Trade::CreateForm.new(
      account: @account,
      type: "dividend",
      date: Date.current,
      amount: 25,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal instrument.security, entry.trade.security
  end

  test "a typed symbol for an archived instrument is rejected rather than resolved as a new security" do
    instrument = create_custom_instrument(family: @account.family, symbol: "GRAU")
    instrument.archive!

    assert_no_difference "Security.count" do
      entry = Trade::CreateForm.new(
        account: @account,
        type: "buy",
        date: Date.current,
        qty: 1,
        price: 10,
        currency: "USD",
        manual_ticker: "grau"
      ).create

      assert_not entry.persisted?
      assert_includes entry.errors[:base], I18n.t("trades.form.trade_requires_security")
    end
  end

  test "another family's instrument id is rejected" do
    foreign = create_custom_instrument(family: families(:empty), symbol: "FOREIGN")

    entry = Trade::CreateForm.new(
      account: @account,
      type: "buy",
      date: Date.current,
      qty: 1,
      price: 10,
      currency: "USD",
      ticker: foreign.security.to_combobox_option.id
    ).create

    assert_not entry.persisted?
    assert_includes entry.errors[:base], I18n.t("trades.form.trade_requires_security")
  end

  test "a typed symbol resolves to the family's instrument ignoring case" do
    instrument = create_custom_instrument(family: @account.family, symbol: "GRAU")

    entry = Trade::CreateForm.new(
      account: @account,
      type: "buy",
      date: Date.current,
      qty: 1,
      price: 10,
      currency: "USD",
      manual_ticker: "grau"
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal instrument.security, entry.trade.security
    assert_includes entry.name, "GRAU"
  end

  test "the trade name uses the instrument's symbol rather than its internal ticker" do
    instrument = create_custom_instrument(family: @account.family, symbol: "CEYREK")

    entry = Trade::CreateForm.new(
      account: @account,
      type: "sell",
      date: Date.current,
      qty: 2,
      price: 10,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_includes entry.name, "CEYREK"
    assert_not_includes entry.name, "CUSTOM-"
  end

  test "income and fee trades with an unresolved custom id report an error instead of raising" do
    unknown = "CUSTOM-#{SecureRandom.uuid}||custom"

    interest = Trade::CreateForm.new(
      account: @account, type: "interest", date: Date.current, amount: 10, currency: "USD", ticker: unknown
    ).create
    assert_not interest.persisted?
    assert_includes interest.errors[:base], I18n.t("trades.form.security_not_found")

    fee = Trade::CreateForm.new(
      account: @account, type: "fee", date: Date.current, amount: 10, currency: "USD", ticker: unknown
    ).create
    assert_not fee.persisted?
    assert_includes fee.errors[:base], I18n.t("trades.form.security_not_found")

    dividend = Trade::CreateForm.new(
      account: @account, type: "dividend", date: Date.current, amount: 10, currency: "USD", ticker: unknown
    ).create
    assert_not dividend.persisted?
    assert_includes dividend.errors[:base], I18n.t("trades.form.dividend_requires_security")
  end

  test "the opening type is not an API-supported type" do
    assert_not_includes Trade::CreateForm::SUPPORTED_TYPES, Trade::CreateForm::OPENING_TYPE
    assert_not_includes Trade::CreateForm::ACTIVITY_LABELS.values, Trade::TRANSFER_LABEL
  end

  test "an instrument account refuses a trade in another security" do
    account = instrument_account
    other = securities(:msft)

    entry = Trade::CreateForm.new(
      account: account,
      type: "buy",
      date: Date.current,
      qty: 1,
      price: 10,
      currency: "USD",
      ticker: other.to_combobox_option.id
    ).create

    assert_not entry.persisted?
    assert_includes entry.errors[:base], I18n.t("trades.form.instrument_account_security")
  end

  test "an instrument account accepts units of its own instrument" do
    account = instrument_account

    entry = Trade::CreateForm.new(
      account: account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: 5,
      currency: "USD",
      ticker: account.custom_instrument.security.to_combobox_option.id
    ).create

    assert entry.persisted?, entry.errors.full_messages.to_sentence
    assert_equal account.custom_instrument.security, entry.trade.security
    assert_equal 5, entry.trade.qty
  end

  private
    def instrument_account
      instrument = create_custom_instrument(family: @account.family, symbol: "UNITACC", currency: "USD")

      @account.family.accounts.create!(
        owner: users(:family_admin),
        name: "Gold units",
        currency: instrument.currency,
        balance: 0,
        cash_balance: 0,
        accountable: Investment.new,
        custom_instrument: instrument
      )
    end
end
