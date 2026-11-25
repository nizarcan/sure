require "test_helper"

class CustomInstrumentsControllerTest < ActionDispatch::IntegrationTest
  include CustomInstrumentTestHelper
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user

    CustomInstrument::RateSource.stubs(:current).returns({ rate: BigDecimal("1"), date: Date.current })

    @instrument = create_custom_instrument(family: @family)
    clear_enqueued_jobs
  end

  test "index lists active instruments and links to the settings nav entry" do
    get custom_instruments_url

    assert_response :success
    assert_select "#active_custom_instruments ##{dom_id(@instrument)}", count: 1
    assert_select "a[href='#{new_custom_instrument_path}']"

    get tags_url
    assert_select "a[href='#{custom_instruments_path}']", text: I18n.t("settings.settings_nav.custom_instruments_label")
  end

  test "index shows the latest price, the 30-day change and held positions" do
    @instrument.security.prices.create!(date: 40.days.ago.to_date, price: 80, currency: "USD")
    @instrument.security.prices.create!(date: 2.days.ago.to_date, price: 100, currency: "USD")
    Holding.create!(
      account: accounts(:investment),
      security: @instrument.security,
      date: Date.current,
      qty: 2.5,
      price: 100,
      amount: 250,
      currency: "USD"
    )

    get custom_instruments_url

    assert_response :success
    assert_includes response.body, Money.new(100, "USD").format
    assert_includes response.body, I18n.t("custom_instruments.index.held", qty: "2.5", count: 1)
  end

  test "index does not show another family's instrument" do
    other = create_custom_instrument(family: families(:empty), name: "Other gold", symbol: "OTHERG")

    get custom_instruments_url

    assert_response :success
    assert_select "##{dom_id(other)}", count: 0
    assert_not_includes response.body, "OTHERG"
  end

  test "index only counts positions in accounts the user can see" do
    private_account = create_private_investment_account(qty: 4)

    get custom_instruments_url

    assert_response :success
    assert_includes response.body, I18n.t("custom_instruments.index.not_held")
    assert_not_includes response.body, private_account.name
  end

  test "new preselects a template" do
    get new_custom_instrument_url(template: "ceyrek")

    assert_response :success
    assert_select "input[name='custom_instrument[symbol]'][value='CEYREK']"
    assert_select "input[name='custom_instrument[name]'][value='#{I18n.t("custom_instruments.templates.ceyrek.name")}']"
    assert_select "textarea[name='custom_instrument[formula]']", text: /1\.754 \* 0\.9166 \* XAU \/ 31\.1034768/
  end

  test "new ignores an unknown template" do
    get new_custom_instrument_url(template: "does_not_exist")

    assert_response :success
    assert_select "input[name='custom_instrument[symbol]'][value='CEYREK']", count: 0
  end

  test "creates an instrument and redirects to the index" do
    assert_difference("CustomInstrument.count") do
      post custom_instruments_url, params: {
        custom_instrument: { name: "Silver gram", symbol: "GRAS", formula: "XAG / 31.1034768", currency: "USD" }
      }
    end

    assert_redirected_to custom_instruments_url
    assert_equal I18n.t("custom_instruments.created"), flash[:notice]
  end

  test "create honours a local return_to and ignores an external one" do
    post custom_instruments_url, params: {
      return_to: tags_path,
      custom_instrument: { name: "Silver gram", symbol: "GRAS", formula: "XAG / 31.1034768", currency: "USD" }
    }
    assert_redirected_to tags_url

    post custom_instruments_url, params: {
      return_to: "https://evil.example.com/phish",
      custom_instrument: { name: "Silver kilo", symbol: "GRASKG", formula: "1000 * XAG / 31.1034768", currency: "USD" }
    }
    assert_redirected_to custom_instruments_url
  end

  test "create from the modal frame answers with a frame redirect" do
    post custom_instruments_url,
         params: {
           custom_instrument: { name: "Silver gram", symbol: "GRAS", formula: "XAG / 31.1034768", currency: "USD" }
         },
         headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal" do
      assert_select "turbo-stream[action='redirect'][target='#{custom_instruments_path}']"
    end
  end

  test "re-renders the modal with 422 when the formula is invalid" do
    assert_no_difference("CustomInstrument.count") do
      post custom_instruments_url, params: {
        custom_instrument: { name: "Broken", symbol: "BROKEN", formula: "XAU * XAG", currency: "USD" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form"
    assert_includes response.body, "Cannot multiply two assets"
  end

  test "edit shows the recalculation warning with the affected account count" do
    Holding.create!(
      account: accounts(:investment),
      security: @instrument.security,
      date: Date.current,
      qty: 1,
      price: 10,
      amount: 10,
      currency: "USD"
    )

    get edit_custom_instrument_url(@instrument)

    assert_response :success
    assert_select "[data-custom-instrument-form-target='historyWarning']", text: /1 account holds or trades it/
  end

  test "edit compares the warning against the saved formula after a failed update" do
    saved_formula = @instrument.formula_in_database

    patch custom_instrument_url(@instrument), params: { custom_instrument: { formula: "XAU * XAG" } }

    assert_response :unprocessable_entity
    assert_select "[data-custom-instrument-form-target='historyWarning']" do |elements|
      assert_equal saved_formula, elements.first["data-custom-instrument-form-saved-formula-value"]
    end
  end

  test "updates an instrument" do
    patch custom_instrument_url(@instrument), params: { custom_instrument: { name: "Gram gold bar" } }

    assert_redirected_to custom_instruments_url
    assert_equal I18n.t("custom_instruments.updated"), flash[:notice]
    assert_equal "Gram gold bar", @instrument.reload.name
  end

  test "update re-renders with 422 when invalid" do
    patch custom_instrument_url(@instrument), params: { custom_instrument: { formula: "XAU * XAG" } }

    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "guest is read-only" do
    sign_in family_guest

    get custom_instruments_url
    assert_response :success
    assert_select "##{dom_id(@instrument)} a[href='#{custom_instrument_path(@instrument)}']", count: 1
    assert_select "##{dom_id(@instrument)} button[aria-haspopup='menu']", count: 0
    get custom_instrument_url(@instrument)
    assert_response :success

    assert_no_difference("CustomInstrument.count") do
      post custom_instruments_url, params: {
        custom_instrument: { name: "Guest", symbol: "GUESTG", formula: "XAU", currency: "USD" }
      }
    end
    assert_redirected_to accounts_url

    patch custom_instrument_url(@instrument), params: { custom_instrument: { name: "Guest renamed" } }
    assert_redirected_to accounts_url

    delete custom_instrument_url(@instrument)
    assert_redirected_to accounts_url

    post preview_custom_instruments_url, params: { formula: "XAU", currency: "USD" }
    assert_redirected_to accounts_url
  end

  test "another family's instrument is not found from every member action" do
    other = create_custom_instrument(family: families(:empty), name: "Other", symbol: "OTHERX")

    get custom_instrument_url(other)
    assert_response :not_found

    get edit_custom_instrument_url(other)
    assert_response :not_found

    get add_units_custom_instrument_url(other)
    assert_response :not_found

    patch custom_instrument_url(other), params: { custom_instrument: { name: "Hijacked" } }
    assert_response :not_found

    delete custom_instrument_url(other)
    assert_response :not_found

    post archive_custom_instrument_url(other)
    assert_response :not_found

    post unarchive_custom_instrument_url(other)
    assert_response :not_found

    post refresh_custom_instrument_url(other)
    assert_response :not_found
  end

  test "deleting an instrument in use is refused and explains why" do
    Holding.create!(
      account: accounts(:investment),
      security: @instrument.security,
      date: Date.current,
      qty: 1,
      price: 10,
      amount: 10,
      currency: "USD"
    )

    assert_no_difference("CustomInstrument.count") do
      delete custom_instrument_url(@instrument)
    end

    assert_redirected_to custom_instruments_url
    assert_equal I18n.t("custom_instruments.destroy.in_use"), flash[:alert]
  end

  test "deletes an unused instrument" do
    assert_difference("CustomInstrument.count", -1) do
      delete custom_instrument_url(@instrument)
    end

    assert_redirected_to custom_instruments_url
    assert_equal I18n.t("custom_instruments.destroy.deleted"), flash[:notice]
  end

  test "archive hides the instrument from the active list and unarchive restores it" do
    post archive_custom_instrument_url(@instrument)

    assert_redirected_to custom_instruments_url
    assert @instrument.reload.archived?

    get custom_instruments_url
    assert_select "#active_custom_instruments ##{dom_id(@instrument)}", count: 0
    assert_select "#archived_custom_instruments ##{dom_id(@instrument)}", count: 1

    post unarchive_custom_instrument_url(@instrument)
    assert_not @instrument.reload.archived?

    get custom_instruments_url
    assert_select "#active_custom_instruments ##{dom_id(@instrument)}", count: 1
  end

  test "refresh enqueues the price job" do
    assert_enqueued_with(job: CustomInstrumentPriceJob) do
      post refresh_custom_instrument_url(@instrument)
    end

    assert_redirected_to custom_instruments_url
    assert_equal I18n.t("custom_instruments.refresh.refresh_queued"), flash[:notice]
  end

  test "preview prices a formula without writing anything" do
    counts = [
      [ CustomInstrument, CustomInstrument.count ],
      [ Security, Security.count ],
      [ Security::Price, Security::Price.count ],
      [ ExchangeRate, ExchangeRate.count ]
    ]

    post preview_custom_instruments_url, params: { formula: "XAU / 31.1034768", currency: "USD", symbol: "grau" }

    assert_response :success
    assert_includes response.body, I18n.t("custom_instruments.preview.price_line", symbol: "GRAU", price: "")
    assert_includes response.body, 'data-custom-instrument-preview-state="ok"'
    counts.each { |model, count| assert_equal count, model.count, "#{model} changed" }
  end

  test "preview reports a formula error and still answers 200" do
    post preview_custom_instruments_url, params: { formula: "XAU * XAG", currency: "USD", symbol: "GRAU" }

    assert_response :success
    assert_includes response.body, "Cannot multiply two assets"
    assert_includes response.body, 'data-custom-instrument-preview-state="error"'
  end

  test "preview renders a friendly message when prices cannot be fetched" do
    CustomInstrument::RateSource.stubs(:current).raises(StandardError.new("network down"))

    post preview_custom_instruments_url, params: { formula: "XAU / 31.1034768", currency: "USD", symbol: "GRAU" }

    assert_response :success
    assert_includes response.body, I18n.t("custom_instruments.preview.price_fetch_failed")
  end

  test "show renders the price, breakdown, chart and visible positions" do
    @instrument.security.prices.create!(date: 20.days.ago.to_date, price: 4, currency: "USD")
    @instrument.security.prices.create!(date: Date.current, price: 5, currency: "USD")
    Holding.create!(
      account: accounts(:investment),
      security: @instrument.security,
      date: Date.current,
      qty: 2.5,
      price: 5,
      amount: 12.5,
      currency: "USD"
    )

    get custom_instrument_url(@instrument)

    assert_response :success
    assert_select "turbo-frame#drawer"
    assert_includes response.body, @instrument.formula
    assert_includes response.body, accounts(:investment).name
    assert_includes response.body, I18n.t("custom_instruments.show.chart_title")
    assert_select "[data-controller='time-series-chart']"
    assert_select "form[action='#{refresh_custom_instrument_path(@instrument)}'][data-turbo-frame='_top']"
  end

  test "show hides positions in accounts not shared with the user" do
    @instrument.security.prices.create!(date: 2.days.ago.to_date, price: 5, currency: "USD")
    private_account = create_private_investment_account(qty: 4)

    get custom_instrument_url(@instrument)

    assert_response :success
    assert_not_includes response.body, private_account.name
    assert_includes response.body, I18n.t("custom_instruments.show.no_positions")
  end

  test "add units lists only writable manual investment and crypto accounts" do
    get add_units_custom_instrument_url(@instrument)

    assert_response :success

    assert_select "turbo-frame#modal" do
      assert_select "a[href*='/trades/new']", count: 2
      assert_select "a[href*='account_id=#{accounts(:investment).id}']", count: 1
      assert_select "a[href*='account_id=#{accounts(:crypto).id}']", count: 1
      assert_select "a[href*='account_id=#{accounts(:depository).id}']", count: 0
      assert_select "a[href*='security=#{ERB::Util.url_encode("#{@instrument.security.ticker}||custom")}']", count: 2
      assert_select "a[href*='type=transfer_in']", count: 2
    end
  end

  test "add units on an archived instrument redirects with an alert" do
    @instrument.archive!

    get add_units_custom_instrument_url(@instrument)

    assert_redirected_to custom_instruments_url
    assert_equal I18n.t("custom_instruments.add_units.archived"), flash[:alert]
  end

  test "add units without an eligible account offers to create one" do
    sign_in users(:family_member)

    get add_units_custom_instrument_url(@instrument)

    assert_response :success
    assert_includes response.body, I18n.t("custom_instruments.add_units.empty_title")
    return_path = add_units_custom_instrument_path(@instrument, account_created: 1)
    assert_select "a[href='#{new_investment_path(return_to: return_path)}']", text: I18n.t("custom_instruments.add_units.empty_action")
  end

  test "creating the offered account returns to adding units in it" do
    member = users(:family_member)
    sign_in member
    return_path = add_units_custom_instrument_path(@instrument, account_created: 1)

    post investments_url, params: { account: {
      name: "Physical gold", balance: 0, currency: "USD", accountable_type: "Investment", return_to: return_path
    } }
    assert_redirected_to return_path

    account = @family.accounts.find_by!(name: "Physical gold")
    follow_redirect!
    assert_redirected_to new_trade_path(
      account_id: account.id, type: Trade::CreateForm::OPENING_TYPE, security: "#{@instrument.security.ticker}||custom"
    )
  end

  test "after an account is created with several to choose from, add units still asks which" do
    get add_units_custom_instrument_url(@instrument, account_created: 1)

    assert_response :success
  end

  test "add units is unavailable to a guest" do
    sign_in family_guest

    get add_units_custom_instrument_url(@instrument)

    assert_redirected_to accounts_url
  end

  test "every page renders its copy in English and Turkish without missing translations" do
    @instrument.security.prices.create!(date: 40.days.ago.to_date, price: 80, currency: "USD")
    @instrument.security.prices.create!(date: Date.current, price: 100, currency: "USD")
    Holding.create!(
      account: accounts(:investment),
      security: @instrument.security,
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )

    stale = create_custom_instrument(family: @family, name: "Stale silver", symbol: "STALESIL")
    stale.security.prices.create!(date: 10.days.ago.to_date, price: 5, currency: "USD")

    archived = create_custom_instrument(family: @family, name: "Archived gold", symbol: "ARCHG")
    archived.archive!
    clear_enqueued_jobs

    %w[en tr].each do |locale|
      @user.update!(locale: locale)

      [
        custom_instruments_url,
        custom_instrument_url(@instrument),
        new_custom_instrument_url,
        edit_custom_instrument_url(@instrument),
        add_units_custom_instrument_url(@instrument)
      ].each do |path|
        get path
        assert_response :success
        assert_no_missing_translation
      end

      post preview_custom_instruments_url, params: { formula: "XAU / 31.1034768", currency: "USD", symbol: "cbk" }
      assert_response :success
      assert_no_missing_translation
      assert_includes response.body, "1 CBK ="
    end
  end

  test "index shows the empty state and the archived disclosure when only archived instruments exist" do
    @instrument.archive!

    get custom_instruments_url

    assert_response :success
    assert_select "#active_custom_instruments", count: 0
    assert_includes response.body, I18n.t("custom_instruments.index.empty_title")
    assert_select "#archived_custom_instruments ##{dom_id(@instrument)}", count: 1
  end

  test "index shows the empty state when no instruments exist" do
    @instrument.destroy!

    get custom_instruments_url

    assert_response :success
    assert_includes response.body, I18n.t("custom_instruments.index.empty_title")
    assert_select "#archived_custom_instruments", count: 0
  end

  private
    def assert_no_missing_translation
      assert_not_includes response.body, "translation_missing"
      assert_not_includes response.body, "translation missing"
      assert_not_includes response.body, "Translation missing"
    end

    def create_private_investment_account(qty:)
      account = Account.create!(
        family: @family,
        owner: users(:family_member),
        name: "Jakob Private Brokerage",
        currency: "USD",
        status: "active",
        balance: 0,
        accountable: Investment.new
      )

      Holding.create!(
        account: account,
        security: @instrument.security,
        date: Date.current,
        qty: qty,
        price: 5,
        amount: qty * 5,
        currency: "USD"
      )

      account
    end
end
