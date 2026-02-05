# frozen_string_literal: true

module DiscourseNestedReplies
  class NestedPostNodeSerializer < ApplicationSerializer
    attr_accessor :topic_view

    def initialize(object, options = {})
      super(object, options)
      @topic_view = options[:topic_view]
    end

    def as_json(options = {})
      {
        post: serialize_post(object[:post]),
        replies: object[:replies].map { |reply| serialize_post(reply) },
        total_reply_count: object[:total_reply_count],
        loaded_reply_count: object[:loaded_reply_count],
        has_more_replies: object[:has_more_replies],
        highlighted: object[:highlighted],
      }
    end

    private

    def serialize_post(post)
      post.topic = @topic_view.topic if @topic_view

      serializer = PostSerializer.new(post, scope: scope, root: false)

      # Set topic_view like PostStreamSerializerMixin does (line 65)
      # This enables PostSerializer to access:
      # - all_post_actions (PostAction.counts_for)
      # - link_counts (TopicLink.counts_for)
      # - bookmarks (Bookmark.for_user_in_topic)
      # - And all other preloaded data
      serializer.topic_view = @topic_view if @topic_view

      serializer.as_json
    end
  end
end
