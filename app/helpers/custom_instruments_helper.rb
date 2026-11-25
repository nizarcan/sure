module CustomInstrumentsHelper
  STATUS_TONES = {
    pending: :neutral,
    missing: :warning,
    stale: :warning
  }.freeze

  # The status pill a row shows. `:ok` is the default state and stays quiet:
  # a pill on every healthy row would read as an alert.
  def custom_instrument_status_pill(instrument, status, stale_components: nil)
    return nil if status == :ok

    components = stale_components || (status == :stale ? instrument.stale_components : [])
    title = status == :stale ? stale_components_title(components) : nil

    render DS::Pill.new(
      label: t("custom_instruments.index.status.#{status}"),
      tone: STATUS_TONES.fetch(status, :neutral),
      marker: false,
      title: title
    )
  end

  def stale_components_title(components)
    return nil if components.empty?

    parts = components.map do |component|
      label = component[:component].security&.display_ticker || component[:component].currency

      if component[:date]
        t("custom_instruments.index.status.component_date", label: label, date: format_date(component[:date]))
      else
        t("custom_instruments.index.status.component_missing", label: label)
      end
    end

    t("custom_instruments.index.status.stale_title", components: parts.to_sentence)
  end

  def custom_instrument_price_money(price)
    price && Money.new(price.price, price.currency)
  end

  # The change between the newest price and the newest one at least 30 days
  # old. Both are loaded by the index in bulk, so no row queries its history.
  def custom_instrument_change(latest_price, previous_price)
    current = custom_instrument_price_money(latest_price)
    previous = custom_instrument_price_money(previous_price)
    return nil unless current && previous
    return nil if previous.zero?

    Trend.new(current: current, previous: previous)
  end

  def custom_instrument_held_label(positions)
    return t("custom_instruments.index.not_held") if positions.blank?

    t(
      "custom_instruments.index.held",
      qty: format_quantity(positions.sum { |holding| holding.qty.to_d }),
      count: positions.map(&:account_id).uniq.size
    )
  end

  # Up to ten significant digits, without trailing zeros: enough to check a
  # coin's grams without printing the stored 18-decimal scale.
  def custom_instrument_weight(weight)
    value = weight.to_d
    decimals = 10 - value.exponent
    rounded = decimals.positive? ? value.round(decimals) : value.round(0)
    text = rounded.to_s("F")

    text.include?(".") ? text.sub(/0+\z/, "").sub(/\.\z/, "") : text
  end

  def custom_instrument_share(share)
    number_to_percentage(share.to_d, precision: 1)
  end

  def custom_instrument_currency_options(instrument)
    Current.family.enabled_currency_codes(extra: [ instrument.currency ].compact).map do |code|
      [ currency_label(code), code ]
    end
  end

  # The identifiers the insert chips offer: the metals, the family's own and
  # the instrument's currency, the two trading currencies, then the family's
  # other instruments so one can be nested in another formula.
  def custom_instrument_chips(instrument)
    currencies = [ "XAU", "XAG", Current.family.primary_currency_code, instrument.currency, "USD", "EUR" ]
                 .compact.map { |code| code.to_s.upcase }
    nested = Current.family.custom_instruments
                    .active
                    .where.not(id: instrument.id)
                    .alphabetically
                    .pluck(:symbol)

    (currencies + nested).uniq
  end

  # A price this small is almost always a formula mistake (a missing troy
  # ounce division), not a cheap unit.
  def custom_instrument_small_price?(value)
    return false if value.nil?

    amount = value.to_d
    amount.positive? && amount < BigDecimal("0.0001")
  end

  def custom_instrument_quote_warnings(quote)
    return [] unless quote&.valid?

    warnings = []

    if quote.stale?
      warnings << t("custom_instruments.preview.stale", date: format_date(quote.as_of))
    end

    if quote.unpriced.any?
      warnings << t("custom_instruments.preview.unpriced", components: quote.unpriced.to_sentence)
    end

    if custom_instrument_small_price?(quote.price)
      warnings << t("custom_instruments.preview.too_small")
    end

    warnings
  end
end
