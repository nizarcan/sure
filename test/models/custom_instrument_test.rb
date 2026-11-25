require "test_helper"

class CustomInstrumentTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment)
    @user = users(:family_admin)
  end

  test "builds its security, syncs the name and writes components in formula order" do
    instrument = create_custom_instrument(family: @family, name: "Gram gold", symbol: "grau", formula: "1 * XAU + 2 * TRY")

    assert_equal "GRAU", instrument.symbol
    assert instrument.security.custom?
    assert_match(/\ACUSTOM-/, instrument.security.ticker)
    assert_not instrument.security.offline?
    assert_equal "Gram gold", instrument.security.name
    assert_equal [ "XAU", "TRY" ], instrument.components.map { |component| component.currency || component.security.ticker }
    assert_equal [ 0, 1 ], instrument.components.map(&:position)
    assert_equal instrument.currency, instrument.security.custom_instrument.currency
  end

  test "validates the symbol format, family uniqueness and currency codes" do
    instrument = @family.custom_instruments.new(name: "Test", symbol: "1BAD", currency: "USD", formula: "XAU")

    assert_not instrument.valid?
    assert instrument.errors[:symbol].any?

    instrument.symbol = "U"
    assert_not instrument.valid?

    instrument.symbol = "TOOLONG123456"
    assert_not instrument.valid?

    instrument.symbol = "TRY"
    assert_not instrument.valid?
    assert_includes instrument.errors[:symbol], I18n.t("activerecord.errors.models.custom_instrument.attributes.symbol.currency_code")

    create_custom_instrument(family: @family, symbol: "TAKEN")
    instrument.symbol = "TAKEN"
    assert_not instrument.valid?
  end

  test "reports parse errors on the formula" do
    instrument = @family.custom_instruments.new(name: "Test", symbol: "PARSEY", currency: "USD", formula: "XAU * XAG")

    assert_not instrument.valid?
    assert_includes instrument.errors[:formula].first, "Cannot multiply two assets"
  end

  test "rejects weights outside the supported range" do
    too_large = @family.custom_instruments.new(name: "Test", symbol: "BIGW", currency: "USD", formula: "1000000000000000 * XAU")
    assert_not too_large.valid?
    assert_includes too_large.errors[:formula], I18n.t("activerecord.errors.models.custom_instrument.attributes.formula.weight_out_of_range")

    too_small = @family.custom_instruments.new(name: "Test", symbol: "SMALLW", currency: "USD", formula: "0.0000000000000000001 * XAU")
    assert_not too_small.valid?
    assert_includes too_small.errors[:formula], I18n.t("activerecord.errors.models.custom_instrument.attributes.formula.weight_out_of_range")
  end

  test "rejects more than twenty components" do
    formula = Money::Currency.all.keys.first(21).map { |code| "1 * #{code.upcase}" }.join(" + ")
    instrument = @family.custom_instruments.new(name: "Test", symbol: "MANY", currency: "USD", formula: formula)

    assert_not instrument.valid?
    assert_includes instrument.errors[:formula], I18n.t("activerecord.errors.models.custom_instrument.attributes.formula.too_many_components")
  end

  test "rejects a formula whose references cancel to no components" do
    Security.create!(ticker: "CANCEL", exchange_operating_mic: "XNAS")
    instrument = @family.custom_instruments.new(
      name: "Test", symbol: "CANCELS", currency: "USD", formula: "1 * [CANCEL] - 1 * [CANCEL:XNAS]"
    )

    assert_not instrument.valid?
    assert_includes instrument.errors[:formula], I18n.t("activerecord.errors.models.custom_instrument.attributes.formula.no_components")
  end

  test "archives and unarchives" do
    instrument = create_custom_instrument(family: @family, symbol: "ARCHY")

    assert_includes CustomInstrument.active, instrument
    assert_not instrument.archived?

    instrument.archive!
    assert instrument.archived?
    assert_includes CustomInstrument.archived, instrument
    assert_not_includes CustomInstrument.active, instrument

    instrument.unarchive!
    assert_not instrument.archived?
  end

  test "scopes alphabetically" do
    create_custom_instrument(family: @family, symbol: "ZZZ")
    create_custom_instrument(family: @family, symbol: "AAA")

    assert_equal %w[AAA ZZZ], @family.custom_instruments.alphabetically.map(&:symbol).last(2)
  end

  test "price status moves from pending to missing, ok and stale" do
    instrument = create_custom_instrument(family: @family, symbol: "STATUS")

    assert_equal :pending, instrument.price_status

    instrument.update_column(:updated_at, 11.minutes.ago)
    assert_equal :missing, instrument.price_status

    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: Date.current, rate: 3000)
    Security::Price.create!(security: instrument.security, date: Date.current, price: 100, currency: "USD")
    assert_equal :ok, instrument.price_status

    instrument.security.prices.delete_all
    Security::Price.create!(security: instrument.security, date: 6.days.ago.to_date, price: 100, currency: "USD")
    assert_equal :stale, instrument.price_status
  end

  test "stale components carry the newest observation date" do
    stock = Security.create!(ticker: "STOCKY", exchange_operating_mic: "XNAS")
    Security::Price.create!(security: stock, date: 10.days.ago.to_date, price: 10, currency: "USD")

    instrument = create_custom_instrument(family: @family, symbol: "STALEY", formula: "1 * [STOCKY]")
    Security::Price.create!(security: instrument.security, date: Date.current, price: 10, currency: "USD")

    assert_equal :stale, instrument.price_status
    stale = instrument.stale_components.sole
    assert_equal instrument.components.sole, stale[:component]
    assert_equal 10.days.ago.to_date, stale[:date]
  end

  test "latest price and thirty day change" do
    instrument = create_custom_instrument(family: @family, symbol: "TRENDY")
    assert_nil instrument.latest_price
    assert_nil instrument.price_change

    Security::Price.create!(security: instrument.security, date: 40.days.ago.to_date, price: 100, currency: "USD")
    latest = Security::Price.create!(security: instrument.security, date: Date.current, price: 120, currency: "USD")

    assert_equal latest, instrument.latest_price
    trend = instrument.price_change
    assert_equal Money.new(120, "USD"), trend.current
    assert_equal Money.new(100, "USD"), trend.previous
  end

  test "tracks dependents, trades, holdings and use" do
    instrument = create_custom_instrument(family: @family, symbol: "USED")

    assert_not instrument.in_use?

    child = create_custom_instrument(family: @family, symbol: "USESIT", formula: "1 * USED")
    assert_equal [ child ], instrument.dependents.to_a
    assert instrument.in_use?

    holding = @account.holdings.create!(
      security: instrument.security, date: Date.current, qty: 2, price: 10, amount: 20, currency: "USD"
    )

    assert_includes instrument.holdings, holding
    assert_not_empty instrument.positions_for(@user)

    entry = create_trade(instrument.security, account: @account, qty: 1, date: Date.current, price: 10)
    assert_includes instrument.trades, entry.trade
    assert_includes instrument.affected_accounts, @account

    other_account = @family.accounts.create!(name: "Other", currency: "USD", balance: 0, accountable: Investment.new)
    other_account.holdings.create!(security: child.security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    assert_includes instrument.affected_accounts, other_account
  end

  test "positions for a user only cover accessible accounts and the latest non-zero holding" do
    instrument = create_custom_instrument(family: @family, symbol: "POSITIONS")
    @account.holdings.create!(security: instrument.security, date: 2.days.ago.to_date, qty: 5, price: 10, amount: 50, currency: "USD")
    latest = @account.holdings.create!(security: instrument.security, date: Date.current, qty: 3, price: 10, amount: 30, currency: "USD")
    @account.holdings.create!(security: instrument.security, date: 1.day.ago.to_date, qty: 0, price: 10, amount: 0, currency: "USD")

    assert_equal [ latest ], instrument.positions_for(@user).to_a
  end

  test "refuses to destroy an instrument in use" do
    instrument = create_custom_instrument(family: @family, symbol: "KEEPME")
    @account.holdings.create!(security: instrument.security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    assert_no_difference [ "CustomInstrument.count", "Security.count" ] do
      assert_not instrument.destroy
    end

    assert instrument.errors[:base].any?
    assert Security.exists?(instrument.security_id)
  end

  test "destroying an unused instrument destroys its security" do
    instrument = create_custom_instrument(family: @family, symbol: "GONE")
    security_id = instrument.security_id

    assert_difference [ "CustomInstrument.count", "Security.count" ], -1 do
      instrument.destroy!
    end

    assert_not Security.exists?(security_id)
  end

  test "renames dependents' formulas without resetting their prices" do
    parent = create_custom_instrument(family: @family, symbol: "PARENT")
    child = create_custom_instrument(family: @family, symbol: "CHILD", formula: "1 * PARENT")
    price = Security::Price.create!(security: child.security, date: Date.current, price: 5, currency: "USD")

    parent.update!(symbol: "PARENT2")

    assert_equal "1 * PARENT2", child.reload.formula
    assert Security::Price.exists?(price.id)
  end

  test "a formula change deletes stored prices" do
    instrument = create_custom_instrument(family: @family, symbol: "RECALC")
    Security::Price.create!(security: instrument.security, date: Date.current, price: 5, currency: "USD")

    instrument.update!(formula: "XAG / 31.1034768")

    assert_empty instrument.security.prices
  end

  test "enqueues a price import after a definition change" do
    assert_enqueued_with(job: CustomInstrumentPriceJob) do
      create_custom_instrument(family: @family, symbol: "ENQUEUE")
    end
  end

  test "a currency change deletes stored prices" do
    instrument = create_custom_instrument(family: @family, symbol: "RECUR")
    Security::Price.create!(security: instrument.security, date: Date.current, price: 5, currency: "USD")

    instrument.update!(currency: "EUR")

    assert_empty instrument.security.prices
  end

  test "rejects a cycle created by editing an existing instrument" do
    base = create_custom_instrument(family: @family, symbol: "CYCLEA", formula: "XAU")
    create_custom_instrument(family: @family, symbol: "CYCLEB", formula: "1 * CYCLEA")

    assert_not base.update(formula: "1 * CYCLEB")
    assert_includes base.errors[:formula].join, "cycle"
  end

  test "rejects an edit that pushes a dependent above the nesting limit" do
    base = create_custom_instrument(family: @family, symbol: "DEEP1", formula: "XAU")
    (2..5).each do |level|
      create_custom_instrument(family: @family, symbol: "DEEP#{level}", formula: "1 * DEEP#{level - 1}")
    end
    extra = create_custom_instrument(family: @family, symbol: "EXTRA", formula: "XAU")

    assert_not base.update(formula: "XAU + 1 * EXTRA")
    assert_includes base.errors[:formula], I18n.t("activerecord.errors.models.custom_instrument.attributes.formula.nesting_too_deep")
    assert extra.persisted?
  end

  test "requires a symbol and reports a blank symbol only once" do
    instrument = @family.custom_instruments.new(name: "Test", symbol: nil, currency: "USD", formula: "XAU")

    assert_not instrument.valid?
    assert_equal 1, instrument.errors[:symbol].size

    instrument.symbol = ""
    assert_not instrument.valid?
    assert_equal 1, instrument.errors[:symbol].size
  end

  test "a same-currency currency component is constant and never stale" do
    instrument = create_custom_instrument(
      family: @family, symbol: "CONSTSTALE", currency: "TRY", formula: "1 * XAU + 150 * TRY"
    )
    ExchangeRate.create!(from_currency: "XAU", to_currency: "TRY", date: Date.current, rate: 1000)
    Security::Price.create!(security: instrument.security, date: Date.current, price: 1000, currency: "TRY")

    assert_empty instrument.stale_components
    assert_equal :ok, instrument.price_status
  end

  test "archiving works when a formula reference no longer resolves" do
    stock = Security.create!(ticker: "GONESTOCK", exchange_operating_mic: "XNAS")
    instrument = create_custom_instrument(family: @family, symbol: "ARCHINVALID", formula: "1 * [GONESTOCK]")
    stock.destroy!

    Security.expects(:search_provider).never
    assert instrument.update!(archived_at: Time.current)
    assert instrument.archived?

    assert instrument.unarchive!
    assert_not instrument.archived?
  end

  test "changing only metadata does not resolve or replace components" do
    Security.create!(ticker: "META", exchange_operating_mic: "XNAS")
    instrument = create_custom_instrument(family: @family, symbol: "METAUPD", formula: "1 * [META]")
    component_ids = instrument.components.ids

    Security.expects(:search_provider).never

    instrument.update!(name: "New name", description: "Notes")
    assert_equal component_ids, instrument.components.ids

    instrument.update!(currency: "EUR")
    assert_equal component_ids, instrument.components.ids

    instrument.update!(symbol: "METAUPD2")
    assert_equal component_ids, instrument.components.ids
  end

  test "forgets resolved components after a save" do
    instrument = create_custom_instrument(family: @family, symbol: "MEMO")

    assert_nil instrument.instance_variable_get(:@resolved_components)

    instrument.update!(formula: "XAG")
    assert_nil instrument.instance_variable_get(:@resolved_components)
  end

  test "a formula change resolves and replaces components" do
    stock = Security.create!(ticker: "FORMCHANGE", exchange_operating_mic: "XNAS")
    instrument = create_custom_instrument(family: @family, symbol: "FORMCHANGEI", formula: "XAU")

    instrument.update!(formula: "1 * [FORMCHANGE]")

    assert_equal [ stock.id ], instrument.components.pluck(:security_id)
  end

  test "a duplicate symbol that races past validation becomes a taken error, not an exception" do
    create_custom_instrument(family: @family, symbol: "DUPSYM")
    duplicate = @family.custom_instruments.new(name: "Duplicate", symbol: "DUPSYM", currency: "USD", formula: "XAU")

    assert_nothing_raised do
      assert_not duplicate.save(validate: false)
    end
    assert_includes duplicate.errors[:symbol], I18n.t("activerecord.errors.models.custom_instrument.attributes.symbol.taken")
  end

  test "a new instrument's depth is checked again inside the save lock" do
    deep = create_custom_instrument(family: @family, symbol: "LOCKDEEP1", formula: "XAU")
    (2..5).each do |level|
      deep = create_custom_instrument(family: @family, symbol: "LOCKDEEP#{level}", formula: "1 * LOCKDEEP#{level - 1}")
    end

    reference = CustomInstrument::Formula::Reference.new(kind: :identifier, symbol: "LOCKNEW", mic: nil)
    resolved = CustomInstrument::ReferenceResolver::Resolved.new(
      reference: reference, weight: Rational(1), currency: "USD", security: deep.security
    )
    CustomInstrument::ReferenceResolver.any_instance.stubs(:resolve).returns([ resolved ])

    instrument = @family.custom_instruments.new(name: "Lock new", symbol: "LOCKNEW", currency: "USD", formula: "1 * LOCKDEEP5")

    assert_not instrument.save(validate: false)
    assert_includes instrument.errors[:formula], I18n.t("activerecord.errors.models.custom_instrument.attributes.formula.nesting_too_deep")
  end

  test "family destroy removes its instruments and their securities" do
    family = Family.create!(name: "Destroy Family")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    instrument = create_custom_instrument(family: family, symbol: "FAMILYGONE")
    account.holdings.create!(security: instrument.security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    security_id = instrument.security_id

    family.destroy!

    assert_not CustomInstrument.exists?(instrument.id)
    assert_not Security.exists?(security_id)
    assert_not Account.exists?(account.id)
  end

  test "a transfer trade of existing units is valued at market without changing cash" do
    family = Family.create!(name: "Transfer family")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    instrument = create_custom_instrument(family: family, symbol: "TRANSFERRED", formula: "1 * USD")
    Security::Price.create!(security: instrument.security, date: Date.current, price: 25, currency: "USD")

    account.entries.create!(
      name: "Deposit",
      date: Date.current,
      amount: -1000,
      currency: "USD",
      entryable: Transaction.new
    )
    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    assert_equal BigDecimal("1000"), account.reload.cash_balance.to_d

    account.entries.create!(
      name: "Added 10 units of TRANSFERRED",
      date: Date.current,
      amount: 0,
      currency: "USD",
      entryable: Trade.new(
        security: instrument.security,
        qty: 10,
        price: 0,
        currency: "USD",
        investment_activity_label: "Transfer"
      )
    )

    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    holding = account.holdings.find_by!(security: instrument.security, date: Date.current)
    assert_equal BigDecimal("10"), holding.qty
    assert_equal BigDecimal("250"), holding.amount
    account.reload
    assert_equal BigDecimal("1000"), account.cash_balance.to_d
    assert_equal BigDecimal("1250"), account.balance.to_d
  end
end
