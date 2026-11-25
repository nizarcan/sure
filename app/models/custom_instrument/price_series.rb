class CustomInstrument::PriceSeries
  PROVISIONAL_DAYS = 7
  Observation = Data.define(:date, :value)

  def initialize(instrument)
    @instrument = instrument
  end

  # Each component contributes weight * price, carrying its last observation
  # forward. A security price in another currency is converted at a rate
  # carried forward from on or before the price's own date. Dates before any
  # component has an observation are left out rather than guessed.
  def calculate(start_date, end_date)
    return [] if start_date.blank? || end_date.blank? || start_date > end_date

    prepared = instrument.components.includes(:security).map { |component| prepare(component, start_date, end_date) }
    return [] if prepared.empty?
    return [] if prepared.any? { |parts| parts[:constant].nil? && parts[:observations].empty? }

    first_observation = prepared.filter_map { |parts| parts[:observations].first&.date }.max
    series_start = [ start_date, first_observation || start_date ].max
    return [] if series_start > end_date

    rows = []

    (series_start..end_date).each do |date|
      total = BigDecimal(0)
      carried = false

      prepared.each do |parts|
        if parts[:constant]
          total += parts[:constant]
          next
        end

        observation = last_observation(parts[:observations], date)
        next unless observation

        total += observation.value
        carried ||= observation.date < date
      end

      next unless total.positive?

      price = total.round(4)
      next unless price.positive?

      rows << {
        date: date,
        price: price,
        provisional: carried && date >= Date.current - PROVISIONAL_DAYS.days
      }
    end

    rows
  end

  private
    attr_reader :instrument

    def prepare(component, start_date, end_date)
      if component.currency.present?
        prepare_currency(component, end_date)
      else
        prepare_security(component, start_date, end_date)
      end
    end

    # A currency component's own price is 1. Only its conversion into the
    # instrument's currency has to be observed; a same-currency component is a
    # constant and is never "carried".
    def prepare_currency(component, end_date)
      weight = component.weight.to_d
      return { constant: weight, observations: [] } if component.currency == instrument.currency

      rates = ExchangeRate.where(from_currency: component.currency, to_currency: instrument.currency)
                          .where(date: ..end_date)
                          .where("rate > 0")
                          .order(:date)
                          .pluck(:date, :rate)

      observations = rates.map do |date, rate|
        Observation.new(date: date, value: weight * rate.to_d)
      end

      { constant: nil, observations: observations }
    end

    def prepare_security(component, start_date, end_date)
      security = component.security
      weight = component.weight.to_d

      # The last observation before the window anchors the carry-forward.
      # A security can have rows in several currencies on one date; pick the
      # instrument currency first, then the currency name, never row order.
      before_order = Security.sanitize_sql_array([
        "date DESC, CASE WHEN currency = ? THEN 0 ELSE 1 END, currency ASC",
        instrument.currency
      ])
      before = security.prices.where("date < ?", start_date).order(Arel.sql(before_order)).first
      prices = [ before, *security.prices.where(date: start_date..end_date).order(:date).to_a ].compact
      prices = preferred_prices_by_date(prices)
      return { constant: nil, observations: [] } if prices.empty?

      foreign_currencies = prices.map(&:currency).uniq - [ instrument.currency ]
      rates = rates_by_currency(foreign_currencies, end_date)

      observations = prices.filter_map do |price|
        value = weight * price.price.to_d

        if price.currency != instrument.currency
          rate = rate_on_or_before(rates[price.currency], price.date)
          next unless rate

          value *= rate
        end

        Observation.new(date: price.date, value: value)
      end

      { constant: nil, observations: observations }
    end

    def preferred_prices_by_date(prices)
      prices.group_by(&:date)
            .sort_by(&:first)
            .map do |_date, rows|
              rows.min_by { |price| [ price.currency == instrument.currency ? 0 : 1, price.currency.to_s ] }
            end
    end

    def rates_by_currency(currencies, end_date)
      return {} if currencies.empty?

      rows = ExchangeRate.where(from_currency: currencies, to_currency: instrument.currency)
                         .where(date: ..end_date)
                         .where("rate > 0")
                         .order(:from_currency, :date)
                         .pluck(:from_currency, :date, :rate)

      rows.group_by(&:first).transform_values do |list|
        list.map { |_currency, date, rate| [ date, rate.to_d ] }
      end
    end

    def rate_on_or_before(rates, date)
      index = rates&.bsearch_index { |(rate_date, _)| rate_date > date }
      return nil if rates.blank? || index == 0

      rates[index ? index - 1 : -1].last
    end

    def last_observation(observations, date)
      index = observations.bsearch_index { |observation| observation.date > date }
      return nil if index == 0

      observations[index ? index - 1 : -1]
    end
end
