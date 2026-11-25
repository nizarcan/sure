require "test_helper"

class Account::InstrumentAccountFlowTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @instrument = create_custom_instrument(
      family: @family, name: "Gram gold", symbol: "GRAU", currency: "USD", formula: "2 * USD"
    )
    @account = @family.accounts.create!(
      owner: @user,
      name: "Gold units",
      currency: "USD",
      balance: 0,
      cash_balance: 0,
      accountable: Investment.new,
      custom_instrument: @instrument
    )
    @opening_date = 30.days.ago.to_date
  end

  test "units drive the money value and the price paid is the cost" do
    seed_prices(10)
    Account::OpeningBalanceManager.new(@account).set_opening_balance(balance: 0, date: @opening_date - 1.day)

    Account::UnitBalance.new(@account).add(quantity: 200, date: @opening_date, unit_price: 5)
    materialize

    @account.reload
    assert_equal 0, @account.cash_balance.to_d
    assert_equal BigDecimal("2000"), @account.balance.to_d
    assert_equal BigDecimal("2000"), @account.balances.find_by!(date: @opening_date).balance.to_d

    holding = @account.holdings.find_by!(security: @instrument.security, date: Date.current)
    assert_equal BigDecimal("200"), holding.qty
    assert_equal BigDecimal("2000"), holding.amount.to_d
    assert_equal BigDecimal("5"), holding.cost_basis.to_d

    Account::UnitBalance.new(@account).set(quantity: 250, date: Date.current)
    materialize

    @account.reload
    assert_equal BigDecimal("2500"), @account.balance.to_d
    assert_equal 0, @account.cash_balance.to_d

    Account::UnitBalance.new(@account).remove(quantity: 30, date: Date.current)
    materialize

    @account.reload
    assert_equal 220, @account.reload.unit_balance
    assert_equal BigDecimal("2200"), @account.balance.to_d
    assert_equal 0, @account.cash_balance.to_d
  end

  private
    def seed_prices(price)
      (@opening_date..Date.current).each do |date|
        @instrument.security.prices.create!(date: date, price: price, currency: "USD")
      end
    end

    def materialize
      Account::Syncer.new(@account).send(:materialize_balances)
    end
end
