require "test_helper"

class CustomInstrumentComponentTest < ActiveSupport::TestCase
  include CustomInstrumentTestHelper

  setup do
    @instrument = create_custom_instrument(family: families(:dylan_family), symbol: "COMPTEST")
  end

  test "accepts exactly one source" do
    currency_component = @instrument.components.create!(currency: "USD", weight: 1, position: 0)
    security = Security.create!(ticker: "COMPSTOCK", exchange_operating_mic: "XNAS")
    security_component = @instrument.components.create!(security: security, weight: 1, position: 1)

    assert currency_component.persisted?
    assert security_component.persisted?
  end

  test "rejects neither or both sources" do
    neither = @instrument.components.new(weight: 1, position: 0)
    assert_not neither.valid?
    assert neither.errors[:base].any?

    security = Security.create!(ticker: "COMPBOTH", exchange_operating_mic: "XNAS")
    both = @instrument.components.new(currency: "USD", security: security, weight: 1, position: 0)
    assert_not both.valid?
    assert both.errors[:base].any?
  end

  test "the database enforces the one-source check" do
    security = Security.create!(ticker: "COMPDB", exchange_operating_mic: "XNAS")

    assert_raises(ActiveRecord::StatementInvalid) do
      CustomInstrumentComponent.transaction(requires_new: true) do
        @instrument.components.insert_all!([
          {
            custom_instrument_id: @instrument.id,
            currency: "USD",
            security_id: security.id,
            weight: 1,
            position: 0,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end
  end
end
