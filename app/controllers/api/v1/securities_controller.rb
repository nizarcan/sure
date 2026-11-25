# frozen_string_literal: true

class Api::V1::SecuritiesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceFiltering

  before_action :ensure_read_scope
  before_action :set_security, only: :show

  def index
    securities_query = apply_filters(securities_scope).order(:ticker, :exchange_operating_mic, :name)
    @per_page = safe_per_page_param

    @pagy, @securities = pagy(
      securities_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::SecurityResourceFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  private

    def set_security
      raise ActiveRecord::RecordNotFound, "Security not found" unless valid_uuid?(params[:id])

      @security = securities_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def securities_scope
      Security
        .where(id: scoped_security_ids)
        .includes(:custom_instrument)
    end

    def apply_filters(query)
      query = filter_by_ticker(query) if params[:ticker].present?
      query = query.where(exchange_operating_mic: params[:exchange_operating_mic].to_s.strip.upcase) if params[:exchange_operating_mic].present?
      if params[:kind].present?
        invalid_filter!("kind must be one of: #{Security::KINDS.join(', ')}") unless Security::KINDS.include?(params[:kind])

        query = query.where(kind: params[:kind])
      end
      if params.key?(:offline)
        offline = parse_boolean_filter_param(:offline)
        query = query.where(offline: offline)
      end
      query
    end

    # A custom security's ticker is a globally unique CUSTOM-<uuid>, so users
    # know it by its instrument's symbol instead. Only this family's own
    # instruments are matched; the result stays inside securities_scope.
    def filter_by_ticker(query)
      value = params[:ticker].to_s.strip
      custom_security_ids = current_resource_owner.family.custom_instruments
        .where("UPPER(symbol) = ?", value.upcase)
        .select(:security_id)

      query.where(
        "LOWER(securities.ticker) = :ticker OR securities.id IN (:custom_security_ids)",
        ticker: value.downcase,
        custom_security_ids: custom_security_ids
      )
    end
end
