require "application_system_test_case"

class CustomInstrumentsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  OUNCE_RATE = 182_803

  setup do
    @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    @family = @user.family
    @family.update!(currency: "TRY")
    @account = @family.accounts.create!(
      owner: @user, name: "Physical gold", currency: "TRY", balance: 0, cash_balance: 0, accountable: Investment.new
    )

    40.downto(0) do |days|
      rate = OUNCE_RATE + days * 100
      ExchangeRate.create!(from_currency: "XAU", to_currency: "TRY", date: days.days.ago.to_date, rate: rate)
      ExchangeRate.create!(from_currency: "XAG", to_currency: "TRY", date: days.days.ago.to_date, rate: 2155)
    end

    Security.stubs(:provider).returns(nil)
    Security.stubs(:providers).returns([])
    # Rates are seeded above; nothing may reach a provider.
    CustomInstrument::RateSource.stubs(:import)

    sign_in @user
  end

  test "defines a gold coin from a template, adds owned units and values them" do
    visit custom_instruments_path
    shot "01-empty"

    click_link "Quarter gold coin"
    within "dialog" do
      assert_field "Symbol", with: "CEYREK"
      assert_text "1 CEYREK =", wait: 10
      shot "02-new-template"
      click_button "Create instrument"
    end

    assert_text "Custom instrument created"
    instrument = @family.custom_instruments.find_by!(symbol: "CEYREK")
    price = (BigDecimal("1.754") * BigDecimal("0.9166") * OUNCE_RATE / BigDecimal("31.1034768")).round(4)

    perform_enqueued_jobs { CustomInstrumentPriceJob.perform_now(instrument) }
    assert_equal price, instrument.latest_price.price

    visit custom_instruments_path
    assert_text "CEYREK"
    shot "03-index"

    find("a[href='#{custom_instrument_path(instrument)}']", match: :first).click
    assert_text "Price history"
    shot "04-drawer"
    click_button "Refresh price"
    assert_text "Refreshing the price"
    shot "05-after-refresh"

    visit add_units_custom_instrument_path(instrument)
    shot "06-add-units"
    visit new_trade_path(account_id: @account.id, type: "transfer_in", security: "#{instrument.security.ticker}||custom")
    assert_field "Quantity"
    assert_text "Cash does not change"
    shot "07-transfer-in"
    fill_in "Quantity", with: "10"
    click_button "Add transaction"
    assert_text "Entry created"

    Account::Syncer.new(@account).send(:materialize_balances)
    holding = @account.reload.holdings.where(security: instrument.security).order(:date).last
    assert_equal 10, holding.qty
    assert_in_delta 10 * price, holding.amount, 0.01
    assert_equal 0, @account.balances.order(:date).last.cash_balance

    visit account_path(@account, tab: "holdings")
    assert_text "10 CEYREK"
    shot "08-holdings"
    click_link "Quarter gold coin"
    assert_text "Formula"
    assert_text "Added 10 units of CEYREK"
    assert_no_text "10 shares"
    shot "09-holding-drawer"
  end

  test "reports formula errors live and prices a custom bucket" do
    visit custom_instruments_path
    find("a[href='#{new_custom_instrument_path}']", match: :first).click

    within "dialog" do
      fill_in "Name", with: "My bucket"
      fill_in "Symbol", with: "cbk"
      fill_in "Formula", with: "0,0517 * XAU"
      assert_text "Use a dot for decimals", wait: 10
      shot "10-error"

      fill_in "Formula", with: "1 * XAU + "
      click_button "Insert XAG"
      assert_field "Formula", with: /1 \* XAU \+ XAG/
      assert_text "1 CBK =", normalize_ws: true, wait: 10
      shot "11-bucket"
      click_button "Create instrument"
    end

    assert_text "Custom instrument created"
    assert_equal "CBK", @family.custom_instruments.sole.symbol

    page.current_window.resize_to(390, 844)
    visit custom_instruments_path
    shot "12-mobile"
    visit edit_custom_instrument_path(@family.custom_instruments.sole)
    shot "13-mobile-edit"
  end

  test "creates the missing account from add units and comes back to add them" do
    @family.accounts.where(accountable_type: %w[Investment Crypto]).find_each(&:destroy!)
    instrument = @family.custom_instruments.create!(name: "Gram gold", symbol: "GRAU", currency: "TRY", formula: "XAU / 31.1034768")

    visit custom_instruments_path
    find("a[href='#{add_units_custom_instrument_path(instrument)}']", match: :first, visible: :all).tap { |link| visit link[:href] }
    click_link "New investment account"
    within "dialog" do
      fill_in "Account name", with: "Gold coins"
      fill_in "account[balance]", with: "0"
      click_button "Create Account"
    end

    assert_text "Add units already owned"
    assert_equal "GRAU - Gram gold", find("input[role='combobox']").value
    shot "15-back-to-add-units"
    fill_in "Quantity", with: "5"
    click_button "Add transaction"
    assert_text "Entry created"
    assert_equal 5, @family.accounts.find_by!(name: "Gold coins").trades.sole.qty
  end

  test "offers instruments in the trade form before anything is typed" do
    @family.custom_instruments.create!(name: "Gram gold", symbol: "GRAU", currency: "TRY", formula: "XAU / 31.1034768")

    visit new_trade_path(account_id: @account.id)
    find("input[role='combobox']", match: :first).click
    assert_text "Gram gold", wait: 10
    shot "14-combobox"
  end

  private
    # Set SCREENSHOTS=/some/dir to keep a visual record of the walkthrough.
    def shot(name)
      return if ENV["SCREENSHOTS"].blank?

      sleep 0.6
      page.save_screenshot(File.join(ENV["SCREENSHOTS"], "#{name}.png"))
    end
end
