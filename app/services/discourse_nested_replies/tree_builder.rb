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
      @chunk_size = opts[:chunk_size] || SiteSetting.nested_replies_posts_per_page
      @post_number = opts[:post_number]&.to_i
      @sort = VALID_SORTS.include?(opts[:sort]) ? opts[:sort] : "chronological"
    end

    def build
      posts = load_posts
      tree = build_tree_structure(posts)
      stream = build_complete_stream

      { nested_posts: tree, meta: build_metadata, stream: stream }
    end

    def build_thread(post_number, highlight_post_number: nil)
      highlight_post_number ||= post_number

      post = secured_posts.find_by(post_number: post_number)
      raise Discourse::NotFound unless post

      root_post = find_root_parent(post)
      tree_data = build_single_thread(root_post, highlight_post_number)

      prepend_op_to_thread(tree_data, root_post) if root_post.post_number != 1

      tree_data
    end

    def collect_all_replies(parent_post, collected = [], visited = Set.new)
      return collected if visited.include?(parent_post.id)
      visited.add(parent_post.id)

      direct_children =
        secured_posts
          .where(reply_to_post_number: parent_post.post_number)
          .order(:created_at)
          .to_a

      direct_children.each do |child|
        collected << child
        collect_all_replies(child, collected, visited)
      end

      collected
    end

    def self.collect_post_ids(tree_data)
      post_ids = []
      tree_data[:nested_posts].each do |node|
        post_ids << node[:post].id
        post_ids.concat(node[:replies].map(&:id))
      end
      post_ids.uniq
    end

    private

    def secured_posts
      @topic.posts.secured(@guardian)
    end

    def load_posts
      all_top_level_posts = secured_posts.where("reply_to_post_number IS NULL").to_a

      op_post = all_top_level_posts.find { |p| p.post_number == 1 }
      sorted_top_level = sort_top_level_posts(all_top_level_posts)

      offset = (@page - 1) * @chunk_size
      top_level_posts = sorted_top_level[offset, @chunk_size] || []

      if op_post
        top_level_posts.delete(op_post)
        top_level_posts.unshift(op_post)
      end

      top_level_post_numbers = top_level_posts.map(&:post_number)

      if @post_number && !top_level_post_numbers.include?(@post_number)
        linked_post = secured_posts.find_by(post_number: @post_number)
        if linked_post
          root = find_root_parent(linked_post)
          if root && !top_level_post_numbers.include?(root.post_number)
            top_level_posts.unshift(root)
            top_level_post_numbers.unshift(root.post_number)
          end
        end
      end

      return top_level_posts if top_level_posts.empty?

      child_posts =
        secured_posts
          .where("reply_to_post_number IN (?)", top_level_post_numbers)
          .order(:created_at)
          .to_a

      all_child_ids = child_posts.map(&:post_number)
      loop do
        break if all_child_ids.empty?

        grandchildren =
          secured_posts
            .where("reply_to_post_number IN (?)", all_child_ids)
            .where.not(post_number: (top_level_post_numbers + child_posts.map(&:post_number)))
            .order(:created_at)
            .to_a

        break if grandchildren.empty?

        child_posts.concat(grandchildren)
        all_child_ids = grandchildren.map(&:post_number)
      end

      (top_level_posts + child_posts).uniq
    end

    def build_tree_structure(all_posts)
      posts_by_parent = all_posts.group_by(&:reply_to_post_number)
      top_level = posts_by_parent[nil] || []

      top_level.map { |post| build_node(post, posts_by_parent) }
    end

    def build_node(post, posts_by_parent)
      replies = collect_flattened_replies(post, posts_by_parent)
      max_initial_replies = SiteSetting.nested_replies_max_initial_replies

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

    def collect_flattened_replies(parent_post, posts_by_parent, collected = [], visited = Set.new)
      return collected if visited.include?(parent_post.id)
      visited.add(parent_post.id)

      direct_children = posts_by_parent[parent_post.post_number] || []
      direct_children.each do |child|
        collected << child
        collect_flattened_replies(child, posts_by_parent, collected, visited)
      end

      collected.sort_by(&:created_at)
    end

    def build_metadata
      top_level_count = secured_posts.where("reply_to_post_number IS NULL").count
      total_posts = secured_posts.count

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
        parent = secured_posts.find_by(post_number: current.reply_to_post_number)
        break unless parent
        current = parent
      end

      current
    end

    def build_single_thread(root_post, highlight_post_number)
      all_replies = collect_all_replies(root_post)
      max_initial_replies = SiteSetting.nested_replies_max_initial_replies
      paginated_replies = all_replies.take(max_initial_replies)

      tree = [
        {
          post: root_post,
          replies: paginated_replies,
          total_reply_count: all_replies.size,
          loaded_reply_count: paginated_replies.size,
          has_more_replies: all_replies.size > max_initial_replies,
          highlighted:
            root_post.post_number == highlight_post_number ||
              paginated_replies.any? { |r| r.post_number == highlight_post_number },
        },
      ]

      meta = {
        page: 1,
        per_page: max_initial_replies,
        total_top_level_posts: 1,
        total_posts: 1 + all_replies.size,
        total_pages: 1,
        has_next_page: false,
        has_previous_page: false,
        thread_view: true,
        root_post_number: root_post.post_number,
        highlight_post_number: highlight_post_number,
      }

      { nested_posts: tree, meta: meta }
    end

    def prepend_op_to_thread(tree_data, root_post)
      op_post = secured_posts.find_by(post_number: 1)
      return unless op_post

      op_replies = collect_all_replies(op_post)
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

      tree_data[:nested_posts].unshift(op_node)
      tree_data[:meta][:total_top_level_posts] = 2
      tree_data[:meta][:total_posts] = 1 + op_replies.size + tree_data[:meta][:total_posts]
    end

    def build_complete_stream
      all_posts = secured_posts.order(:post_number).to_a
      posts_by_parent = all_posts.group_by(&:reply_to_post_number)
      top_level = posts_by_parent[nil] || []

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
      else
        posts.sort_by(&:post_number)
      end
    end
  end
end
