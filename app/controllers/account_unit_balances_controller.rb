class AccountUnitBalancesController < ApplicationController
  include StreamExtensions

  MODES = %w[set add remove].freeze

  before_action :set_account
  before_action :ensure_instrument_account
  before_action :authorize_write, only: %i[new create]

  def new
    @mode = resolved_mode
    @date = Date.current
  end

  def create
    @mode = resolved_mode
    @date = date
    @quantity = unit_balance_params[:quantity]
    @unit_price = unit_balance_params[:unit_price]
    @unit_balance = Account::UnitBalance.new(@account)

    result = case @mode
    when "add"
      @unit_balance.add(quantity: quantity, date: @date, unit_price: unit_price)
    when "remove"
      @unit_balance.remove(quantity: quantity, date: @date)
    else
      @unit_balance.set(quantity: quantity, date: @date, unit_price: unit_price)
    end

    if result.success?
      respond_to do |format|
        format.html { redirect_to account_path(@account, tab: "activity"), notice: result.message }
        format.turbo_stream { stream_redirect_to(account_path(@account, tab: "activity"), notice: result.message) }
      end
    else
      @error_message = result.message
      render :new, status: :unprocessable_entity
    end
  end

  private
    def set_account
      @account = accessible_accounts.find(params[:account_id])
    end

    def authorize_write
      require_account_permission!(@account)
    end

    def ensure_instrument_account
      return if @account.instrument_account?

      redirect_to account_path(@account), alert: t("accounts.unit_balance.errors.not_an_instrument_account")
    end

    def resolved_mode
      params[:mode].presence_in(MODES) || unit_balance_params[:mode].presence_in(MODES) || "set"
    end

    def unit_balance_params
      return @unit_balance_params if defined?(@unit_balance_params)

      value = params[:unit_balance]
      @unit_balance_params = value.is_a?(ActionController::Parameters) ?
        value.permit(:date, :quantity, :unit_price, :mode) : ActionController::Parameters.new
    end

    def date
      value = unit_balance_params[:date]
      value.present? ? value.to_date : Date.current
    rescue Date::Error
      Date.current
    end

    def quantity
      unit_balance_params[:quantity].to_d
    end

    def unit_price
      unit_balance_params[:unit_price].presence&.to_d
    end
end
