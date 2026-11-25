class CustomInstrumentComponent < ApplicationRecord
  belongs_to :custom_instrument
  belongs_to :security, optional: true

  validates :weight, :position, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true, if: -> { security_id.blank? }
  validates :security, presence: true, if: -> { currency.blank? }

  validate :exactly_one_source

  private
    def exactly_one_source
      return if currency.blank? ^ security_id.blank?

      errors.add(:base, :one_source)
    end
end
