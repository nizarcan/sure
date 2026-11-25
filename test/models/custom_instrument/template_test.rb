require "test_helper"

class CustomInstrument::TemplateTest < ActiveSupport::TestCase
  test "lists the documented templates in order with groups and localized names" do
    templates = CustomInstrument::Template.all

    assert_equal %w[GRAU CEYREK YARIM TAM CUMHURIYET GREMSE BILEZIK22 GRAU14 KGAU GRAG KGAG BASKET],
                 templates.map(&:symbol)
    assert_equal %w[gold silver basket], templates.map(&:group).uniq
    assert_equal "Gram gold", I18n.with_locale(:en) { templates.first.name }
    assert_equal "Gram altın", I18n.with_locale(:tr) { templates.first.name }
    assert_equal "XAU / 31.1034768", templates.first.formula
    assert_equal "1 * XAU + 1 * XAG", templates.last.formula
  end

  test "every template formula parses and its symbol validates" do
    family = families(:dylan_family)

    CustomInstrument::Template.all.each do |template|
      formula = CustomInstrument::Formula.new(template.formula)
      assert formula.valid?, "#{template.symbol} formula should parse: #{formula.error&.message}"

      instrument = family.custom_instruments.create!(
        name: "#{template.symbol} test",
        symbol: template.symbol,
        currency: "USD",
        formula: template.formula
      )
      assert instrument.persisted?, "#{template.symbol} should be valid"
    end
  end
end
