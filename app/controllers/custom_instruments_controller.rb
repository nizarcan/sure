class CustomInstrumentsController < ApplicationController
  include StreamExtensions

  QUICK_START_KEYS = %i[grau ceyrek grag basket].freeze

  before_action :require_non_guest!, except: %i[index show]
  before_action :set_instrument, only: %i[show edit update destroy archive unarchive refresh add_units]

  def index
    instruments = Current.family.custom_instruments.alphabetically.includes(:security).to_a
    @instruments = instruments.select { |instrument| !instrument.archived? }
    @archived_instruments = instruments.select(&:archived?)
    @quick_start_templates = CustomInstrument::Template.all.select { |template| QUICK_START_KEYS.include?(template.key) }

    @latest_prices = latest_prices_for(instruments)
    @previous_prices = prices_on_or_before(instruments, Date.current - 30.days)
    @positions = positions_by_security(instruments)
    @statuses = instruments.to_h { |instrument| [ instrument.id, instrument.price_status ] }

    render layout: "settings"
  end

  def show
    @positions = @instrument.positions_for(Current.user).includes(:account)
    @dependents = @instrument.dependents.alphabetically.includes(:security)
    @status = @instrument.price_status
    @stale_components = @instrument.stale_components
    @series = price_series
    @quote = begin
      quote_for(@instrument.formula)
    rescue StandardError => error
      log_quote_failure(error)
      @quote_error = t(".price_fetch_failed")
      nil
    end
  end

  def new
    @instrument = Current.family.custom_instruments.new(currency: Current.family.primary_currency_code)
    @templates = CustomInstrument::Template.all
    @selected_template = @templates.find { |template| template.key.to_s == params[:template].to_s }
    apply_template(@instrument, @selected_template) if @selected_template
  end

  def create
    @instrument = Current.family.custom_instruments.new(instrument_params)
    @templates = CustomInstrument::Template.all

    if @instrument.save
      redirect_after_save(t(".created"))
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @templates = CustomInstrument::Template.all
    @affected_account_count = affected_account_count
  end

  def update
    @templates = CustomInstrument::Template.all

    if @instrument.update(instrument_params)
      redirect_after_save(t(".updated"))
    else
      @affected_account_count = affected_account_count
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @instrument.destroy

    if @instrument.destroyed?
      redirect_back_or_to custom_instruments_path, notice: t(".deleted")
    else
      redirect_back_or_to custom_instruments_path, alert: t(".in_use")
    end
  end

  def archive
    @instrument.archive!
    redirect_back_or_to custom_instruments_path, notice: t(".archived")
  end

  def unarchive
    @instrument.unarchive!
    redirect_back_or_to custom_instruments_path, notice: t(".unarchived")
  end

  def refresh
    @instrument.refresh_prices_later
    redirect_back_or_to custom_instruments_path, notice: t(".refresh_queued")
  end

  def add_units
    if @instrument.archived?
      redirect_to custom_instruments_path, alert: t(".archived")
      return
    end

    @accounts = eligible_accounts

    # Back from creating the account the empty state offered: with only that
    # one to choose from, go straight on to adding the units.
    if params[:account_created].present? && @accounts.one?
      redirect_to new_trade_path(account_id: @accounts.first.id, type: Trade::CreateForm::OPENING_TYPE, security: "#{@instrument.security.ticker}||custom")
    end
  end

  def preview
    @instrument = Current.family.custom_instruments.find_by(id: params[:id]) if params[:id].present?
    @symbol = (params[:symbol].presence || @instrument&.symbol)&.upcase
    @currency = preview_currency
    @formula = params[:formula].to_s

    if @formula.strip.present?
      @quote = CustomInstrument::Quote.new(
        family: Current.family,
        formula_text: @formula,
        currency: @currency,
        instrument: @instrument
      )
    end
  rescue StandardError => error
    log_quote_failure(error)
    @quote = nil
    @quote_error = t(".price_fetch_failed")
  ensure
    # A blank formula has nothing to price; an error still renders the
    # friendly message, so every response is a 200 with the target's content.
    render partial: "custom_instruments/preview", locals: preview_locals, layout: false
  end

  private
    def set_instrument
      @instrument = Current.family.custom_instruments.includes(:security).find(params[:id])
    end

    def instrument_params
      params.require(:custom_instrument).permit(:name, :symbol, :formula, :currency, :description)
    end

    def apply_template(instrument, template)
      instrument.name = template.name
      instrument.symbol = template.symbol
      instrument.formula = template.formula
    end

    def redirect_after_save(notice)
      target = url_from(params[:return_to]) || custom_instruments_path

      if request.format.turbo_stream?
        flash[:notice] = notice
        render turbo_stream: turbo_stream.action(:redirect, target)
      else
        frame_redirect_to(target, notice: notice)
      end
    end

    def affected_account_count
      accessible_ids = Current.user.accessible_accounts.select(:id)

      @instrument.affected_accounts.where(id: accessible_ids).count
    end

    def eligible_accounts
      Current.user.accessible_accounts
             .writable_by(Current.user)
             .visible
             .manual
             .where(accountable_type: %w[Investment Crypto])
             .alphabetically
             .to_a
    end

    def preview_currency
      code = params[:currency].presence || @instrument&.currency || Current.family.primary_currency_code

      Money::Currency.all.key?(code.to_s.downcase) ? code : Current.family.primary_currency_code
    end

    def preview_locals
      {
        quote: @quote,
        error: @quote_error,
        symbol: @symbol,
        formula: @formula,
        currency: @currency
      }
    end

    # One query per fact rather than one per row: the newest stored price of
    # each instrument's security, the newest one at least 30 days old, and the
    # latest holding snapshot per account for the accounts this user may see.
    def latest_prices_for(instruments)
      prices_for(instruments, ->(scope) { scope })
    end

    def prices_on_or_before(instruments, date)
      prices_for(instruments, ->(scope) { scope.where(date: ..date) })
    end

    def prices_for(instruments, filter)
      security_ids = instruments.map(&:security_id)
      return {} if security_ids.empty?

      scope = Security::Price.where(security_id: security_ids)
      filter.call(scope)
            .select("DISTINCT ON (security_id) security_id, price, currency, date")
            .order(:security_id, date: :desc)
            .to_h { |price| [ price.security_id, price ] }
    end

    def positions_by_security(instruments)
      security_ids = instruments.map(&:security_id)
      return {} if security_ids.empty?

      accessible_ids = Account.accessible_by(Current.user).select(:id)
      latest_ids = Holding.where(security_id: security_ids, account_id: accessible_ids)
                          .select("DISTINCT ON (security_id, account_id) holdings.id")
                          .order(:security_id, :account_id, date: :desc)

      Holding.where(id: latest_ids).where.not(qty: 0).group_by(&:security_id)
    end

    def price_series
      rows = @instrument.security.prices
                      .where(date: (1.year.ago.to_date)..Date.current)
                      .order(:date)
                      .pluck(:date, :price)
      return nil if rows.size < 2

      Series.from_raw_values(
        rows.map { |date, price| { date: date, value: Money.new(price, @instrument.currency) } }
      )
    end

    def quote_for(formula)
      CustomInstrument::Quote.new(
        family: Current.family,
        formula_text: formula,
        currency: @instrument.currency,
        instrument: @instrument
      )
    end

    def log_quote_failure(error)
      Rails.logger.warn(
        "[CustomInstrumentsController] Could not price custom instrument #{@instrument&.id}: #{error.class}: #{error.message}"
      )
    end
end
