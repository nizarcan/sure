require "test_helper"

class AccountUnitBalancesControllerTest < ActionDispatch::IntegrationTest
  include CustomInstrumentTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user

    @instrument = create_custom_instrument(
      family: @family, name: "Gram gold", symbol: "GRAU", currency: "USD"
    )
    @account = @family.accounts.create!(
      owner: @user,
      name: "Gold units",
      currency: @instrument.currency,
      balance: 0,
      cash_balance: 0,
      accountable: Investment.new,
      custom_instrument: @instrument
    )
  end

  test "new renders the form for each mode" do
    %w[set add remove].each do |mode|
      get new_account_unit_balance_url(account_id: @account.id, mode: mode)

      assert_response :success
      assert_select "form[action=?]", account_unit_balance_path(account_id: @account.id, mode: mode)
      assert_select "input[name='unit_balance[quantity]']"
      assert_select "input[name='unit_balance[date]']"
      assert_select "input[name='unit_balance[mode]'][value=?]", mode
    end
  end

  test "only add offers a price paid" do
    get new_account_unit_balance_url(account_id: @account.id, mode: "add")
    assert_select "input[name='unit_balance[unit_price]']"

    get new_account_unit_balance_url(account_id: @account.id, mode: "set")
    assert_select "input[name='unit_balance[unit_price]']", count: 0
  end

  test "add writes the units and stores the price paid" do
    date = 10.days.ago.to_date

    assert_difference "Entry.count", 1 do
      post account_unit_balance_url(account_id: @account.id, mode: "add"), params: {
        unit_balance: { date: date, quantity: "50", unit_price: "12.5" }
      }
    end

    assert_redirected_to account_path(@account, tab: "activity")
    assert_equal I18n.t("accounts.unit_balance.names.add", quantity: "50", symbol: "GRAU"), flash[:notice]
    assert_equal 50, @account.reload.unit_balance

    lot = HoldingLot.find_by!(account_id: @account.id)
    assert_equal BigDecimal("625"), lot.manual_total_cost
    assert_equal date, lot.acquired_on
  end

  test "set books only the difference and reports no change" do
    Account::UnitBalance.new(@account).add(quantity: 200, date: Date.current)

    post account_unit_balance_url(account_id: @account.id, mode: "set"), params: {
      unit_balance: { date: Date.current, quantity: "250" }
    }
    assert_redirected_to account_path(@account, tab: "activity")
    assert_equal(
      I18n.t("accounts.unit_balance.changed",
             name: I18n.t("accounts.unit_balance.names.set", quantity: "250", symbol: "GRAU"),
             change: "+50 GRAU"),
      flash[:notice]
    )

    assert_no_difference "Entry.count" do
      post account_unit_balance_url(account_id: @account.id, mode: "set"), params: {
        unit_balance: { date: Date.current, quantity: "250" }
      }
    end
    assert_redirected_to account_path(@account, tab: "activity")
    assert_equal I18n.t("accounts.unit_balance.unchanged", quantity: "250", symbol: "GRAU"), flash[:notice]
  end

  test "removing more than is held re-renders with the error and writes nothing" do
    Account::UnitBalance.new(@account).add(quantity: 10, date: Date.current)

    assert_no_difference "Entry.count" do
      post account_unit_balance_url(account_id: @account.id, mode: "remove"), params: {
        unit_balance: { date: Date.current, quantity: "11" }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("accounts.unit_balance.errors.insufficient_units", held: "10", symbol: "GRAU")
    assert_equal 10, @account.reload.unit_balance
  end

  test "an account that does not hold an instrument is sent to its page" do
    account = accounts(:investment)

    get new_account_unit_balance_url(account_id: account.id, mode: "set")

    assert_redirected_to account_path(account)
    assert_equal I18n.t("accounts.unit_balance.errors.not_an_instrument_account"), flash[:alert]
  end

  test "another family's account is not found" do
    other = families(:empty).accounts.create!(
      name: "Other", currency: "USD", balance: 0, accountable: Investment.new
    )

    get new_account_unit_balance_url(account_id: other.id, mode: "set")

    assert_response :not_found
  end

  test "a guest with read-only access cannot change units" do
    guest = family_guest
    @account.account_shares.create!(user: guest, permission: "read_only", include_in_finances: true)
    sign_in guest

    post account_unit_balance_url(account_id: @account.id, mode: "add"), params: {
      unit_balance: { date: Date.current, quantity: "5" }
    }

    assert_redirected_to account_path(@account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_equal 0, @account.reload.unit_balance
  end

  test "an unknown mode falls back to setting the balance" do
    post account_unit_balance_url(account_id: @account.id, mode: "bogus"), params: {
      unit_balance: { date: Date.current, quantity: "5" }
    }

    assert_redirected_to account_path(@account, tab: "activity")
    assert_equal 5, @account.reload.unit_balance
  end

  test "the form renders in English and Turkish" do
    %w[en tr].each do |locale|
      @user.update!(locale: locale)

      %w[set add remove].each do |mode|
        get new_account_unit_balance_url(account_id: @account.id, mode: mode)
        assert_response :success
        assert_no_missing_translation
      end
    end
  end

  private
    def assert_no_missing_translation
      assert_not_includes response.body, "translation_missing"
      assert_not_includes response.body, "translation missing"
      assert_not_includes response.body, "Translation missing"
    end
end
