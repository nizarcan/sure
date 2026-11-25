# Changes how many units of its instrument an account holds. Units are booked
# as Transfer trades at price 0, so the quantity moves without cash moving; the
# account's money value follows from the instrument's price, as for any holding.
class Account::UnitBalance
  Result = Struct.new(:success?, :entry, :message, keyword_init: true)

  # A quantity as entered, without trailing zeros ("250", "10.5").
  def self.format_quantity(value)
    formatted = value.to_d.to_s("F")
    formatted.include?(".") ? formatted.sub(/0+\z/, "").delete_suffix(".") : formatted
  end

  def initialize(account)
    @account = account
  end

  # Makes the account hold exactly +quantity+ units on +date+. A price paid is
  # recorded on the added lot, which is how a gain or loss becomes visible.
  def set(quantity:, date:, unit_price: nil)
    quantity = quantity.to_d
    return failure(:not_instrument) unless instrument
    return failure(:negative_quantity) if quantity.negative?

    date = date.to_date
    diff = quantity - account.unit_balance_on(date)
    write(diff: diff, date: date, unit_price: unit_price, action: :set, quantity: quantity)
  end

  def add(quantity:, date:, unit_price: nil)
    quantity = quantity.to_d
    return failure(:not_instrument) unless instrument
    return failure(:quantity_must_be_positive) unless quantity.positive?
    return failure(:invalid_price) if unit_price.present? && unit_price.to_d.negative?

    write(diff: quantity, date: date.to_date, unit_price: unit_price, action: :add, quantity: quantity)
  end

  def remove(quantity:, date:)
    quantity = quantity.to_d
    return failure(:not_instrument) unless instrument
    return failure(:quantity_must_be_positive) unless quantity.positive?

    date = date.to_date
    held = account.unit_balance_on(date)
    return failure(:insufficient_units, held: self.class.format_quantity(held)) if quantity > held

    write(diff: -quantity, date: date, action: :remove, quantity: quantity)
  end

  private
    attr_reader :account

    def instrument
      account.custom_instrument
    end

    def write(diff:, date:, action:, quantity:, unit_price: nil)
      if diff.zero?
        return Result.new(
          success?: true,
          entry: nil,
          message: I18n.t("accounts.unit_balance.unchanged",
                          quantity: self.class.format_quantity(quantity),
                          symbol: instrument.symbol)
        )
      end

      entry = nil
      Account.transaction do
        entry = account.entries.create!(
          name: entry_name(action, quantity),
          date: date,
          amount: 0,
          currency: account.currency,
          entryable: Trade.new(
            qty: diff,
            price: 0,
            fee: 0,
            currency: account.currency,
            security: instrument.security,
            investment_activity_label: Trade::TRANSFER_LABEL
          )
        )
        record_cost(entry, diff, unit_price) if unit_price.present? && diff.positive?
        entry.lock_saved_attributes!
        entry.mark_user_modified!
      end

      account.sync_later
      Result.new(success?: true, entry: entry, message: success_message(action, entry, diff))
    rescue ActiveRecord::RecordInvalid => e
      Result.new(
        success?: false,
        entry: nil,
        message: e.record.errors.full_messages.to_sentence.presence || e.message
      )
    end

    # Adding and removing already say what changed. Setting says the balance it
    # reached, so its message also names the difference the user sees.
    def success_message(action, entry, diff)
      return entry.name unless action == :set

      change = "#{diff.positive? ? "+" : "-"}#{self.class.format_quantity(diff.abs)} #{instrument.symbol}"
      I18n.t("accounts.unit_balance.changed", name: entry.name, change: change)
    end

    def entry_name(action, quantity)
      I18n.t(
        "accounts.unit_balance.names.#{action}",
        quantity: self.class.format_quantity(quantity),
        symbol: instrument.symbol
      )
    end

    # The same shape Family::DataImporter#import_lot_total_cost writes, so the
    # holdings materializer keeps the user's cost on the rebuilt lot.
    def record_cost(entry, quantity, unit_price)
      lot = HoldingLot.new(
        account_id: account.id,
        source_entry: entry,
        security: instrument.security,
        acquired_on: entry.date,
        qty: quantity,
        currency: account.currency
      )
      lot.manual_total_cost = quantity * unit_price.to_d
      lot.save!
    end

    def failure(key, **options)
      symbol = instrument&.symbol
      message = I18n.t("accounts.unit_balance.errors.#{key}", **options.merge(symbol: symbol).compact)
      Result.new(success?: false, entry: nil, message: message)
    end
end
