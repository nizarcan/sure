module AccountableResource
  extend ActiveSupport::Concern

  included do
    include Periodable, StreamExtensions

    before_action :set_account, only: [ :show ]
    before_action :set_manageable_account, only: [ :edit, :update ]
    before_action :set_link_options, only: :new
  end

  class_methods do
    def permitted_accountable_attributes(*attrs)
      @permitted_accountable_attributes = attrs if attrs.any?
      @permitted_accountable_attributes ||= [ :id ]
    end
  end

  def new
    @account = Current.family.accounts.build(
      currency: Current.family.currency,
      accountable: accountable_type.new
    )
    apply_requested_instrument(@account)
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: safe_per_page(10))
  end

  def edit
  end

  def create
    if instrument_selection_id
      create_instrument_account
      return
    end

    opening_balance_date = parsed_opening_balance_date
    Account.transaction do
      # A new account has no sales to restate, so it starts on the default method.
      @account = Current.family.accounts.create_and_sync(
        account_params.except(:return_to, :opening_balance_date, :cost_basis_method, :unit_price).merge(owner: Current.user, logo_chosen: logo_chosen?),
        opening_balance_date: opening_balance_date
      )
      @account.lock_saved_attributes!
    end
    apply_logo_choice

    redirect_to create_return_path,
                notice: t("accounts.create.success", type: accountable_type.name.underscore.humanize)
  rescue ActiveRecord::RecordInvalid => e
    # `create_and_sync` saves with `save!`. A validation the user can trip from
    # the form (a half-filled loan rate change, say) must come back as the form
    # with the error and what they typed, not as the generic 422 page. The
    # transaction above has already rolled back. The record on the exception is
    # usually the unsaved account with its nested accountable still attached --
    # but the opening valuation's `entries.create!` or `lock_saved_attributes!`
    # can raise too, and then it is an Entry or the accountable, neither of
    # which the form can render. Recover the account through it, or rebuild
    # it from what was submitted so the form comes back filled in rather
    # than blank.
    @account = if e.record.is_a?(Account)
      e.record
    else
      e.record.try(:account) || rebuilt_account_from_submission
    end
    @error_message = e.record.errors.full_messages.join(", ").presence || e.message
    # The `new` template's method-selection branch reads `@provider_configs`,
    # which the `new` action's before_action sets up; this render needs it too.
    set_link_options
    render :new, status: :unprocessable_entity
  end

  def update
    # Assigning a balance can fail before the normal update path assigns the
    # other submitted fields. Keep them available for the 422 form without
    # persisting them.
    update_params = account_params.except(:return_to, :balance, :opening_balance_date, :cost_basis_method, :unit_price)
    # Every account type posts through here; only one with trades has lots to
    # sell. Applied after the other fields, since the same form can change a
    # crypto account's subtype and with it whether the account trades.
    cost_basis_method = account_params[:cost_basis_method]
    previous_cost_basis_method = @account.cost_basis_method
    # An uploaded logo is meant to be seen, so it takes over from Brandfetch.
    update_params[:logo_selection] = "automatic" if account_params[:logo].present?
    @account.logo_chosen = logo_chosen?

    # The balance change and the attribute update are one form, so they commit
    # or roll back as one. `set_current_balance` writes a valuation and the
    # account's cached balance; before this, a validation failing on the
    # attributes (a half-filled loan rate change, say) returned 422 with the
    # balance half of the rejected form already committed.
    saved = Account.transaction do
      # Handle balance update if the value actually changed
      if account_params[:balance].present? && account_params[:balance].to_d != @account.balance
        result = @account.set_current_balance(account_params[:balance].to_d)
        unless result.success?
          @account.assign_attributes(update_params)
          @error_message = result.error
          raise ActiveRecord::Rollback
        end
      end

      # Update remaining account attributes. Note: currency is intentionally allowed
      # here so all account types (depositories, credit cards, loans, etc.) can
      # have their currency changed via this shared update path.
      # One save: lock_saved_attributes! below locks what this save changed,
      # and a second save would leave it nothing to lock.
      @account.assign_attributes(update_params)
      @account.cost_basis_method = cost_basis_method if cost_basis_method && @account.supports_trades?
      unless @account.save
        @error_message = @account.errors.full_messages.join(", ")
        raise ActiveRecord::Rollback
      end

      # Inside the transaction, as `create` does: the locks are saved with
      # `update!`, and a raise there after the commit left the balance and the
      # attributes above in place behind a failed request.
      @account.lock_saved_attributes!

      true
    rescue ActiveRecord::RecordInvalid => e
      @error_message = e.record.errors.full_messages.join(", ").presence || e.message
      raise ActiveRecord::Rollback
    end

    unless saved
      render :edit, status: :unprocessable_entity
      return
    end

    apply_logo_choice
    # The stored figures were worked out under the old method; a sync restates
    # them. Compared by hand: lock_saved_attributes! saves again, which clears
    # saved_change_to_cost_basis_method?.
    @account.sync_later if @account.cost_basis_method != previous_cost_basis_method
    @account_updated = true

    notice = t("accounts.update.success", type: accountable_type.name.underscore.humanize)
    respond_to do |format|
      format.html { redirect_back_or_to account_path(@account), notice: notice }
      # The form submitted through Turbo from the modal: return to the page it
      # was opened on with a "replace" visit, which Turbo turns into a
      # morphing refresh of the same page, keeping its scroll position.
      format.turbo_stream do
        flash[:notice] = notice
        render turbo_stream: turbo_stream.action(:redirect, url_from(request.referer) || account_path(@account))
      end
    end
  end

  private
    # Whether `update` saved the account, for controllers that save more after it.
    def account_updated?
      @account_updated.present?
    end

    def parsed_opening_balance_date
      begin
        account_params[:opening_balance_date].presence&.to_date
      rescue Date::Error
        nil
      end || (Time.zone.today - 2.years)
    end

    # The id an investment form's currency picker carries when the account is
    # to be held in one of the family's custom instruments. Another account
    # type that submits one is refused by Account's own validation rather than
    # falling through with a currency code the app cannot format.
    def instrument_selection_id
      value = account_params[:currency].to_s
      value.delete_prefix("instrument:") if value.start_with?("instrument:")
    end

    # Only the investment form offers instruments, and only for a new manual
    # account, so the picker starts on the requested instrument.
    def apply_requested_instrument(account)
      return unless accountable_type == Investment
      return if params[:instrument].blank?

      instrument = Current.family.custom_instruments.active.find_by(id: params[:instrument])
      return unless instrument

      account.custom_instrument = instrument
      account.currency = "instrument:#{instrument.id}"
    end

    # The instrument account starts empty, anchored at zero on the opening
    # date, and the entered quantity is then booked as its first units. Both
    # commit together, so an invalid quantity leaves no account behind.
    def create_instrument_account
      instrument = Current.family.custom_instruments.active.find_by(id: instrument_selection_id)
      return render_instrument_form_error(rebuilt_instrument_account, t("accounts.create.instrument_not_found")) unless instrument

      quantity = account_params[:balance].to_d
      # Zero opens an empty account to fill later; only a negative is refused.
      if quantity.negative?
        return render_instrument_form_error(
          rebuilt_instrument_account(instrument, quantity: account_params[:balance]),
          t("accounts.create.quantity_cannot_be_negative")
        )
      end

      opening_balance_date = parsed_opening_balance_date
      unit_price = account_params[:unit_price].presence&.to_d
      created = false

      Account.transaction do
        # The zero anchor sits the day before the units. On the units' own date
        # the balance calculator would read the holding as a negative cash
        # position, because it derives cash as the anchor total minus holdings;
        # a day earlier there is nothing to subtract, so cash starts at zero and
        # the units alone carry the account's value.
        @account = Current.family.accounts.create_and_sync(
          instrument_account_attributes(instrument),
          opening_balance_date: opening_balance_date - 1.day
        )
        result = if quantity.positive?
          Account::UnitBalance.new(@account).add(quantity: quantity, date: opening_balance_date, unit_price: unit_price)
        end
        if result && !result.success?
          @error_message = result.message
          raise ActiveRecord::Rollback
        end
        @account.lock_saved_attributes!
        created = true
      end

      unless created
        return render_instrument_form_error(
          rebuilt_instrument_account(instrument, quantity: account_params[:balance]),
          @error_message
        )
      end

      apply_logo_choice
      redirect_to create_return_path,
                  notice: t("accounts.create.success", type: accountable_type.name.underscore.humanize)
    rescue ActiveRecord::RecordInvalid => e
      render_instrument_form_error(
        rebuilt_instrument_account(instrument, quantity: account_params[:balance]),
        e.record.errors.full_messages.join(", ").presence || e.message
      )
    end

    def instrument_account_attributes(instrument)
      account_params
        .except(:return_to, :opening_balance_date, :cost_basis_method, :balance, :currency, :unit_price)
        .merge(
          owner: Current.user,
          logo_chosen: logo_chosen?,
          currency: instrument.currency,
          custom_instrument: instrument,
          balance: 0,
          cash_balance: 0
        )
    end

    # The form the 422 renders, still on the chosen instrument and holding the
    # quantity the user typed. `currency` carries the picker's own value so the
    # instrument stays selected; the model resolves it from `custom_instrument`.
    def rebuilt_instrument_account(instrument = nil, quantity: account_params[:balance])
      attributes = account_params.except(:return_to, :opening_balance_date, :cost_basis_method, :unit_price)
      attributes[:currency] = "instrument:#{instrument.id}" if instrument
      attributes[:balance] = quantity
      attributes[:accountable_attributes] ||= {}
      Current.family.accounts.build(attributes.merge(custom_instrument: instrument))
    end

    def render_instrument_form_error(account, message)
      @account = account
      @error_message = message
      set_link_options
      render :new, status: :unprocessable_entity
    end

    # Prefer the form-carried return_to, then the session value StoreLocation
    # captured from `?return_to=` (survives multi-step flows where the param
    # isn't threaded), then the account page. The form param is sanitized here
    # (the session value is already filtered at store time); the session is
    # consumed with delete so a stale value can't leak into a later flow.
    def create_return_path
      safe_return_to(account_params[:return_to]) || session.delete(:return_to).presence || @account
    end

    def logo_choice
      params.dig(:account, :logo_choice).presence
    end

    # An icon picked or uploaded in the form wins over the automatic fetch
    # that a new domain would otherwise queue.
    def logo_chosen?
      logo_choice.present? || account_params[:logo].present?
    end

    # The icon picked in the form downloads only on save, after the account
    # committed, and an upload in the same submit wins over it.
    def apply_logo_choice
      return unless logo_choice && account_params[:logo].blank?
      return if @account.choose_logo(logo_choice)

      flash[:alert] = t("accounts.update.logo_not_applied")
      # The choice held back the automatic fetch; with it gone, that fetch
      # replaces or drops an automatic icon left from an earlier domain.
      AccountLogoFetchJob.perform_paced(@account)
    end

    # The account the 422 form renders when the exception carried none.
    #
    # `accountable_attributes` is defaulted the way `create_and_sync` defaults
    # it. `accountable_type=` only writes the type column: the accountable
    # object itself is built as a side effect of `accountable_attributes=` or
    # of `subtype=`. A submission that names neither -- a loan form whose
    # nested fields are all blank, say -- rebuilt an account with a nil
    # `accountable`, and the form came back without any of the type's own
    # inputs, which is the opposite of what this rescue exists to do.
    def rebuilt_account_from_submission
      attributes = account_params.except(:return_to, :opening_balance_date, :unit_price)
      attributes[:accountable_attributes] ||= {}
      Current.family.accounts.build(attributes)
    end

    def set_link_options
      account_type_name = accountable_type.name

      # Get all available provider configs dynamically for this account type
      @provider_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: account_type_name,
        family: Current.family
      )
    end

    def accountable_type
      controller_name.classify.constantize
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:id])
    end

    def set_manageable_account
      @account = Current.user.accessible_accounts.find(params[:id])
      require_account_permission!(@account)
    end

    def account_params
      params.require(:account).permit(
        :name, :balance, :subtype, :currency, :accountable_type, :return_to,
        :opening_balance_date,
        :institution_name, :institution_domain, :notes, :exclude_from_reports,
        :enable_category_matcher, :cost_basis_method, :logo, :unit_price,
        accountable_attributes: self.class.permitted_accountable_attributes
      )
    end
end
