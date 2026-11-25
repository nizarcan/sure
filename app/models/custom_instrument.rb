class CustomInstrument < ApplicationRecord
  SYMBOL_FORMAT = /\A\p{Lu}[\p{Lu}\p{N}_]{1,11}\z/
  MAX_COMPONENTS = 20
  MAX_NESTING_DEPTH = 5
  STALE_AFTER_DAYS = 5
  PENDING_FOR = 10.minutes

  belongs_to :family
  belongs_to :security
  has_many :components, -> { order(:position) }, class_name: "CustomInstrumentComponent", dependent: :delete_all

  before_validation :normalize_attributes
  before_save :save_with_family_lock
  before_save :save_security
  after_save :finish_save
  after_commit :enqueue_price_job

  before_destroy :prevent_destroy_when_in_use, prepend: true
  after_destroy :destroy_security

  validates :name, presence: true, length: { maximum: 100 }
  validates :symbol, presence: true
  validates :symbol, format: { with: SYMBOL_FORMAT }, allow_blank: true
  validates :symbol, uniqueness: { scope: :family_id, case_sensitive: false }, allow_blank: true
  validates :formula, presence: true
  validates :currency, presence: true
  validate :symbol_is_not_a_currency
  validate :currency_is_known
  validate :formula_is_resolvable, if: :resolution_needed?

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :alphabetically, -> { order(:symbol) }

  def self.depth_of_security(security, memo: {}, overrides: {})
    return 0 unless security&.custom?

    instrument = find_by(security_id: security.id)
    instrument ? depth_of(instrument, memo: memo, overrides: overrides) : 0
  end

  # An instrument made only of currencies and securities is depth 1. The
  # `overrides` hash lets validation ask what a dependent's depth would be
  # after this instrument's own depth changes.
  def self.depth_of(instrument, memo: {}, overrides: {})
    return overrides[instrument.id] if instrument.id && overrides.key?(instrument.id)
    return memo[instrument.id] if instrument.id && memo.key?(instrument.id)
    return 1 unless instrument

    memo[instrument.id] = 1 if instrument.id

    child_depths = instrument.components.map do |component|
      next 0 unless component.security_id

      security = component.security || Security.find_by(id: component.security_id)
      depth_of_security(security, memo: memo, overrides: overrides)
    end

    depth = 1 + child_depths.max.to_i
    memo[instrument.id] = depth if instrument.id
    depth
  end

  def self.depends_on?(instrument, target, visited = Set.new)
    return false if instrument.nil? || target.nil? || instrument.id.nil?
    return false unless visited.add?(instrument.id)

    instrument.components.any? do |component|
      next false unless component.security_id

      security = component.security || Security.find_by(id: component.security_id)
      child = security&.custom? ? find_by(security_id: security.id) : nil
      next false unless child

      child.id == target.id || depends_on?(child, target, visited)
    end
  end

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  def latest_price
    security.prices.order(date: :desc).first
  end

  def price_status
    price = latest_price

    if price.nil?
      updated_at && updated_at > PENDING_FOR.ago ? :pending : :missing
    elsif price.date < STALE_AFTER_DAYS.days.ago.to_date || stale_components.any?
      :stale
    else
      :ok
    end
  end

  # Components whose newest observation is older than the staleness window,
  # with the date of that observation (nil when there is none at all). A
  # same-currency currency component is a constant and can never be stale.
  def stale_components
    components.filter_map do |component|
      next if constant_component?(component)

      date = component_observation_date(component)
      next if date && date >= STALE_AFTER_DAYS.days.ago.to_date

      { component: component, date: date }
    end
  end

  def price_change(days: 30)
    current = latest_price
    return nil unless current

    previous = security.prices.where("date <= ?", current.date - days).order(date: :desc).first
    return nil unless previous

    Trend.new(current: money_for(current), previous: money_for(previous))
  end

  def trades
    security.trades
  end

  def holdings
    Holding.where(security_id: security_id)
  end

  def dependents
    CustomInstrument.where(
      id: CustomInstrumentComponent.where(security_id: security_id).select(:custom_instrument_id)
    )
  end

  def in_use?
    trades.exists? || holdings.exists? || dependents.exists?
  end

  def positions_for(user)
    accessible_ids = Account.accessible_by(user).select(:id)
    latest_ids = holdings.where(account_id: accessible_ids)
                         .select("DISTINCT ON (holdings.account_id) holdings.id")
                         .order("holdings.account_id, holdings.date DESC")

    holdings.where(id: latest_ids).where.not(qty: 0).order(date: :desc)
  end

  # Accounts trading or holding this instrument, or any instrument that
  # depends on it and is therefore repriced along with it.
  def affected_accounts
    ids = ([ security_id ] + transitive_dependents.map(&:security_id)).uniq
    trade_accounts = Trade.joins(:entry).where(security_id: ids).select("entries.account_id")
    holding_accounts = Holding.where(security_id: ids).select(:account_id)

    Account.where(id: trade_accounts).or(Account.where(id: holding_accounts))
  end

  def refresh_prices_later
    CustomInstrumentPriceJob.perform_later(self)
  end

  def import_prices(start_date:, end_date:, clear_cache: false)
    CustomInstrument::PriceImporter.new(self).import(
      start_date: start_date,
      end_date: end_date,
      clear_cache: clear_cache
    )
  end

  private
    def normalize_attributes
      self.name = name.to_s.strip
      self.symbol = symbol.to_s.strip.upcase
      self.currency = currency.respond_to?(:iso_code) ? currency.iso_code : currency.to_s.strip.upcase
      self.formula = formula.to_s.strip
      self.description = description.to_s.strip.presence

      build_custom_security if new_record?
      security.name = name if security
    end

    def build_custom_security
      self.security ||= Security.new(kind: "custom", offline: false)
      security.kind = "custom"
      security.ticker = "CUSTOM-#{SecureRandom.uuid}" if security.ticker.blank?
      security.offline = false
    end

    def save_security
      return unless security
      return unless security.new_record? || security.changed?

      security.save!
    end

    def symbol_is_not_a_currency
      return if symbol.blank?
      return unless Money::Currency.all.key?(symbol.downcase)

      errors.add(:symbol, :currency_code)
    end

    def currency_is_known
      return if currency.blank?
      return if Money::Currency.all.key?(currency.downcase)

      errors.add(:currency, :invalid)
    end

    def resolution_needed?
      new_record? || will_save_change_to_formula?
    end

    def constant_component?(component)
      component.currency.present? && component.currency == currency
    end

    def formula_is_resolvable
      @resolved_components = nil
      return if formula.blank? || family.nil?

      parsed = CustomInstrument::Formula.new(formula)
      unless parsed.valid?
        errors.add(:formula, parsed.error.message)
        return
      end

      resolved = CustomInstrument::ReferenceResolver.new(
        family: family,
        instrument: persisted? ? self : nil,
        create_securities: true
      ).resolve(parsed)

      @resolved_components = resolved

      errors.add(:formula, :no_components) if resolved.empty?
      errors.add(:formula, :too_many_components) if resolved.size > MAX_COMPONENTS
      resolved.each do |component|
        if component.weight.abs >= 10**15 || component.weight.to_d.round(18).zero?
          errors.add(:formula, :weight_out_of_range)
        end
      end
      return if errors[:formula].any?

      validate_nesting(resolved)
    rescue CustomInstrument::Formula::ParseError => error
      errors.add(:formula, error.message)
    rescue CustomInstrument::ReferenceResolver::Error => error
      errors.add(:formula, error.message)
    end

    def validate_nesting(resolved)
      depth = resolved_depth(resolved)

      if depth > MAX_NESTING_DEPTH
        errors.add(:formula, :nesting_too_deep)
        return
      end

      return unless persisted?

      overrides = { id => depth }
      if transitive_dependents.any? { |dependent| self.class.depth_of(dependent, overrides: overrides) > MAX_NESTING_DEPTH }
        errors.add(:formula, :nesting_too_deep)
      end
    end

    def resolved_depth(resolved)
      1 + resolved.filter_map do |component|
        next unless component.security&.custom?

        instrument = self.class.find_by(security_id: component.security.id)
        instrument ? self.class.depth_of(instrument) : 0
      end.max.to_i
    end

    def resolved_components
      @resolved_components ||= CustomInstrument::ReferenceResolver.new(
        family: family,
        instrument: persisted? ? self : nil,
        create_securities: true
      ).resolve(CustomInstrument::Formula.new(formula))
    end

    def replace_components
      resolved = resolved_components

      components.delete_all
      resolved.each_with_index do |component, index|
        components.create!(
          currency: component.security ? nil : component.currency,
          security: component.security,
          weight: component.weight.to_d.round(18),
          position: index
        )
      end
      components.reset
    end

    # A dependent's formula names this instrument by its old symbol. Rewriting
    # the text keeps it parsing, and deliberately skips callbacks so editing a
    # symbol does not throw away the dependent's price history.
    def rename_dependents
      return unless saved_change_to_symbol?

      old_symbol, new_symbol = saved_change_to_symbol
      return if old_symbol.blank?

      dependents.find_each do |dependent|
        rewritten = CustomInstrument::Formula.new(dependent.formula).rename(old_symbol, new_symbol)
        next if rewritten == dependent.formula

        dependent.update_columns(formula: rewritten, updated_at: Time.current)
      end
    end

    def clear_prices_on_definition_change
      @recalculate_prices = previously_new_record? || saved_change_to_formula? || saved_change_to_currency?
      return unless @recalculate_prices

      security.prices.delete_all
    end

    def enqueue_price_job
      return unless @recalculate_prices

      @recalculate_prices = false
      refresh_prices_later
    end

    def save_with_family_lock
      Family.transaction do
        Family.lock.find(family_id) if family_id
        abort_on_duplicate_symbol

        @replace_components_on_save = resolution_needed?
        abort_on_invalid_graph if @replace_components_on_save
      end
    end

    def finish_save
      replace_components if @replace_components_on_save
      rename_dependents
      clear_prices_on_definition_change
    ensure
      # A second save of this object must resolve and replace its own
      # components, never reuse the ones from the first save.
      @resolved_components = nil
      @replace_components_on_save = nil
    end

    def abort_on_duplicate_symbol
      value = symbol.to_s.strip.upcase
      return if value.blank?

      scope = CustomInstrument.where(family_id: family_id).where("UPPER(symbol) = ?", value)
      scope = scope.where.not(id: id) if persisted?
      return unless scope.exists?

      errors.add(:symbol, :taken)
      throw :abort
    end

    # Validation ran outside the lock; the graph may have changed while this
    # save waited for it. Both checks read the current rows, so two concurrent
    # edits cannot commit a cycle, and a new instrument cannot slip past the
    # depth limit because a referenced instrument got deeper.
    def abort_on_invalid_graph
      resolved = resolved_components

      if persisted?
        resolved.each do |component|
          next unless component.security&.custom?

          child = self.class.find_by(security_id: component.security.id)
          next unless child

          if child.id == id || self.class.depends_on?(child, self)
            errors.add(:formula, :cycle)
            throw :abort
          end
        end
      end

      depth = resolved_depth(resolved)
      if depth > MAX_NESTING_DEPTH
        errors.add(:formula, :nesting_too_deep)
        throw :abort
      end

      return unless persisted?

      overrides = { id => depth }
      if transitive_dependents.any? { |dependent| self.class.depth_of(dependent, overrides: overrides) > MAX_NESTING_DEPTH }
        errors.add(:formula, :nesting_too_deep)
        throw :abort
      end
    end

    def transitive_dependents
      seen = Set.new
      queue = dependents.to_a

      until queue.empty?
        dependent = queue.shift
        next unless seen.add?(dependent.id)

        queue.concat(dependent.dependents.to_a)
      end

      CustomInstrument.where(id: seen)
    end

    def component_observation_date(component)
      if component.currency.present?
        return nil if component.currency == currency

        ExchangeRate.where(from_currency: component.currency, to_currency: currency).maximum(:date)
      else
        Security::Price.where(security_id: component.security_id).maximum(:date)
      end
    end

    def prevent_destroy_when_in_use
      return if destroyed_by_association
      return unless in_use?

      errors.add(:base, :in_use)
      throw :abort
    end

    def destroy_security
      security.destroy! if security && !security.destroyed?
    end

    def money_for(price)
      Money.new(price.price, price.currency)
    end
end
