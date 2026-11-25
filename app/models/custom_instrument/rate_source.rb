class CustomInstrument::RateSource
  METALS = %w[XAU XAG XPT XPD].freeze

  CURRENT_LOOKBACK_DAYS = 5
  TAIL_DAYS = 5
  FIRST_DATE_TTL = 1.week
  TAIL_TTL = 1.hour
  CURRENT_SUCCESS_TTL = 10.minutes
  METAL_CURRENT_TTL = 1.hour
  FAILURE_TTL = 1.minute

  # Remembers the earliest date Frankfurter actually answered for a pair, so a
  # request for years before its first date is not downloaded again every run.
  class RecordingFrankfurter
    attr_reader :earliest_date

    def initialize(provider: Provider::Frankfurter.new)
      @provider = provider
    end

    def fetch_exchange_rates(**options)
      response = @provider.fetch_exchange_rates(**options)
      return response unless response.success?

      dates = response.data.filter_map { |rate| rate.date if rate.rate.to_d.positive? }
      earliest = dates.min
      @earliest_date = earliest if earliest && (@earliest_date.nil? || earliest < @earliest_date)
      response
    end

    def max_history_days
      @provider.respond_to?(:max_history_days) ? @provider.max_history_days : nil
    end
  end

  class << self
    # Fetches the rates a metal pair needs. Non-metal pairs are the ordinary
    # exchange-rate job's business. A metal pair is kept current daily: the
    # configured provider is used only when it has served the pair before,
    # missing history is filled from Frankfurter, and the carried-forward tail
    # is corrected from Frankfurter unless the configured provider served it.
    def import(from:, to:, start_date:, end_date:, clear_cache: false)
      from = from.to_s.upcase
      to = to.to_s.upcase
      return if from == to

      unless metal_pair?(from, to)
        return ExchangeRate.import_provider_rates(
          from: from, to: to, start_date: start_date, end_date: end_date, clear_cache: clear_cache
        )
      end

      # When Frankfurter is the configured provider its own importer already
      # knows how to gap-fill metals, so let it do the work.
      if ExchangeRate.provider_name == "frankfurter"
        return ExchangeRate.import_provider_rates(
          from: from, to: to, start_date: start_date, end_date: end_date, clear_cache: clear_cache
        )
      end

      pair = ExchangeRatePair.find_by(from_currency: from, to_currency: to)
      configured_served = configured_provider_served_pair?(pair)

      run_configured_provider(from: from, to: to, start_date: start_date, end_date: end_date, clear_cache: clear_cache) if configured_served

      if history_incomplete?(from: from, to: to, start_date: start_date, end_date: end_date)
        import_frankfurter(
          from: from, to: to, start_date: start_date, end_date: end_date,
          clear_cache: clear_cache, record_first_date: true
        )
      end

      correct_tail(from: from, to: to, end_date: end_date, clear_cache: clear_cache) unless configured_served
    rescue => error
      capture_error(error, from: from, to: to, start_date: start_date, end_date: end_date)
    end

    # A non-persisting rate lookup for the live preview. Returns { rate:, date: }
    # or nil. Provider answers are cached so typing does not make one request
    # per keystroke; `cache: false` on find_or_fetch_rate is load-bearing because
    # it would otherwise write a fetched rate to the database.
    def current(from:, to:)
      from = from.to_s.upcase
      to = to.to_s.upcase
      return { rate: BigDecimal(1), date: Date.current } if from == to

      stored = stored_current_rate(from, to)
      return { rate: stored.rate.to_d, date: stored.date } if stored

      success_key, failure_key = current_cache_keys(from, to)
      cached = Rails.cache.read(success_key)
      return cached if cached
      return nil if Rails.cache.read(failure_key)

      rate = metal_pair?(from, to) ? metal_current(from, to) : configured_current(from, to)

      if rate
        ttl = metal_pair?(from, to) ? METAL_CURRENT_TTL : CURRENT_SUCCESS_TTL
        Rails.cache.write(success_key, rate, expires_in: ttl)
      else
        Rails.cache.write(failure_key, true, expires_in: FAILURE_TTL)
      end

      rate
    end

    private
      def metal_pair?(from, to)
        METALS.include?(from) || METALS.include?(to)
      end

      def stored_current_rate(from, to)
        scope = ExchangeRate.where(from_currency: from, to_currency: to).where("rate > 0").order(date: :desc)
        stored = scope.first
        return nil unless stored

        if metal_pair?(from, to)
          stored.date == Date.current ? stored : nil
        elsif stored.date >= Date.current - CURRENT_LOOKBACK_DAYS
          stored
        end
      end

      def metal_current(from, to)
        frankfurter_current(from, to) || (configured_current(from, to) unless ExchangeRate.provider_name == "frankfurter")
      end

      def frankfurter_current(from, to)
        response = Provider::Frankfurter.new(timeout: 3, max_retries: 0)
                                        .fetch_exchange_rate(from: from, to: to, date: Date.current)
        return unless response.success?

        { rate: BigDecimal(response.data.rate.to_s), date: response.data.date }
      rescue Provider::Error
        nil
      end

      def configured_current(from, to)
        fetched = ExchangeRate.find_or_fetch_rate(from: from, to: to, cache: false)
        return unless fetched && fetched.rate.to_d.positive?
        # A metal's stored "nearest" rate can be days old; a preview must not
        # pass it off as today's.
        return if metal_pair?(from, to) && fetched.date != Date.current

        { rate: fetched.rate.to_d, date: fetched.date }
      rescue Provider::Error
        nil
      end

      def current_cache_keys(from, to)
        [
          "custom_instrument:current:#{from}:#{to}:#{Date.current}",
          "custom_instrument:current_failure:#{from}:#{to}"
        ]
      end

      def configured_provider_served_pair?(pair)
        return false unless pair
        return false if pair.first_provider_rate_on.blank?

        pair.provider_name == ExchangeRate.provider_name
      end

      def run_configured_provider(from:, to:, start_date:, end_date:, clear_cache:)
        ExchangeRate.import_provider_rates(
          from: from, to: to, start_date: start_date, end_date: end_date, clear_cache: clear_cache
        )
      rescue => error
        capture_error(error, from: from, to: to, start_date: start_date, end_date: end_date)
      end

      def history_incomplete?(from:, to:, start_date:, end_date:)
        first = cached_first_date(from, to)
        coverage_start = [ start_date, first ].compact.max
        return false if coverage_start > end_date

        expected = (coverage_start..end_date).count
        actual = ExchangeRate.where(from_currency: from, to_currency: to, date: coverage_start..end_date)
                             .where("rate > 0")
                             .distinct
                             .count(:date)

        actual < expected
      end

      def cached_first_date(from, to)
        value = Rails.cache.read(first_date_key(from, to))
        return if value.blank?
        return value if value.is_a?(Date)

        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end

      def correct_tail(from:, to:, end_date:, clear_cache:)
        marker_key = tail_marker_key(from, to)

        if clear_cache
          Rails.cache.write(marker_key, true, expires_in: TAIL_TTL)
        elsif !Rails.cache.write(marker_key, true, expires_in: TAIL_TTL, unless_exist: true)
          return
        end

        import_frankfurter(
          from: from, to: to, start_date: end_date - TAIL_DAYS, end_date: end_date,
          clear_cache: true, record_first_date: false
        )
      end

      def import_frankfurter(from:, to:, start_date:, end_date:, clear_cache:, record_first_date:)
        lock_key = "exchange_rate_import:#{from}:#{to}:#{start_date}"
        lock_token = SecureRandom.uuid
        return unless Rails.cache.write(lock_key, lock_token, expires_in: 5.minutes, unless_exist: true)

        recorder = RecordingFrankfurter.new
        begin
          ExchangeRate::Importer.new(
            exchange_rate_provider: recorder,
            provider_name: "frankfurter",
            from: from,
            to: to,
            start_date: start_date,
            end_date: end_date,
            clear_cache: clear_cache
          ).import_provider_rates
        ensure
          Rails.cache.delete(lock_key) if Rails.cache.read(lock_key) == lock_token
        end

        remember_first_date(from, to, recorder.earliest_date) if record_first_date && recorder.earliest_date
      end

      def remember_first_date(from, to, date)
        key = first_date_key(from, to)
        current = cached_first_date(from, to)
        return if current && current <= date

        Rails.cache.write(key, date, expires_in: FIRST_DATE_TTL)
      end

      def first_date_key(from, to)
        "custom_instrument:frankfurter_first:#{from}:#{to}"
      end

      def tail_marker_key(from, to)
        "custom_instrument:frankfurter_tail:#{from}:#{to}"
      end

      def capture_error(error, from:, to:, start_date:, end_date:)
        DebugLogEntry.capture(
          category: "custom_instruments",
          level: "warn",
          message: "Could not import rates for a custom instrument",
          source: name,
          metadata: { from: from, to: to, start_date: start_date, end_date: end_date, error: error.message }
        )
      end
  end
end
