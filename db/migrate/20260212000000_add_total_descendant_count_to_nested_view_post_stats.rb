# frozen_string_literal: true

class AddTotalDescendantCountToNestedViewPostStats < ActiveRecord::Migration[7.2]
  def change
    add_column :nested_view_post_stats, :total_descendant_count, :integer, default: 0, null: false
  end
end
