# frozen_string_literal: true

class CreateNestedViewPostStats < ActiveRecord::Migration[7.2]
  def change
    create_table :nested_view_post_stats do |t|
      t.bigint :post_id, null: false
      t.integer :direct_reply_count, default: 0, null: false
      t.timestamps
    end

    add_index :nested_view_post_stats, :post_id, unique: true
  end
end
