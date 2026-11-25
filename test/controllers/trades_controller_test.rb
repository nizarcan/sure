require "test_helper"

class TradesControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest, EntriesTestHelper
  include GoalPledgeTestHelper
  include CustomInstrumentTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:trade)
  end

  # The header used to read the amount's sign and call every trade a buy or a
  # sell, so an inbound transfer — Questrade journals one, and so do the
  # self-custody wallets — was shown as a purchase it never was.
  test "the header calls a labelled trade what it is, not a buy or a sell" do
    @entry.trade.update!(investment_activity_label: "Transfer")

    get trade_url(@entry)

    assert_response :success
    # Scoped to the header's own line: "Buy" also appears in the quick-edit
    # picker further down the page.
    assert_select "span.text-secondary.text-sm", text: I18n.t("trades.header.transfer")
    assert_select "span.text-secondary.text-sm", text: I18n.t("trades.header.buy"), count: 0
  end

  test "the German header localizes supported provider activity labels" do
    @user.update!(locale: "de")

    translations = {
      "Buy" => "Kaufen",
      "Contribution" => "Einlage",
      "Dividend" => "Dividende",
      "Exchange" => "Umtausch",
      "Fee" => "Gebühr",
      "Interest" => "Zinsen",
      "Other" => "Sonstige",
      "Reinvestment" => "Reinvestition",
      "Sell" => "Verkaufen",
      "Sweep In" => "Sweep In",
      "Sweep Out" => "Sweep Out",
      "Transfer" => "Überweisung",
      "Withdrawal" => "Entnahme"
    }

    assert_equal Trade::ACTIVITY_LABELS.sort, translations.keys.sort

    translations.each do |activity_label, translation|
      key = activity_label.parameterize(separator: "_")

      assert_equal translation,
                   I18n.t("trades.header.#{key}", locale: :de, fallback: false, default: nil)

      @entry.trade.update!(investment_activity_label: activity_label)

      get trade_url(@entry)

      assert_response :success
      assert_select "span.text-secondary.text-sm", text: translation
    end
  end

  test "an unlabelled trade still reads from the amount" do
    @entry.trade.update!(investment_activity_label: nil)

    get trade_url(@entry)

    assert_response :success
    expected = @entry.amount.positive? ? I18n.t("trades.header.buy") : I18n.t("trades.header.sell")
    assert_select "span.text-secondary.text-sm", text: expected
  end

  # A label this view has no wording for must not blank the line out.
  test "an unknown label falls back rather than rendering nothing" do
    @entry.trade.update!(investment_activity_label: "Sweep In")
    I18n.backend.store_translations(:en, trades: { header: { sweep_in: nil } })

    get trade_url(@entry)

    assert_response :success
    expected = @entry.amount.positive? ? I18n.t("trades.header.buy") : I18n.t("trades.header.sell")
    assert_select "span.text-secondary.text-sm", text: expected
  ensure
    I18n.reload!
  end

  test "updates trade entry" do
    assert_no_difference [ "Entry.count", "Trade.count" ] do
      patch trade_url(@entry), params: {
        entry: {
          currency: "USD",
          entryable_attributes: {
            id: @entry.entryable_id,
            qty: 20,
            price: 20
          }
        }
      }
    end

    @entry.reload

    assert_enqueued_with job: SyncJob

    assert_equal 20, @entry.trade.qty
    assert_equal 20, @entry.trade.price
    assert_equal "USD", @entry.currency

    assert_redirected_to account_url(@entry.account)
  end

  test "creates deposit entry" do
    from_account = accounts(:depository) # Account the deposit is coming from

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2,
                      -> { Transfer.count } => 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "deposit",
          date: Date.current,
          amount: 10,
          currency: "USD",
          transfer_account_id: from_account.id
        }
      }
    end

    assert_redirected_to @entry.account
  end

  # A deposit or withdrawal books an entry on the other account too, so that
  # account needs write permission, not just the investment account.
  test "a withdrawal cannot book into an account the member may only read" do
    sign_in_as_member_with_writable_investment

    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      post trades_url(account_id: @investment.id), params: {
        model: { type: "withdrawal", date: Date.current, amount: 10, currency: "USD", transfer_account_id: accounts(:credit_card).id }
      }
    end

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "a deposit cannot draw from another member's private account" do
    sign_in_as_member_with_writable_investment

    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      post trades_url(account_id: @investment.id), params: {
        model: { type: "deposit", date: Date.current, amount: 10, currency: "USD", transfer_account_id: accounts(:connected).id }
      }
    end

    assert_response :not_found
  end

  test "a member can still book a withdrawal into an account shared with full control" do
    sign_in_as_member_with_writable_investment

    assert_difference -> { Transfer.count } => 1 do
      post trades_url(account_id: @investment.id), params: {
        model: { type: "withdrawal", date: Date.current, amount: 10, currency: "USD", transfer_account_id: accounts(:depository).id }
      }
    end

    assert_redirected_to @investment
  end

  test "the transfer account picker only offers accounts the member may write to" do
    sign_in_as_member_with_writable_investment

    get new_trade_url(account_id: @investment.id, type: "withdrawal")

    assert_response :success
    assert_select "input[type=hidden][name='model[transfer_account_id]']"
    assert_select "[role=option][data-value='#{accounts(:depository).id}']"
    assert_select "[role=option][data-value='#{accounts(:credit_card).id}']", count: 0
    assert_select "[role=option][data-value='#{accounts(:connected).id}']", count: 0
  end

  test "creates withdrawal entry" do
    to_account = accounts(:depository) # Account the withdrawal is going to

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2,
                      -> { Transfer.count } => 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "withdrawal",
          date: Date.current,
          amount: 10,
          currency: "USD",
          transfer_account_id: to_account.id
        }
      }
    end

    assert_redirected_to @entry.account
  end

  test "deposit and withdrawal has optional transfer account" do
    assert_difference -> { Entry.count } => 1,
                      -> { Transaction.count } => 1,
                      -> { Transfer.count } => 0 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "withdrawal",
          date: Date.current,
          amount: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.positive?
    assert_redirected_to @entry.account
  end

  test "creates interest entry as trade with synthetic cash security when no ticker given" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "interest",
          date: Date.current,
          amount: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade?
    assert created_entry.trade.security.cash?
    assert_equal "Interest", created_entry.name
    assert_redirected_to @entry.account
  end

  test "creates interest entry as trade with security when ticker given" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "interest",
          date: Date.current,
          amount: 10,
          currency: "USD",
          ticker: "AAPL|XNAS"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade?
    assert_equal "AAPL", created_entry.trade.security.ticker
    assert_equal "Interest: AAPL", created_entry.name
    assert_redirected_to @entry.account
  end

  test "creates dividend entry as trade with required security" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "dividend",
          date: Date.current,
          amount: 25,
          currency: "USD",
          ticker: "AAPL|XNAS"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade?
    assert_equal 0, created_entry.trade.qty
    assert_equal "AAPL", created_entry.trade.security.ticker
    assert_equal "Dividend: AAPL", created_entry.name
    assert_equal "Dividend", created_entry.trade.investment_activity_label
    assert_redirected_to @entry.account
  end

  test "creating dividend without security returns error" do
    assert_no_difference [ "Entry.count", "Trade.count" ] do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "dividend",
          date: Date.current,
          amount: 25,
          currency: "USD"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "creates trade buy entry with fee" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: "NVDA (NASDAQ)",
          qty: 10,
          price: 20,
          fee: 9.95,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert_in_delta 209.95, created_entry.amount.to_f, 0.001
    assert_in_delta 9.95, created_entry.trade.fee.to_f, 0.001
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade sell entry with fee" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "sell",
          date: Date.current,
          ticker: "AAPL (NYSE)",
          qty: 10,
          price: 20,
          fee: 9.95,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    # sell: signed_amount = -10 * 20 + 9.95 = -190.05
    assert_in_delta(-190.05, created_entry.amount.to_f, 0.001)
    assert_in_delta 9.95, created_entry.trade.fee.to_f, 0.001
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade buy entry without fee defaults to zero" do
    post trades_url(account_id: @entry.account_id), params: {
      model: {
        type: "buy",
        date: Date.current,
        ticker: "NVDA (NASDAQ)",
        qty: 10,
        price: 20,
        currency: "USD"
      }
    }

    created_entry = Entry.order(created_at: :desc).first

    assert_in_delta 200, created_entry.amount.to_f, 0.001
    assert_equal 0, created_entry.trade.fee.to_f
  end

  test "update includes fee in amount" do
    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        nature: "outflow",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 10,
          price: 20,
          fee: 9.95
        }
      }
    }

    @entry.reload

    assert_in_delta 209.95, @entry.amount.to_f, 0.001
    assert_in_delta 9.95, @entry.trade.fee.to_f, 0.001
  end

  test "creates trade buy entry" do
    assert_difference [ "Entry.count", "Trade.count", "Security.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: "NVDA (NASDAQ)",
          qty: 10,
          price: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.positive?
    assert created_entry.trade.qty.positive?
    assert_equal "Entry created", flash[:notice]
    assert_enqueued_with job: SyncJob
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade sell entry" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "sell",
          ticker: "AAPL (NYSE)",
          date: Date.current,
          currency: "USD",
          qty: 10,
          price: 10
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade.qty.negative?
    assert_equal "Entry created", flash[:notice]
    assert_enqueued_with job: SyncJob
    assert_redirected_to account_url(created_entry.account)
  end

  test "unlock clears protection flags on user-modified entry" do
    # Mark as protected with locked_attributes on both entry and entryable
    @entry.update!(user_modified: true, locked_attributes: { "name" => Time.current.iso8601 })
    @entry.trade.update!(locked_attributes: { "qty" => Time.current.iso8601 })

    assert @entry.reload.protected_from_sync?

    post unlock_trade_path(@entry.trade)

    assert_redirected_to account_path(@entry.account)
    assert_equal "Entry unlocked. It may be updated on next sync.", flash[:notice]

    @entry.reload
    assert_not @entry.user_modified?
    assert_empty @entry.locked_attributes, "Entry locked_attributes should be cleared"
    assert_empty @entry.trade.locked_attributes, "Trade locked_attributes should be cleared"
    assert_not @entry.protected_from_sync?
  end

  test "unlock clears import_locked flag" do
    @entry.update!(import_locked: true)

    assert @entry.reload.protected_from_sync?

    post unlock_trade_path(@entry.trade)

    assert_redirected_to account_path(@entry.account)
    @entry.reload
    assert_not @entry.import_locked?
    assert_not @entry.protected_from_sync?
  end

  test "update locks saved attributes" do
    assert_not @entry.user_modified?
    assert_empty @entry.trade.locked_attributes

    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }

    @entry.reload
    assert @entry.user_modified?
    assert @entry.trade.locked_attributes.key?("qty")
    assert @entry.trade.locked_attributes.key?("price")
  end

  test "turbo stream update includes lock icon for protected entry" do
    assert_not @entry.user_modified?

    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        nature: "outflow",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
    # The turbo stream should contain the lock icon link with protection tooltip
    assert_match(/title="Protected from sync"/, response.body)
    # And should contain the lock SVG (the path for lock icon)
    assert_match(/M7 11V7a5 5 0 0 1 10 0v4/, response.body)
  end

  test "quick edit badge update locks activity label" do
    assert_not @entry.user_modified?
    assert_empty @entry.trade.locked_attributes
    original_label = @entry.trade.investment_activity_label

    # Mimic the quick edit badge JSON request
    patch trade_url(@entry),
      params: {
        entry: {
          entryable_attributes: {
            id: @entry.entryable_id,
            investment_activity_label: original_label == "Buy" ? "Sell" : "Buy"
          }
        }
      }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "text/vnd.turbo-stream.html"
      }

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
    # The turbo stream should contain the lock icon
    assert_match(/title="Protected from sync"/, response.body)

    @entry.reload
    assert @entry.user_modified?, "Entry should be marked as user_modified"
    assert @entry.trade.locked_attributes.key?("investment_activity_label"), "investment_activity_label should be locked"
    assert @entry.protected_from_sync?, "Entry should be protected from sync"
  end

  test "the drawer offers the lot choice only on a fifo sale" do
    account, buy, sale = lot_choice_account
    lot_select = "select[name='entry[entryable_attributes][lot_source_entry_id]']"

    get trade_url(sale)
    assert_select lot_select, count: 0

    account.update!(cost_basis_method: "fifo")
    get trade_url(sale)
    assert_select "#{lot_select} option[value='#{buy.id}']", count: 1

    get trade_url(buy)
    assert_select lot_select, count: 0
  end

  test "naming a lot on a sale saves it and restates the account" do
    account, buy, sale = lot_choice_account(method: "fifo")

    patch trade_url(sale), params: { entry: { entryable_attributes: { id: sale.entryable_id, lot_source_entry_id: buy.id } } }

    assert_redirected_to account_url(account)
    assert_enqueued_with job: SyncJob
    assert_equal buy.id, sale.trade.reload.lot_source_entry_id
  end

  test "naming another account's lot on a sale is refused" do
    _account, _buy, sale = lot_choice_account(method: "fifo")
    other = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Investment.new, cost_basis_method: "fifo")
    theirs = create_trade(sale.trade.security, account: other, qty: 5, price: 10, date: 3.days.ago.to_date)

    patch trade_url(sale), params: { entry: { entryable_attributes: { id: sale.entryable_id, lot_source_entry_id: theirs.id } } }

    assert_response :unprocessable_entity
    assert_nil sale.trade.reload.lot_source_entry_id
  end

  # we-promise/sure#4226: a deposit with no "from" account books a standalone
  # inflow on the investment account, which must resolve its pledge.
  test "an unlinked deposit resolves the account's open transfer pledge" do
    investment = accounts(:investment)
    pledge = open_transfer_pledge(investment, amount: 250)

    post trades_url(account_id: investment.id), params: {
      model: { type: "deposit", date: Date.current, amount: 250, currency: "USD" }
    }

    entry = investment.entries.order(:created_at).last
    assert_equal entry.transaction.id, pledge.reload.matched_transaction_id
  end

  test "an unlinked withdrawal leaves the pledge open" do
    investment = accounts(:investment)
    pledge = open_transfer_pledge(investment, amount: 250)

    post trades_url(account_id: investment.id), params: {
      model: { type: "withdrawal", date: Date.current, amount: 250, currency: "USD" }
    }

    assert_equal "open", pledge.reload.status
  end

  # ------------------------------------------------ custom instruments

  test "creates a buy for a custom instrument picked in the combobox" do
    instrument = create_custom_instrument(family: @entry.account.family)

    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: instrument.security.to_combobox_option.id,
          qty: 10,
          price: 20,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first
    assert_equal instrument.security, created_entry.trade.security
    assert_equal "Buy 10.0 shares of GRAU", created_entry.name
    assert_redirected_to account_url(created_entry.account)
  end

  test "adds units already owned without moving cash and values them at market" do
    family = @entry.account.family
    account = family.accounts.create!(
      name: "Opening units", currency: "USD", balance: 0, cash_balance: 0, accountable: Investment.new
    )
    instrument = create_custom_instrument(family: family)
    Security::Price.create!(security: instrument.security, date: Date.current, price: 25, currency: "USD")

    account.entries.create!(name: "Deposit", date: Date.current, amount: -1000, currency: "USD", entryable: Transaction.new)
    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    assert_equal 1000, account.reload.cash_balance.to_d

    assert_difference "Trade.count", 1 do
      post trades_url(account_id: account.id), params: {
        model: {
          type: Trade::CreateForm::OPENING_TYPE,
          date: Date.current,
          qty: 10,
          currency: "USD",
          ticker: instrument.security.to_combobox_option.id
        }
      }
    end

    assert_redirected_to account_url(account)
    created_entry = account.entries.where(entryable_type: "Trade").order(:created_at).last
    assert_equal "Added 10 units of GRAU", created_entry.name
    assert_equal 0, created_entry.amount.to_d
    assert_equal Trade::TRANSFER_LABEL, created_entry.trade.investment_activity_label

    Balance::Materializer.new(account.reload, strategy: :forward).materialize_balances

    holding = account.holdings.find_by!(security: instrument.security, date: Date.current)
    assert_equal BigDecimal("10"), holding.qty
    assert_equal BigDecimal("250"), holding.amount.to_d
    assert_equal 1000, account.reload.cash_balance.to_d, "units already owned must not move cash"
  end

  test "rejects another family's custom instrument id and re-renders the form" do
    foreign = create_custom_instrument(family: families(:empty), symbol: "FOREIGN")

    assert_no_difference [ "Entry.count", "Trade.count" ] do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: foreign.security.to_combobox_option.id,
          qty: 1,
          price: 10,
          currency: "USD"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form[action=?]", trades_path(account_id: @entry.account_id)
  end

  test "rejects an archived custom instrument" do
    instrument = create_custom_instrument(family: @entry.account.family)
    instrument.archive!

    assert_no_difference [ "Entry.count", "Trade.count" ] do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: instrument.security.to_combobox_option.id,
          qty: 1,
          price: 10,
          currency: "USD"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "a typed symbol resolves to the family's custom instrument" do
    instrument = create_custom_instrument(family: @entry.account.family)

    assert_difference "Trade.count", 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          manual_ticker: "grau",
          qty: 1,
          price: 10,
          currency: "USD"
        }
      }
    end

    assert_equal instrument.security, Entry.order(created_at: :desc).first.trade.security
  end

  test "the new form preselects a family custom instrument" do
    instrument = create_custom_instrument(family: @entry.account.family)
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: Trade::CreateForm::OPENING_TYPE)

    assert_response :success
    assert_select "input[type=hidden][name='model[ticker]'][value=?]", id
    assert_select "fieldset[data-hw-combobox-prefilled-display-value=?]", "GRAU - Gram gold"
  end

  test "the new form ignores a custom instrument from another family" do
    create_custom_instrument(family: @entry.account.family, symbol: "OWN")
    foreign = create_custom_instrument(family: families(:empty), symbol: "FOREIGN")

    get new_trade_url(
      account_id: @entry.account_id,
      security: foreign.security.to_combobox_option.id,
      type: Trade::CreateForm::OPENING_TYPE
    )

    assert_response :success
    assert_select "input[type=hidden][name='model[ticker]'][value=?]", foreign.security.to_combobox_option.id, count: 0
    fieldset = css_select("fieldset.hw-combobox").first
    assert fieldset, "expected the security combobox"
    assert_nil fieldset["data-hw-combobox-prefilled-display-value"]
  end

  test "a rejected transfer_in re-renders the form with the entered quantity" do
    instrument = create_custom_instrument(family: @entry.account.family)
    id = instrument.security.to_combobox_option.id

    post trades_url(account_id: @entry.account_id), params: {
      model: { type: Trade::CreateForm::OPENING_TYPE, date: Date.current, qty: 0, currency: "USD", ticker: id }
    }

    assert_response :unprocessable_entity
    assert_select "select[name='model[type]'] option[selected][value=?]", Trade::CreateForm::OPENING_TYPE
    assert_select "input[name='model[qty]'][value=?]", "0"
    assert_select "input[type=hidden][name='model[ticker]'][value=?]", id
    assert_select "p", text: I18n.t("trades.form.qty_must_be_positive")
  end

  test "the transfer_in form shows quantity but not price or fee" do
    instrument = create_custom_instrument(family: @entry.account.family)
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: Trade::CreateForm::OPENING_TYPE)

    assert_response :success
    assert_select "input[name='model[qty]']", count: 1
    assert_select "input[name='model[price]']", count: 0
    assert_select "input[name='model[fee]']", count: 0
    assert_select "input[type=hidden][name='model[currency]'][value=?]", @entry.account.currency
    assert_select "select[name='model[type]'] option[value=?]", Trade::CreateForm::OPENING_TYPE
    assert_select "p", text: I18n.t("trades.form.transfer_in_hint")
  end

  test "switching type keeps the preselected instrument and account in the URL" do
    instrument = create_custom_instrument(family: @entry.account.family)
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: "buy")

    assert_response :success
    select = css_select("select[name='model[type]']").first
    url_param = select["data-trade-form-url-param"]
    assert_includes url_param, "security="
    assert_includes url_param, "account_id=#{@entry.account_id}"
  end

  test "a preselected custom instrument labels the price per unit and hints at the current price" do
    instrument = create_custom_instrument(family: @entry.account.family)
    Security::Price.create!(security: instrument.security, date: Date.current, price: 123.45, currency: "USD")
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: "buy")

    assert_response :success
    assert_select "label", text: /#{Regexp.escape(I18n.t("trades.form.price_per_unit"))}/
    assert_select "p", text: /#{Regexp.escape(I18n.t("trades.form.current_price_hint", price: "").strip)}.*123\.45/
    assert_equal "", css_select("input[name='model[price]']").first["value"].to_s
  end

  test "the current-price hint is left out when the price is in another currency" do
    instrument = create_custom_instrument(family: @entry.account.family)
    Security::Price.create!(security: instrument.security, date: Date.current, price: 123.45, currency: "EUR")
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: "buy")

    assert_response :success
    assert_select "p", text: /#{Regexp.escape(I18n.t("trades.form.current_price_hint", price: "").strip)}/, count: 0
  end

  test "editing the quantity of an added-units trade keeps its transfer wording" do
    instrument = create_custom_instrument(family: @entry.account.family, symbol: "CEYREK")
    entry = Trade::CreateForm.new(
      account: @entry.account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: 10,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create
    assert entry.persisted?, entry.errors.full_messages.to_sentence

    patch trade_url(entry), params: {
      entry: {
        nature: "outflow",
        entryable_attributes: { id: entry.entryable_id, qty: 12, price: 0, fee: 0 }
      }
    }

    assert_redirected_to account_url(@entry.account)
    entry.reload
    assert_equal "Added 12 units of CEYREK", entry.name
    assert_equal Trade::TRANSFER_LABEL, entry.trade.investment_activity_label
    assert_equal 0, entry.amount.to_d
    assert_equal BigDecimal("12"), entry.trade.qty
  end

  test "a tampered model param does not break the new trade form" do
    instrument = create_custom_instrument(family: @entry.account.family)
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: "buy", model: "not-a-hash")

    assert_response :success
    assert_select "form[data-controller='trade-form']"
  end

  test "the new form preselects an archived instrument for a sale" do
    instrument = create_custom_instrument(family: @entry.account.family, symbol: "ARCHD")
    instrument.archive!
    id = instrument.security.to_combobox_option.id

    get new_trade_url(account_id: @entry.account_id, security: id, type: "sell")

    assert_response :success
    assert_select "fieldset[data-hw-combobox-prefilled-display-value=?]", "ARCHD - Gram gold"
  end

  test "the trade header shows the instrument symbol" do
    instrument = create_custom_instrument(family: @entry.account.family)
    entry = Trade::CreateForm.new(
      account: @entry.account,
      type: "buy",
      date: Date.current,
      qty: 1,
      price: 10,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    get trade_url(entry)

    assert_response :success
    assert_includes response.body, "GRAU"
    assert_not_includes response.body, "CUSTOM-"
  end

  test "the header hides purchase price and return for an unpriced internal movement" do
    instrument = create_custom_instrument(family: @entry.account.family)
    entry = Trade::CreateForm.new(
      account: @entry.account,
      type: Trade::CreateForm::OPENING_TYPE,
      date: Date.current,
      qty: 10,
      currency: "USD",
      ticker: instrument.security.to_combobox_option.id
    ).create

    get trade_url(entry)

    assert_response :success
    assert_select "dt", text: I18n.t("trades.header.purchase_qty_label")
    assert_select "dt", text: I18n.t("trades.header.purchase_price_label"), count: 0
    assert_select "dt", text: I18n.t("trades.header.total_return_label"), count: 0
    assert_select "span.text-secondary.text-sm", text: I18n.t("trades.header.transfer")
  end

  test "an instrument account's trade form sends to its unit form" do
    instrument = create_custom_instrument(family: @user.family, name: "Gram gold", symbol: "GRAU")
    account = @user.family.accounts.create!(
      owner: @user, name: "Gold units", currency: instrument.currency, balance: 0,
      cash_balance: 0, accountable: Investment.new, custom_instrument: instrument
    )

    get new_trade_url(account_id: account.id)

    assert_redirected_to new_account_unit_balance_path(account, mode: "add")
  end

  private
    def lot_choice_account(method: "average")
      account = accounts(:investment)
      account.update!(cost_basis_method: method)
      security = Security.create!(ticker: "LOTN", name: "LOTN")
      buy = create_trade(security, account: account, qty: 40, price: 20, date: 3.days.ago.to_date)
      sale = create_trade(security, account: account, qty: -10, price: 25, date: 1.day.ago.to_date)
      [ account, buy, sale ]
    end

    # family_member gets the investment account with full control; fixtures
    # already share depository with full control and credit_card read-only,
    # and leave connected private to family_admin.
    def sign_in_as_member_with_writable_investment
      @investment = accounts(:investment)
      @investment.account_shares.create!(user: users(:family_member), permission: "full_control")
      sign_in users(:family_member)
    end
end
