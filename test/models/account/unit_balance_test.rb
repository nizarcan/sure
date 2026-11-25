require "test_helper"

class Account::UnitBalanceTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @instrument = create_custom_instrument(
      family: @family, name: "Gram gold", symbol: "GRAU", currency: "USD"
    )
    @account = instrument_account
    @unit_balance = Account::UnitBalance.new(@account)
  end

  test "add books a transfer trade that does not move cash" do
    result = @unit_balance.add(quantity: 200, date: Date.current)

    assert result.success?
    assert_equal "Added 200 GRAU", result.message
    assert_equal "Added 200 GRAU", result.entry.name

    trade = result.entry.reload.trade
    assert_equal 200, trade.qty
    assert_equal 0, trade.price
    assert_equal 0, trade.fee
    assert_equal Trade::TRANSFER_LABEL, trade.investment_activity_label
    assert_equal @instrument.security, trade.security
    assert_equal 0, result.entry.amount
    assert_equal "USD", result.entry.currency
    assert_equal 200, @account.reload.unit_balance
  end

  test "add formats a fractional quantity without trailing zeros" do
    result = @unit_balance.add(quantity: BigDecimal("10.50"), date: Date.current)

    assert_equal "Added 10.5 GRAU", result.message
    assert_equal BigDecimal("10.5"), @account.reload.unit_balance
  end

  test "set writes only the difference and names the new balance" do
    @unit_balance.add(quantity: 200, date: Date.current)

    result = @unit_balance.set(quantity: 250, date: Date.current)

    assert result.success?
    assert_equal "Balance set to 250 GRAU (+50 GRAU)", result.message
    assert_equal 50, result.entry.trade.qty
    assert_equal 250, @account.reload.unit_balance

    lower = @unit_balance.set(quantity: 220, date: Date.current)
    assert_equal "Balance set to 220 GRAU (-30 GRAU)", lower.message
    assert_equal(-30, lower.entry.trade.qty)
  end

  test "set to the current quantity writes nothing and says so" do
    @unit_balance.add(quantity: 250, date: Date.current)

    assert_no_difference "Entry.count" do
      result = @unit_balance.set(quantity: 250, date: Date.current)

      assert result.success?
      assert_nil result.entry
      assert_equal "The balance is already 250 GRAU.", result.message
    end

    assert_equal 250, @account.reload.unit_balance
  end

  test "remove writes a negative transfer trade" do
    @unit_balance.add(quantity: 200, date: Date.current)

    result = @unit_balance.remove(quantity: 30, date: Date.current)

    assert result.success?
    assert_equal "Removed 30 GRAU", result.message
    assert_equal(-30, result.entry.trade.qty)
    assert_equal 170, @account.reload.unit_balance
  end

  test "removing more than is held fails without writing anything" do
    @unit_balance.add(quantity: 10, date: Date.current)

    assert_no_difference "Entry.count" do
      result = @unit_balance.remove(quantity: 11, date: Date.current)

      assert_not result.success?
      assert_nil result.entry
      assert_includes result.message, "10 GRAU"
    end

    assert_equal 10, @account.reload.unit_balance
  end

  test "a price paid is stored as the lot's manual cost" do
    date = 10.days.ago.to_date

    result = @unit_balance.add(quantity: 10, date: date, unit_price: 12.5)

    lot = HoldingLot.find_by!(account_id: @account.id, source_entry_id: result.entry.id)
    assert_equal BigDecimal("125"), lot.manual_total_cost
    assert_equal 10, lot.qty
    assert_equal date, lot.acquired_on
    assert_equal "USD", lot.currency
    assert lot.manual_cost?
  end

  test "set stores a price paid only on the units it adds" do
    date = Date.current
    @unit_balance.add(quantity: 10, date: date, unit_price: 10)

    result = @unit_balance.set(quantity: 15, date: date, unit_price: 20)

    lot = HoldingLot.find_by!(account_id: @account.id, source_entry_id: result.entry.id)
    assert_equal BigDecimal("100"), lot.manual_total_cost
  end

  test "scheduled trades are left out of the balance" do
    @account.entries.create!(
      name: "Scheduled units",
      date: 1.day.from_now.to_date,
      amount: 0,
      currency: "USD",
      entryable: Trade.new(
        qty: 5, price: 0, fee: 0, currency: "USD",
        security: @instrument.security, investment_activity_label: Trade::TRANSFER_LABEL
      )
    )

    assert_equal 0, @account.reload.unit_balance
    assert_equal 0, @account.unit_balance_on(1.day.from_now.to_date)
  end

  test "unit balance on a date counts only the trades up to it" do
    @unit_balance.add(quantity: 100, date: 10.days.ago.to_date)
    @unit_balance.add(quantity: 50, date: Date.current)

    assert_equal 100, @account.unit_balance_on(5.days.ago.to_date)
    assert_equal 150, @account.unit_balance_on(Date.current)
  end

  test "another account type is refused" do
    result = Account::UnitBalance.new(accounts(:depository)).add(quantity: 1, date: Date.current)

    assert_not result.success?
    assert_equal I18n.t("accounts.unit_balance.errors.not_instrument"), result.message
  end

  test "non-positive quantities are refused" do
    assert_not @unit_balance.add(quantity: 0, date: Date.current).success?
    assert_not @unit_balance.remove(quantity: 0, date: Date.current).success?
    assert_not @unit_balance.set(quantity: -1, date: Date.current).success?
  end

  test "a negative price paid is refused" do
    assert_no_difference "Entry.count" do
      result = @unit_balance.add(quantity: 1, date: Date.current, unit_price: -5)

      assert_not result.success?
      assert_equal I18n.t("accounts.unit_balance.errors.invalid_price"), result.message
    end
  end

  test "an unsupported date comes back as an error, not an exception" do
    assert_no_difference "Entry.count" do
      result = @unit_balance.add(quantity: 1, date: Entry.min_supported_date)

      assert_not result.success?
      assert_nil result.entry
      assert result.message.present?
    end

    assert_equal 0, @account.reload.unit_balance
  end

  private
    def instrument_account
      @family.accounts.create!(
        owner: @user,
        name: "Gold units",
        currency: @instrument.currency,
        balance: 0,
        cash_balance: 0,
        accountable: Investment.new,
        custom_instrument: @instrument
      )
    end
end
