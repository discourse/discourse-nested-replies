# frozen_string_literal: true

module DiscourseNestedReplies
  class NestedTopicViewSerializer < ApplicationSerializer
    def as_json(options = {})
      topic_view = object[:topic_view]

      {
        nested_posts:
          object[:nested_posts].map do |node|
            NestedPostNodeSerializer.new(
              node,
              scope: scope,
              root: false,
              topic_view: topic_view
            ).as_json
          end,
        meta: object[:meta],
        stream: object[:stream],
      }
    end
  end
end
