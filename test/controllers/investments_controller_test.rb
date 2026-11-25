require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest
  include CustomInstrumentTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "the investment type select is labelled from the locale" do
    get new_investment_url
    assert_response :success
    assert_select "label[for=account_accountable_attributes_subtype]", text: "Investment type"
  end

  test "changing the method starts one sync of the account" do
    assert @account.cost_basis_average?
    Account.any_instance.expects(:sync_later).once

    patch investment_path(@account), params: { account: { cost_basis_method: "fifo" } }

    assert_redirected_to account_path(@account)
    assert @account.reload.cost_basis_fifo?
  end

  test "resubmitting the same method starts no sync" do
    Account.any_instance.expects(:sync_later).never

    patch investment_path(@account), params: { account: { name: "Renamed", cost_basis_method: "average" } }

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
  end

  test "an unknown method is rejected" do
    Account.any_instance.expects(:sync_later).never

    patch investment_path(@account), params: { account: { cost_basis_method: "lifo" } }

    assert_response :unprocessable_entity
    assert @account.reload.cost_basis_average?
  end

  test "the method select is on the form of an account that supports trades, and only there" do
    get edit_investment_path(@account)
    assert_select "select[name='account[cost_basis_method]'] option", count: 2

    get edit_depository_path(accounts(:depository))
    assert_response :success
    assert_select "select[name='account[cost_basis_method]']", count: 0
  end

  test "a new account starts on average whatever the form submits" do
    assert_difference "Account.count", 1 do
      post investments_path, params: {
        account: { name: "New brokerage", currency: "USD", balance: 1000, accountable_type: "Investment", cost_basis_method: "fifo" }
      }
    end

    assert Account.order(:created_at).last.cost_basis_average?
  end

  test "an account that does not support trades ignores a submitted method" do
    depository = accounts(:depository)
    Account.any_instance.expects(:sync_later).never

    patch depository_path(depository), params: { account: { cost_basis_method: "fifo" } }

    assert depository.reload.cost_basis_average?
  end

  # A linked account's provider sync overwrites any attribute not locked, so
  # a field edited on the form is locked whether or not the method changes.
  test "renaming a linked account locks its name, the method unchanged" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))
    assert_not @account.locked?(:name)

    patch investment_path(@account), params: { account: { name: "Renamed", cost_basis_method: "average" } }

    assert_redirected_to account_path(@account)
    assert @account.reload.locked?(:name)
  end

  test "renaming a linked account locks its name, the method changed" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))
    assert_not @account.locked?(:name)

    patch investment_path(@account), params: { account: { name: "Renamed", cost_basis_method: "fifo" } }

    assert_redirected_to account_path(@account)
    @account.reload
    assert @account.locked?(:name)
    assert @account.cost_basis_fifo?
  end

  test "the new form offers the family's active instruments" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")
    archived = create_custom_instrument(family: @user.family, name: "Old gold", symbol: "OLDG")
    archived.archive!

    get new_investment_url

    assert_response :success
    assert_select "optgroup[label=?]", I18n.t("shared.money_field.instruments_group") do
      assert_select "option[value=?]", "instrument:#{instrument.id}"
      assert_select "option[value=?]", "instrument:#{archived.id}", count: 0
    end
  end

  test "the new form preselects a requested instrument as a quantity field" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")

    get new_investment_url(instrument: instrument.id)

    assert_response :success
    assert_select "select[name='account[currency]'] option[selected][value=?]", "instrument:#{instrument.id}"
    assert_select "label[for=account_balance] span", text: I18n.t("shared.money_field.quantity")
    assert_select "input[name='account[unit_price]']"
  end

  test "creates an instrument account with its first units" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")
    date = 20.days.ago.to_date

    assert_difference "Account.count", 1 do
      assert_difference "Entry.count", 2 do
        post investments_url, params: { account: {
          name: "Gold units",
          balance: "200",
          currency: "instrument:#{instrument.id}",
          accountable_type: "Investment",
          opening_balance_date: date.iso8601,
          unit_price: "12.5"
        } }
      end
    end

    account = @user.family.accounts.find_by!(name: "Gold units")
    assert_redirected_to account_path(account)
    assert_equal instrument, account.custom_instrument
    assert_equal "USD", account.currency
    assert_equal 0, account.balance.to_d
    assert_equal 0, account.cash_balance.to_d
    assert_equal 200, account.unit_balance
    assert_equal 1, account.trades.count

    entry = account.trades.sole.entry
    assert_equal 0, entry.amount
    assert_equal Trade::TRANSFER_LABEL, entry.trade.investment_activity_label

    lot = HoldingLot.find_by!(account_id: account.id, source_entry_id: entry.id)
    assert_equal BigDecimal("2500"), lot.manual_total_cost

    anchor = account.valuations.opening_anchor.sole.entry
    assert_equal date - 1.day, anchor.date
    assert_equal 0, anchor.amount
    assert_equal date, account.trades.sole.entry.date
  end

  test "an unknown instrument is a form error, not a missing page" do
    assert_no_difference "Account.count" do
      post investments_url, params: { account: {
        name: "Gold units",
        balance: "200",
        currency: "instrument:#{SecureRandom.uuid}",
        accountable_type: "Investment"
      } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("accounts.create.instrument_not_found")
  end

  test "another family's instrument is a form error" do
    foreign = create_custom_instrument(family: families(:empty), name: "Other gold", symbol: "OTHERG")

    assert_no_difference "Account.count" do
      post investments_url, params: { account: {
        name: "Gold units",
        balance: "200",
        currency: "instrument:#{foreign.id}",
        accountable_type: "Investment"
      } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("accounts.create.instrument_not_found")
  end

  test "an archived instrument is a form error" do
    instrument = create_custom_instrument(family: @user.family, name: "Old gold", symbol: "OLDG")
    instrument.archive!

    assert_no_difference "Account.count" do
      post investments_url, params: { account: {
        name: "Gold units",
        balance: "200",
        currency: "instrument:#{instrument.id}",
        accountable_type: "Investment"
      } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("accounts.create.instrument_not_found")
  end

  test "an instrument account can start empty" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")

    assert_difference "Account.count", 1 do
      assert_no_difference "Trade.count" do
        post investments_url, params: { account: {
          name: "Gold units", balance: "0", currency: "instrument:#{instrument.id}", accountable_type: "Investment"
        } }
      end
    end

    account = @user.family.accounts.find_by!(name: "Gold units")
    assert_redirected_to account_url(account)
    assert_equal instrument, account.custom_instrument
    assert_equal 0, account.unit_balance

    result = Account::UnitBalance.new(account).add(quantity: 5, date: Date.current)
    assert result.success?
    assert_equal 5, account.reload.unit_balance
  end

  test "an instrument account refuses a negative quantity" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")

    assert_no_difference "Account.count" do
      post investments_url, params: { account: {
        name: "Gold units",
        balance: "-1",
        currency: "instrument:#{instrument.id}",
        accountable_type: "Investment"
      } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("accounts.create.quantity_cannot_be_negative")
    assert_select "select[name='account[currency]'] option[selected][value=?]", "instrument:#{instrument.id}"
  end

  test "errors keep the instrument and the entered quantity" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")

    assert_no_difference "Account.count" do
      post investments_url, params: { account: {
        name: "",
        balance: "200",
        currency: "instrument:#{instrument.id}",
        accountable_type: "Investment",
        opening_balance_date: 10.days.ago.to_date.iso8601
      } }
    end

    assert_response :unprocessable_entity
    assert_select "select[name='account[currency]'] option[selected][value=?]", "instrument:#{instrument.id}"
    assert_select "input[name='account[balance]'][value='200']"
  end

  test "the edit form of an instrument account shows the instrument, not a balance" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")
    account = @user.family.accounts.create!(
      owner: @user, name: "Gold units", currency: "USD", balance: 0,
      cash_balance: 0, accountable: Investment.new, custom_instrument: instrument
    )

    get edit_investment_path(account)

    assert_response :success
    assert_select "input[name='account[balance]']", count: 0
    assert_select "select[name='account[currency]']", count: 0
    assert_select "a[href=?]", custom_instrument_path(instrument), text: instrument.name
    assert_includes response.body, I18n.t("accounts.form.held_in")
  end
end
