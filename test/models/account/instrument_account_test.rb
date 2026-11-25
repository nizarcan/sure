require "test_helper"

class Account::InstrumentAccountTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @instrument = create_custom_instrument(
      family: @family, name: "Gram gold", symbol: "GRAU", currency: "USD"
    )
  end

  test "an investment account can be held in a family instrument" do
    account = build_account

    assert account.save
    assert account.instrument_account?
    assert_equal @instrument, account.custom_instrument
  end

  test "another family's instrument is refused" do
    other = create_custom_instrument(family: families(:empty), name: "Other gold", symbol: "OTHERG", currency: "USD")

    account = build_account(instrument: other)

    assert_not account.save
    assert_includes account.errors[:custom_instrument], I18n.t("activerecord.errors.models.account.attributes.custom_instrument.other_family")
  end

  test "only investment accounts can hold an instrument" do
    account = build_account(accountable: Depository.new)

    assert_not account.save
    assert_includes account.errors[:custom_instrument], I18n.t("activerecord.errors.models.account.attributes.custom_instrument.not_an_investment")
  end

  test "the account's currency must match the instrument's" do
    account = build_account(currency: "EUR")

    assert_not account.save
    assert_includes account.errors[:currency],
                    I18n.t("activerecord.errors.models.account.attributes.currency.instrument_currency", currency: "USD")
  end

  test "the instrument cannot be changed after the account is created" do
    account = build_account
    account.save!

    account.custom_instrument = nil

    assert_not account.save
    assert_includes account.errors[:custom_instrument], I18n.t("activerecord.errors.models.account.attributes.custom_instrument.immutable")
  end

  test "unit balance display pairs the quantity with the symbol" do
    account = build_account
    account.save!
    Account::UnitBalance.new(account).add(quantity: 250, date: Date.current)

    assert_equal "250 GRAU", account.reload.unit_balance_display
  end

  test "preloading fills the unit balance for a collection" do
    first = build_account
    first.save!
    second = build_account(name: "More gold")
    second.save!
    Account::UnitBalance.new(first).add(quantity: 2, date: Date.current)
    Account::UnitBalance.new(second).add(quantity: 3, date: Date.current)

    Account.preload_unit_balances([ first, second ])

    assert_equal 2, first.unit_balance
    assert_equal 3, second.unit_balance
  end

  private
    def build_account(instrument: @instrument, accountable: Investment.new, currency: instrument.currency, name: "Gold units")
      @family.accounts.new(
        owner: @user,
        name: name,
        currency: currency,
        balance: 0,
        cash_balance: 0,
        accountable: accountable,
        custom_instrument: instrument
      )
    end
end
