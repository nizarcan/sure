class Security::ComboboxOption
  include ActiveModel::Model

  attr_accessor :symbol, :name, :logo_url, :exchange_operating_mic, :country_code, :price_provider, :currency, :isin,
                :ticker, :custom, :formula

  def id
    "#{ticker || symbol}|#{exchange_operating_mic}|#{price_provider}"
  end

  def custom?
    !!custom
  end

  def exchange_name
    Security.exchange_name_for(exchange_operating_mic)
  end

  def to_combobox_display
    # A custom instrument has no exchange, so the provider shape would print
    # an empty "()" after its name.
    return I18n.t("securities.combobox.display_custom", symbol: symbol, name: name) if custom?

    I18n.t(
      "securities.combobox.display",
      symbol: symbol,
      name: name,
      exchange: exchange_name
    )
  end
end
