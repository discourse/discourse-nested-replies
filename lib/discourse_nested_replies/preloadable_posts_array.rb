# frozen_string_literal: true

module ::DiscourseNestedReplies
  # Array wrapper that makes TopicView.on_preload hooks work with
  # already-loaded post arrays. Translates ActiveRecord relation methods
  # (.includes, .pluck) to their array-compatible equivalents so that
  # plugin hooks calling topic_view.posts.includes(:association) or
  # topic_view.posts.pluck(:column) work transparently.
  class PreloadablePostsArray < Array
    def includes(*associations)
      ActiveRecord::Associations::Preloader.new(records: self, associations: associations).call
      self
    end

    def pluck(*columns)
      if columns.one?
        map(&columns.first)
      else
        map { |record| columns.map { |col| record.public_send(col) } }
      end
    end
  end
end
