# A read-only valuation of a formula for the live preview. Nothing here may
# write to securities, prices or exchange rates: the values are fetched with
# `cache: false` and resolved without creating securities.
class CustomInstrument::Quote
  Line = Data.define(:reference, :label, :weight, :unit_price, :value, :share, :date)

  MAX_DEPTH = CustomInstrument::MAX_NESTING_DEPTH
  STALE_AFTER_DAYS = CustomInstrument::STALE_AFTER_DAYS

  attr_reader :family, :currency, :price, :as_of, :lines

  def initialize(family:, formula_text:, currency:, instrument: nil, depth: 0)
    @family = family
    @formula_text = formula_text
    @currency = currency.respond_to?(:iso_code) ? currency.iso_code : currency.to_s.upcase
    @instrument = instrument
    @depth = depth
    @lines = []
    @error = nil
    calculate
  end

  def valid?
    error.nil?
  end

  def error
    @error
  end

  def stale?
    as_of.present? && as_of < Date.current - STALE_AFTER_DAYS.days
  end

  def positive?
    price.present? && price.positive?
  end

  def nonpositive?
    price.present? && price <= 0
  end

  # How many instruments one unit of the single referenced asset is worth.
  # Only meaningful for a one-asset formula such as GRAU = XAU / 31.103…
  def inverse
    return nil unless lines.one?

    line = lines.first
    return nil unless line.unit_price&.amount && price&.positive?

    line.unit_price.amount / price
  end

  def unpriced
    lines.reject { |line| line.unit_price }.map(&:label)
  end

  private
    attr_reader :formula_text, :instrument, :depth

    def calculate
      parsed = CustomInstrument::Formula.new(formula_text)

      unless parsed.valid?
        @error = parsed.error.message
        return
      end

      resolved = CustomInstrument::ReferenceResolver.new(
        family: family,
        instrument: instrument,
        create_securities: false
      ).resolve(parsed)

      raw_lines = resolved.map { |component| build_line(component) }
      total = raw_lines.select { |line| line.unit_price && line.value }.sum(BigDecimal(0)) { |line| line.value.amount }

      @lines = raw_lines.map do |line|
        share = total.positive? && line.value ? (line.value.amount / total * 100).round(2) : BigDecimal(0)
        line.with(share: share)
      end

      @as_of = @lines.filter_map(&:date).min
      @price = @lines.all?(&:unit_price) && @lines.any? ? total.round(4) : nil
    rescue CustomInstrument::Formula::ParseError => error
      @error = error.message
    rescue CustomInstrument::ReferenceResolver::Error => error
      @error = error.message
    end

    def build_line(component)
      unit_price, date = component.security ? security_price(component.security) : currency_price(component.currency)

      weight = component.weight.to_d
      value = unit_price && weight * unit_price

      Line.new(
        reference: component.reference,
        label: label_for(component),
        weight: weight,
        unit_price: unit_price && Money.new(unit_price, currency),
        value: value && Money.new(value, currency),
        share: nil,
        date: date
      )
    end

    def currency_price(source_currency)
      convert(BigDecimal(1), source_currency, Date.current)
    end

    def security_price(security)
      if security.custom?
        nested_price(security)
      else
        price = newest_stored_price(security)
        price ||= security.find_or_fetch_price(cache: false) unless security.offline?
        return [ nil, nil ] unless price

        convert(price.price.to_d, price.currency, price.date)
      end
    end

    def nested_price(security)
      nested = security.custom_instrument
      return [ nil, nil ] unless nested

      price = newest_stored_price(nested.security)
      return convert(price.price.to_d, price.currency, price.date) if price
      return [ nil, nil ] if depth >= MAX_DEPTH

      quote = CustomInstrument::Quote.new(
        family: family,
        formula_text: nested.formula,
        currency: nested.currency,
        instrument: nested,
        depth: depth + 1
      )
      return [ nil, nil ] unless quote.valid? && quote.price

      convert(quote.price, nested.currency, quote.as_of)
    end

    def newest_stored_price(security)
      security.prices.order(date: :desc).first
    end

    def convert(amount, source_currency, date)
      return [ amount, date ] if source_currency == currency

      rate = CustomInstrument::RateSource.current(from: source_currency, to: currency)
      return [ nil, nil ] unless rate

      [ amount * rate[:rate], [ date, rate[:date] ].compact.min ]
    end

    def label_for(component)
      component.security ? component.security.display_ticker : component.currency
    end
end
