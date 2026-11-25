module CustomInstrumentTestHelper
  def create_custom_instrument(family: families(:dylan_family), name: "Gram gold", symbol: "GRAU",
                               currency: "USD", formula: "XAU / 31.1034768", **attributes)
    family.custom_instruments.create!(
      name: name,
      symbol: symbol,
      currency: currency,
      formula: formula,
      **attributes
    )
  end

  def create_security_with_price(ticker, price:, currency: "USD", date: Date.current, mic: nil, offline: false)
    security = Security.create!(ticker: ticker, exchange_operating_mic: mic, offline: offline)
    Security::Price.create!(security: security, date: date, price: price, currency: currency)
    security
  end
end
