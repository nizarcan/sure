class CreateCustomInstruments < ActiveRecord::Migration[8.1]
  def change
    create_table :custom_instruments, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :security, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { unique: true }
      t.string :name, null: false
      t.string :symbol, null: false
      t.text :formula, null: false
      t.string :currency, null: false
      t.text :description
      t.datetime :archived_at

      t.timestamps
    end

    add_index :custom_instruments, [ :family_id, :symbol ], unique: true

    create_table :custom_instrument_components, id: :uuid do |t|
      t.references :custom_instrument, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :currency
      t.references :security, foreign_key: { on_delete: :cascade }, type: :uuid
      t.decimal :weight, precision: 34, scale: 18, null: false
      t.integer :position, null: false

      t.timestamps
    end

    add_check_constraint :custom_instrument_components,
                         "(currency IS NULL) <> (security_id IS NULL)",
                         name: "chk_custom_instrument_components_source"

    reversible do |direction|
      direction.up do
        remove_check_constraint :securities, name: "chk_securities_kind"
        add_check_constraint :securities, "kind IN ('standard', 'cash', 'custom')", name: "chk_securities_kind"
      end

      direction.down do
        remove_check_constraint :securities, name: "chk_securities_kind"
        add_check_constraint :securities, "kind IN ('standard', 'cash')", name: "chk_securities_kind"
      end
    end
  end
end
