class CustomInstrument::ReferenceResolver
  Resolved = Data.define(:reference, :weight, :currency, :security)

  RECENT_PRICE_DAYS = 7
  MAX_NESTING_DEPTH = CustomInstrument::MAX_NESTING_DEPTH

  class Error < StandardError
    attr_reader :code, :token

    def initialize(code, token: nil, **locals)
      @code = code
      @token = token
      @locals = locals
      super()
    end

    def message
      locals = @locals.dup
      locals[:token] ||= token
      locals[:symbol] ||= token
      I18n.t("custom_instruments.resolver.errors.#{code}", **locals)
    end
  end

  def initialize(family:, instrument: nil, create_securities: false)
    @family = family
    @instrument = instrument
    @create_securities = create_securities
  end

  # Resolves every reference in `formula` into the asset it names. References
  # that point at the same asset are merged, so [AAPL] and [AAPL:XNAS] add up.
  def resolve(formula)
    formula = CustomInstrument::Formula.new(formula) unless formula.is_a?(CustomInstrument::Formula)

    merged = {}

    formula.weights.each do |reference, weight|
      resolved = resolve_reference(reference, weight)
      next if resolved.nil?

      key = key_for(resolved)
      if merged.key?(key)
        current = merged[key]
        merged[key] = Resolved.new(
          reference: current.reference,
          weight: current.weight + resolved.weight,
          currency: current.currency,
          security: current.security
        )
      else
        merged[key] = resolved
      end
    end

    merged.values.reject { |resolved| resolved.weight.zero? }
  end

  private
    attr_reader :family, :instrument, :create_securities

    def resolve_reference(reference, weight)
      case reference.kind
      when :identifier
        resolve_identifier(reference, weight)
      when :security
        resolve_security(reference, weight)
      else
        raise Error.new(:unknown_symbol, symbol: reference.symbol)
      end
    end

    def resolve_identifier(reference, weight)
      candidate = family.custom_instruments.find_by("UPPER(symbol) = ?", reference.symbol)

      if candidate
        raise Error.new(:self_reference, token: reference.to_s) if instrument && candidate.id == instrument.id
        if candidate.archived? && !already_referenced?(candidate)
          raise Error.new(:archived_instrument, symbol: reference.symbol)
        end
        raise Error.new(:cycle, token: reference.to_s) if instrument && CustomInstrument.depends_on?(candidate, instrument)
        if CustomInstrument.depth_of(candidate) + 1 > MAX_NESTING_DEPTH
          raise Error.new(:nesting_too_deep, token: reference.to_s)
        end

        Resolved.new(reference: reference, weight: weight, currency: candidate.currency, security: candidate.security)
      elsif Money::Currency.all.key?(reference.symbol.downcase)
        Resolved.new(reference: reference, weight: weight, currency: reference.symbol, security: nil)
      else
        raise Error.new(:unknown_symbol, symbol: reference.symbol)
      end
    end

    def resolve_security(reference, weight)
      stored = stored_security(reference)
      return Resolved.new(reference: reference, weight: weight, currency: nil, security: stored) if stored

      match = provider_match(reference)
      raise Error.new(:unknown_security, token: reference.to_s) unless match

      match = persist_security(match) if create_securities
      Resolved.new(reference: reference, weight: weight, currency: match.search_currency, security: match)
    end

    # Deliberately does not use Security.find_by_ticker_and_exchange: that
    # method upgrades a legacy MIC, a write a preview must not perform.
    def stored_security(reference)
      scope = Security.where("UPPER(ticker) = ?", reference.symbol).where.not(kind: [ "cash", "custom" ])

      if reference.mic.present?
        canonical = Security.canonical_exchange_operating_mic(reference.mic)
        values = Security.exchange_operating_mic_lookup_values(reference.mic)
        order = Security.sanitize_sql_array(
          [ "CASE WHEN UPPER(COALESCE(exchange_operating_mic, '')) = ? THEN 0 ELSE 1 END", canonical ]
        )
        scope.where("UPPER(exchange_operating_mic) IN (?)", values).order(Arel.sql(order)).first
      else
        best_stored_candidate(scope.to_a)
      end
    end

    # Without a MIC several rows can match. Prefer an online row with recent
    # prices, then a blank MIC (the venue-less listing), then the lowest id.
    def best_stored_candidate(candidates)
      return nil if candidates.empty?

      recent_ids = Security::Price.where(
        security_id: candidates.map(&:id),
        date: RECENT_PRICE_DAYS.days.ago.to_date..Date.current
      ).distinct.pluck(:security_id).to_set

      candidates.min_by do |candidate|
        [
          candidate.offline? || !recent_ids.include?(candidate.id) ? 1 : 0,
          candidate.exchange_operating_mic.blank? ? 0 : 1,
          candidate.id
        ]
      end
    end

    def provider_match(reference)
      params = reference.mic.present? ? { exchange_operating_mic: reference.mic } : {}
      Security.search_provider(reference.symbol, **params).find do |candidate|
        next false unless candidate.ticker.to_s.upcase == reference.symbol
        next true if reference.mic.blank?

        Security.canonical_exchange_operating_mic(candidate.exchange_operating_mic) ==
          Security.canonical_exchange_operating_mic(reference.mic)
      end
    end

    def persist_security(security)
      security.offline = false
      security.save!
      security
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      existing = stored_security(
        CustomInstrument::Formula::Reference.new(
          kind: :security, symbol: security.ticker, mic: security.exchange_operating_mic
        )
      )
      raise Error.new(:unknown_security, token: security.ticker) unless existing

      # The search result carries the display name; a stored row that raced in
      # without one should not replace it with a blank name.
      existing.update_column(:name, security.name) if existing.name.blank? && security.name.present?
      existing
    end

    def already_referenced?(candidate)
      return false unless instrument&.persisted?

      instrument.components.where(security_id: candidate.security_id).exists?
    end

    def key_for(resolved)
      if resolved.security
        identity = resolved.security.id ||
          [ resolved.security.ticker, Security.canonical_exchange_operating_mic(resolved.security.exchange_operating_mic) ]
        [ :security, identity ]
      else
        [ :currency, resolved.currency ]
      end
    end
end
