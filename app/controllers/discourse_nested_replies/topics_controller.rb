# frozen_string_literal: true

module DiscourseNestedReplies
  class TopicsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    def show
      topic = Topic.find_by(id: params[:id])
      raise Discourse::NotFound unless topic

      guardian.ensure_can_see!(topic)

      page = params[:page]&.to_i || 1
      post_number = params[:post_number]&.to_i
      sort = params[:sort]

      tree_data =
        TreeBuilder.new(topic, guardian, page: page, post_number: post_number, sort: sort).build

      # Create TopicView with all post IDs for data preloading
      # This loads post_actions, bookmarks, link_counts, custom_fields, etc.
      all_post_ids = []
      tree_data[:nested_posts].each do |node|
        all_post_ids << node[:post].id
        all_post_ids.concat(node[:replies].map(&:id))
      end

      @topic_view = TopicView.new(topic.id, current_user, post_ids: all_post_ids.uniq)

      # Pass both tree structure and TopicView to serializer
      tree_data[:topic_view] = @topic_view

      render json: NestedTopicViewSerializer.new(tree_data, scope: guardian, root: false)
    end

    def load_more_replies
      post = Post.find_by(id: params[:post_id])
      raise Discourse::NotFound unless post

      topic = post.topic
      guardian.ensure_can_see!(post)
      guardian.ensure_can_see!(topic)

      offset = params[:offset].to_i
      limit = params[:limit]&.to_i || SiteSetting.nested_replies_load_more_count

      # Get all replies to this post (flattened, recursive)
      all_replies = collect_all_replies(post, topic)

      # Paginate
      paginated_replies = all_replies[offset, limit] || []
      has_more = all_replies.size > (offset + paginated_replies.size)

      # Create TopicView for data preloading
      post_ids = paginated_replies.map(&:id)
      topic_view = TopicView.new(topic.id, current_user, post_ids: post_ids) if post_ids.any?

      # Serialize posts
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

    def collect_all_replies(parent_post, topic, collected = [], visited = Set.new)
      return collected if visited.include?(parent_post.id)
      visited.add(parent_post.id)

      # Find direct children
      direct_children =
        topic
          .posts
          .secured(guardian)
          .where(reply_to_post_number: parent_post.post_number)
          .order(:created_at)
          .to_a

      # Add them and recurse to get grandchildren
      direct_children.each do |child|
        collected << child
        collect_all_replies(child, topic, collected, visited)
      end

      collected
    end
  end
end
