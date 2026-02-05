# frozen_string_literal: true

module DiscourseNestedReplies
  class TreeBuilder
    DEFAULT_CHUNK_SIZE = 20
    VALID_SORTS = %w[chronological new best].freeze

    attr_reader :topic, :guardian, :page, :chunk_size, :sort

    def initialize(topic, guardian, opts = {})
      @topic = topic
      @guardian = guardian
      @page = [opts[:page].to_i, 1].max
      @chunk_size = opts[:chunk_size] || DEFAULT_CHUNK_SIZE
      @post_number = opts[:post_number]&.to_i # For linking to specific posts
      @sort = VALID_SORTS.include?(opts[:sort]) ? opts[:sort] : "chronological"
    end

    def build
      # Load all posts for current page plus their children
      posts = load_posts

      # Build tree structure
      tree = build_tree_structure(posts)

      # Build complete stream of all post IDs in nested order
      stream = build_complete_stream

      { nested_posts: tree, meta: build_metadata, stream: stream }
    end

    private

    def load_posts
      # For sorting, we need to load all top-level posts, sort them, then paginate
      # This ensures we get the true top posts across the entire topic
      all_top_level_posts =
        @topic.posts.secured(@guardian).where("reply_to_post_number IS NULL").to_a

      # Sort based on the chosen method
      sorted_top_level = sort_top_level_posts(all_top_level_posts)

      # Apply pagination
      offset = (@page - 1) * @chunk_size
      top_level_posts = sorted_top_level[offset, @chunk_size] || []

      top_level_post_numbers = top_level_posts.map(&:post_number)

      # If linking to specific post, ensure it's included
      if @post_number && !top_level_post_numbers.include?(@post_number)
        linked_post = @topic.posts.secured(@guardian).find_by(post_number: @post_number)
        if linked_post
          # Find its root parent
          root = find_root_parent(linked_post)
          if root && !top_level_post_numbers.include?(root.post_number)
            top_level_posts.unshift(root)
            top_level_post_numbers.unshift(root.post_number)
          end
        end
      end

      return top_level_posts if top_level_posts.empty?

      # Fetch all descendants (flattened) for visible top-level posts
      child_posts =
        @topic
          .posts
          .secured(@guardian)
          .where("reply_to_post_number IN (?)", top_level_post_numbers)
          .order(:created_at)
          .to_a

      # Recursively fetch descendants of descendants
      all_child_ids = child_posts.map(&:post_number)
      loop do
        break if all_child_ids.empty?

        grandchildren =
          @topic
            .posts
            .secured(@guardian)
            .where("reply_to_post_number IN (?)", all_child_ids)
            .where.not(post_number: (top_level_post_numbers + child_posts.map(&:post_number)))
            .order(:created_at)
            .to_a

        break if grandchildren.empty?

        child_posts.concat(grandchildren)
        all_child_ids = grandchildren.map(&:post_number)
      end

      # Combine and return
      (top_level_posts + child_posts).uniq
    end

    def build_tree_structure(all_posts)
      # Separate top-level from replies
      posts_by_parent = all_posts.group_by(&:reply_to_post_number)
      top_level = posts_by_parent[nil] || []

      # Build tree nodes for top-level posts in this page
      max_initial_replies = SiteSetting.nested_replies_max_initial_replies

      top_level.map do |post|
        replies = collect_flattened_replies(post, posts_by_parent)

        {
          post: post,
          replies: replies.take(max_initial_replies),
          total_reply_count: replies.count,
          loaded_reply_count: [replies.count, max_initial_replies].min,
          has_more_replies: replies.count > max_initial_replies,
          highlighted:
            @post_number &&
              (
                post.post_number == @post_number ||
                  replies.any? { |r| r.post_number == @post_number }
              ),
        }
      end
    end

    def collect_flattened_replies(parent_post, posts_by_parent, collected = [], visited = Set.new)
      # Prevent infinite loops
      return collected if visited.include?(parent_post.id)
      visited.add(parent_post.id)

      # Find direct children
      direct_children = posts_by_parent[parent_post.post_number] || []

      # Add them and recurse to get grandchildren
      direct_children.each do |child|
        collected << child
        collect_flattened_replies(child, posts_by_parent, collected, visited)
      end

      # Sort by creation time to maintain chronological flow within thread
      collected.sort_by(&:created_at)
    end

    def build_metadata
      top_level_count = @topic.posts.secured(@guardian).where("reply_to_post_number IS NULL").count
      total_posts = @topic.posts.secured(@guardian).count

      {
        page: @page,
        per_page: @chunk_size,
        total_top_level_posts: top_level_count,
        total_posts: total_posts,
        total_pages: (top_level_count.to_f / @chunk_size).ceil,
        has_next_page: @page * @chunk_size < top_level_count,
        has_previous_page: @page > 1,
      }
    end

    def find_root_parent(post)
      current = post
      visited = Set.new

      while current.reply_to_post_number && !visited.include?(current.id)
        visited.add(current.id)
        parent = @topic.posts.find_by(post_number: current.reply_to_post_number)
        break unless parent
        current = parent
      end

      current
    end

    def build_complete_stream
      # Load ALL posts in the topic to build the complete stream
      all_posts = @topic.posts.secured(@guardian).order(:post_number).to_a

      # Separate top-level from replies
      posts_by_parent = all_posts.group_by(&:reply_to_post_number)
      top_level = posts_by_parent[nil] || []

      # Build stream in nested order: each top-level post followed by all its descendants
      stream = []
      top_level.each do |post|
        stream << post.id
        collect_descendant_ids(post, posts_by_parent, stream)
      end

      stream
    end

    def collect_descendant_ids(parent_post, posts_by_parent, stream, visited = Set.new)
      return if visited.include?(parent_post.id)
      visited.add(parent_post.id)

      children = posts_by_parent[parent_post.post_number] || []
      children
        .sort_by(&:created_at)
        .each do |child|
          stream << child.id
          collect_descendant_ids(child, posts_by_parent, stream, visited)
        end
    end

    def sort_top_level_posts(posts)
      case @sort
      when "new"
        posts.sort_by(&:created_at).reverse
      when "best"
        posts.sort_by(&:like_count).reverse
      else # chronological
        posts.sort_by(&:post_number)
      end
    end
  end
end
