class SecuritiesController < ApplicationController
  # The family's own instruments come first, above provider results, so a
  # short query always lists what the user defined before it lists strangers.
  CUSTOM_RESULTS_LIMIT = 10

  def index
    @securities = custom_securities + Security.search_provider(
      params[:q],
      country_code: params[:country_code].presence
    )
  end

  private
    def custom_securities
      return [] if params[:exclude_custom].present?

      query = params[:q].to_s.strip.downcase
      instruments = Current.family.custom_instruments.active.alphabetically.includes(:security)

      if query.present?
        instruments = instruments.select do |instrument|
          instrument.symbol.downcase.include?(query) || instrument.name.to_s.downcase.include?(query)
        end
      end

      instruments.first(CUSTOM_RESULTS_LIMIT).map(&:security)
    end
end
