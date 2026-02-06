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

    def thread
      topic = Topic.find_by(id: params[:id])
      raise Discourse::NotFound unless topic

      guardian.ensure_can_see!(topic)

      post_number = params[:post_number]&.to_i
      raise Discourse::NotFound unless post_number

      # Find the specific post
      post = topic.posts.secured(guardian).find_by(post_number: post_number)
      raise Discourse::NotFound unless post

      # Find the root parent of this post
      root_post = find_root_parent(post, topic)

      # Build tree for just this thread
      tree_data = build_single_thread(root_post, topic, post_number)

      # Create TopicView first with the thread data
      # This ensures the TopicView is properly initialized before we add extra posts
      all_post_ids = []
      tree_data[:nested_posts].each do |node|
        all_post_ids << node[:post].id
        all_post_ids.concat(node[:replies].map(&:id))
      end

      # Always include the OP (post #1) if it's not already the root post
      if root_post.post_number != 1
        op_post = topic.posts.secured(guardian).find_by(post_number: 1)
        if op_post
          # Build OP tree node
          op_replies = collect_all_replies(op_post, topic)
          max_initial_replies = SiteSetting.nested_replies_max_initial_replies
          paginated_op_replies = op_replies.take(max_initial_replies)

          op_node = {
            post: op_post,
            replies: paginated_op_replies,
            total_reply_count: op_replies.size,
            loaded_reply_count: paginated_op_replies.size,
            has_more_replies: op_replies.size > max_initial_replies,
            highlighted: false,
          }

          # Prepend OP to the tree
          tree_data[:nested_posts].unshift(op_node)

          # Add OP post IDs to the TopicView
          all_post_ids.unshift(op_post.id)
          all_post_ids.concat(paginated_op_replies.map(&:id))

          # Update metadata
          tree_data[:meta][:total_top_level_posts] = 2
          tree_data[:meta][:total_posts] = 1 + op_replies.size + tree_data[:meta][:total_posts]
        end
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

    def find_root_parent(post, topic)
      current = post
      visited = Set.new

      while current.reply_to_post_number && !visited.include?(current.id)
        visited.add(current.id)
        parent = topic.posts.secured(guardian).find_by(post_number: current.reply_to_post_number)
        break unless parent
        current = parent
      end

      current
    end

    def build_single_thread(root_post, topic, highlight_post_number)
      # Collect all replies to this root post (recursively)
      all_replies = collect_all_replies(root_post, topic)

      # Apply pagination
      max_initial_replies = SiteSetting.nested_replies_max_initial_replies
      paginated_replies = all_replies.take(max_initial_replies)
      has_more = all_replies.size > max_initial_replies

      # Build the tree structure (single node)
      tree = [
        {
          post: root_post,
          replies: paginated_replies,
          total_reply_count: all_replies.size,
          loaded_reply_count: paginated_replies.size,
          has_more_replies: has_more,
          highlighted:
            root_post.post_number == highlight_post_number ||
              paginated_replies.any? { |r| r.post_number == highlight_post_number },
        },
      ]

      # Build metadata
      meta = {
        page: 1,
        per_page: max_initial_replies,
        total_top_level_posts: 1, # Only showing one thread
        total_posts: 1 + all_replies.size,
        total_pages: 1, # Thread view doesn't paginate top-level
        has_next_page: false,
        has_previous_page: false,
        thread_view: true, # Flag to indicate this is a thread view
        root_post_number: root_post.post_number,
        highlight_post_number: highlight_post_number,
      }

      { nested_posts: tree, meta: meta }
    end

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
