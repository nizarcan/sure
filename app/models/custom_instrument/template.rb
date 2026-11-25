class CustomInstrument::Template
  DEFINITIONS = [
    { key: :grau,       symbol: "GRAU",       group: "gold",   formula: "XAU / 31.1034768" },
    { key: :ceyrek,     symbol: "CEYREK",     group: "gold",   formula: "1.754 * 0.9166 * XAU / 31.1034768" },
    { key: :yarim,      symbol: "YARIM",      group: "gold",   formula: "3.508 * 0.9166 * XAU / 31.1034768" },
    { key: :tam,        symbol: "TAM",        group: "gold",   formula: "7.016 * 0.9166 * XAU / 31.1034768" },
    { key: :cumhuriyet, symbol: "CUMHURIYET", group: "gold",   formula: "7.216 * 0.9166 * XAU / 31.1034768" },
    { key: :gremse,     symbol: "GREMSE",     group: "gold",   formula: "17.54 * 0.9166 * XAU / 31.1034768" },
    { key: :bilezik22,  symbol: "BILEZIK22",  group: "gold",   formula: "0.916 * XAU / 31.1034768" },
    { key: :grau14,     symbol: "GRAU14",     group: "gold",   formula: "0.585 * XAU / 31.1034768" },
    { key: :kgau,       symbol: "KGAU",       group: "gold",   formula: "1000 * XAU / 31.1034768" },
    { key: :grag,       symbol: "GRAG",       group: "silver", formula: "XAG / 31.1034768" },
    { key: :kgag,       symbol: "KGAG",       group: "silver", formula: "1000 * XAG / 31.1034768" },
    { key: :basket,     symbol: "BASKET",     group: "basket", formula: "1 * XAU + 1 * XAG" }
  ].freeze

  attr_reader :key, :symbol, :formula, :group

  def initialize(key:, symbol:, formula:, group:)
    @key = key
    @symbol = symbol
    @formula = formula
    @group = group
  end

  def self.all
    DEFINITIONS.map do |definition|
      new(
        key: definition[:key],
        symbol: definition[:symbol],
        formula: definition[:formula],
        group: definition[:group]
      )
    end
  end

  def name
    I18n.t("custom_instruments.templates.#{key}.name")
  end
end
