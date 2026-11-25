class AddCustomInstrumentToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_reference :accounts, :custom_instrument, type: :uuid, foreign_key: { on_delete: :restrict }
  end
end
