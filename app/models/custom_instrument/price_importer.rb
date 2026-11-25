class CustomInstrument::PriceImporter
  def initialize(instrument, visited: Set.new)
    @instrument = instrument
    @visited = visited
    @visited << instrument.id if instrument.id
  end

  def import(start_date:, end_date:, clear_cache: false)
    missing = []

    instrument.components.includes(:security).each do |component|
      if component.currency.present?
        import_currency(component, start_date: start_date, end_date: end_date, clear_cache: clear_cache)
        missing << label_for(component) unless currency_priced?(component, end_date)
      else
        import_security(component, start_date: start_date, end_date: end_date, clear_cache: clear_cache)
        missing << label_for(component) unless security_priced?(component, end_date)
      end
    end

    return capture_missing_prices(missing) if missing.any?

    rows = CustomInstrument::PriceSeries.new(instrument).calculate(start_date, end_date)
    write(rows, start_date, end_date)

    [ rows.size, nil ]
  rescue => error
    capture_error(error)
    [ 0, error.message ]
  end

  private
    attr_reader :instrument, :visited

    def import_currency(component, start_date:, end_date:, clear_cache:)
      CustomInstrument::RateSource.import(
        from: component.currency,
        to: instrument.currency,
        start_date: start_date,
        end_date: end_date,
        clear_cache: clear_cache
      )
    end

    def import_security(component, start_date:, end_date:, clear_cache:)
      security = component.security

      if security.custom?
        nested = security.custom_instrument
        if nested && !visited.include?(nested.id)
          visited << nested.id
          CustomInstrument::PriceImporter.new(nested, visited: visited).import(
            start_date: start_date, end_date: end_date, clear_cache: clear_cache
          )
        end
      else
        # An offline security's stored prices are used as they are; it has no
        # provider to ask.
        unless security.offline?
          security.import_provider_prices(
            start_date: start_date, end_date: end_date, clear_cache: clear_cache
          )
        end
      end

      import_price_currencies(security, start_date: start_date, end_date: end_date, clear_cache: clear_cache)
    end

    # Prices can be quoted in a currency the instrument is not, and the
    # series converts them. Make sure those pairs are covered too.
    def import_price_currencies(security, start_date:, end_date:, clear_cache:)
      currencies = Security::Price.where(security_id: security.id, date: ..end_date)
                                  .distinct
                                  .pluck(:currency) - [ instrument.currency ]

      currencies.each do |currency|
        CustomInstrument::RateSource.import(
          from: currency,
          to: instrument.currency,
          start_date: start_date,
          end_date: end_date,
          clear_cache: clear_cache
        )
      end
    end

    def currency_priced?(component, end_date)
      return true if component.currency == instrument.currency

      ExchangeRate.where(from_currency: component.currency, to_currency: instrument.currency)
                  .where(date: ..end_date)
                  .where("rate > 0")
                  .exists?
    end

    def security_priced?(component, end_date)
      Security::Price.where(security_id: component.security_id, date: ..end_date).exists?
    end

    def label_for(component)
      component.currency.presence || component.security&.display_ticker || component.security&.ticker
    end

    def missing_message(missing)
      I18n.t(
        "custom_instruments.price_importer.missing_prices",
        components: missing.uniq.to_sentence
      )
    end

    def capture_missing_prices(missing)
      message = missing_message(missing)
      DebugLogEntry.capture(
        category: "custom_instruments",
        level: "warn",
        message: message,
        source: self.class.name,
        family: instrument.family,
        metadata: { custom_instrument_id: instrument.id, components: missing.uniq }
      )
      [ 0, message ]
    end

    def capture_error(error)
      DebugLogEntry.capture(
        category: "custom_instruments",
        level: "error",
        message: "Could not import prices for a custom instrument",
        source: self.class.name,
        family: instrument.family,
        metadata: { custom_instrument_id: instrument.id, error: error.message }
      )
    end

    def write(rows, start_date, end_date)
      security = instrument.security
      currency = instrument.currency
      now = Time.current

      if rows.any?
        Security::Price.upsert_all(
          rows.map do |row|
            {
              security_id: security.id,
              date: row[:date],
              price: row[:price],
              currency: currency,
              provisional: row[:provisional],
              updated_at: now
            }
          end,
          unique_by: %i[security_id date currency]
        )
      end

      # A currency change and dates the current formula no longer produces are
      # corrections, not gaps, so the stale rows go. An error that left the
      # components unpriced never reaches this method.
      security.prices.where(date: start_date..end_date).where.not(currency: currency).delete_all

      dates = rows.map { |row| row[:date] }
      security.prices.where(date: start_date..end_date, currency: currency).where.not(date: dates).delete_all
    end
end
