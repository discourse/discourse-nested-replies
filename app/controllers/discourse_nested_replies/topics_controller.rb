# frozen_string_literal: true

module DiscourseNestedReplies
  class TopicsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    def show
      topic = find_topic
      tree_builder = TreeBuilder.new(
        topic,
        guardian,
        page: params[:page]&.to_i || 1,
        post_number: params[:post_number]&.to_i,
        sort: params[:sort],
      )

      render_nested_tree(topic, tree_builder.build)
    end

    def thread
      topic = find_topic

      post_number = params[:post_number]&.to_i
      raise Discourse::NotFound unless post_number

      tree_builder = TreeBuilder.new(topic, guardian)
      tree_data = tree_builder.build_thread(post_number)

      render_nested_tree(topic, tree_data)
    end

    def load_more_replies
      post = Post.find_by(id: params[:post_id])
      raise Discourse::NotFound unless post

      topic = post.topic
      guardian.ensure_can_see!(post)
      guardian.ensure_can_see!(topic)

      tree_builder = TreeBuilder.new(topic, guardian)
      all_replies = tree_builder.collect_all_replies(post)

      offset = params[:offset].to_i
      limit = params[:limit]&.to_i || SiteSetting.nested_replies_load_more_count

      paginated_replies = all_replies[offset, limit] || []
      has_more = all_replies.size > (offset + paginated_replies.size)

      post_ids = paginated_replies.map(&:id)
      topic_view = TopicView.new(topic.id, current_user, post_ids: post_ids) if post_ids.any?

      serialized_posts =
        paginated_replies.map do |reply|
          reply.topic = topic
          serializer = PostSerializer.new(reply, scope: guardian, root: false)
          serializer.topic_view = topic_view if topic_view
          serializer.as_json
        end

      render json: {
               posts: serialized_posts,
               has_more_replies: has_more,
               loaded_count: offset + paginated_replies.size,
               total_count: all_replies.size,
             }
    end

    private

    def find_topic
      topic = Topic.find_by(id: params[:id])
      raise Discourse::NotFound unless topic
      guardian.ensure_can_see!(topic)
      topic
    end

    def render_nested_tree(topic, tree_data)
      all_post_ids = TreeBuilder.collect_post_ids(tree_data)
      topic_view = TopicView.new(topic.id, current_user, post_ids: all_post_ids)
      tree_data[:topic_view] = topic_view

      render json: NestedTopicViewSerializer.new(tree_data, scope: guardian, root: false)
    end
  end
end
