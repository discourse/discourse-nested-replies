# frozen_string_literal: true

class AddWhisperCountsToNestedViewPostStats < ActiveRecord::Migration[7.2]
  def change
    add_column :nested_view_post_stats,
               :whisper_direct_reply_count,
               :integer,
               default: 0,
               null: false
    add_column :nested_view_post_stats,
               :whisper_total_descendant_count,
               :integer,
               default: 0,
               null: false
  end
end
