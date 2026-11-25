require "test_helper"

class CustomInstrumentsHelperTest < ActionView::TestCase
  test "formats a component weight with up to ten significant digits" do
    {
      "0.0516892825306" => "0.05168928253",
      "1" => "1",
      "1000" => "1000",
      "0.0000123" => "0.0000123",
      "123456789.123456" => "123456789.1",
      "1.754" => "1.754",
      "2.5" => "2.5"
    }.each do |weight, expected|
      assert_equal expected, custom_instrument_weight(BigDecimal(weight)), "weight #{weight}"
    end
  end
end
