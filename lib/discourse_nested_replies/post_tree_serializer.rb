# frozen_string_literal: true

module ::DiscourseNestedReplies
  class PostTreeSerializer
    def initialize(topic:, topic_view:, guardian:)
      @topic = topic
      @topic_view = topic_view
      @guardian = guardian
    end

    def serialize_topic
      serializer = TopicViewSerializer.new(@topic_view, scope: @guardian, root: false)
      json = serializer.as_json
      json.except(:post_stream, :timeline_lookup, :user_badges)
    end

    def serialize_post(post, reply_counts, descendant_counts = {})
      post.topic = @topic
      serializer = PostSerializer.new(post, scope: @guardian, root: false)
      serializer.topic_view = @topic_view
      json = serializer.as_json

      # direct_reply_count: live query (always fresh, cheap GROUP BY on posts table).
      # total_descendant_count: from nested_view_post_stats (maintained by after_create/
      # after_destroy callbacks; may lag briefly during concurrent writes).
      # The frontend uses direct_reply_count for expand/collapse decisions and
      # total_descendant_count for display labels, with fallback chains.
      json[:direct_reply_count] = reply_counts[post.post_number] || 0
      json[:total_descendant_count] = descendant_counts[post.id] || 0
      json
    end

    # Recursively builds the nested JSON from the flat children_map.
    def serialize_tree(post, children_map, reply_counts, descendant_counts = {})
      node = serialize_post(post, reply_counts, descendant_counts)
      children = children_map[post.post_number] || []
      node[:children] = children.map do |child|
        serialize_tree(child, children_map, reply_counts, descendant_counts)
      end
      node
    end
  end
end
