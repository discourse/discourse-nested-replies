# frozen_string_literal: true

module ::DiscourseNestedReplies
  class TreeLoader
    PRELOAD_DEPTH = 3
    ROOTS_PER_PAGE = 20
    CHILDREN_PER_PAGE = 50
    PRELOAD_CHILDREN_PER_PARENT = 3
    SIBLINGS_PER_ANCESTOR = 5

    POST_INCLUDES = [
      { user: %i[primary_group flair_group] },
      :reply_to_user,
      :deleted_by,
      :incoming_email,
      :image_upload,
    ].freeze

    attr_reader :topic, :guardian

    def initialize(topic:, guardian:)
      @topic = topic
      @guardian = guardian
    end

    def visible_post_types
      types = [Post.types[:regular], Post.types[:moderator_action]]
      types << Post.types[:whisper] if guardian.user&.whisperer?
      types
    end

    def op_post
      @op_post ||= load_posts_for_tree(topic.posts.where(post_number: 1)).first
    end

    def root_posts_scope(sort)
      scope =
        topic
          .posts
          .where("reply_to_post_number IS NULL OR reply_to_post_number = 1")
          .where(post_number: 2..) # exclude OP itself
      scope = apply_visibility(scope)
      DiscourseNestedReplies::Sort.apply(scope, sort)
    end

    def load_posts_for_tree(scope)
      scope = scope.includes(*POST_INCLUDES)
      scope = scope.includes(:localizations) if SiteSetting.content_localization_enabled
      scope = scope.includes({ user: :user_status }) if SiteSetting.enable_user_status
      scope
    end

    def apply_visibility(scope)
      scope = scope.unscope(where: :deleted_at)
      scope = scope.where(post_type: visible_post_types)
      scope
    end

    # Breadth-first batch loader: one query per depth level instead of one per post.
    # Returns { children_map: { post_number => [child_posts] }, all_posts: [all loaded posts] }
    def batch_preload_tree(starting_posts, sort, max_depth:)
      all_posts = starting_posts.dup
      children_map = {}

      current_level = starting_posts
      max_depth.times do |depth|
        break if current_level.empty?

        parent_numbers = current_level.map(&:post_number)
        last_level = (depth + 1 >= max_depth) || (depth + 1 >= configured_max_depth)

        scope = topic.posts.where(reply_to_post_number: parent_numbers).where(post_number: 2..)
        scope = apply_visibility(scope)
        scope = DiscourseNestedReplies::Sort.apply(scope, sort)
        all_children = load_posts_for_tree(scope).to_a

        next_level = []
        all_children
          .group_by(&:reply_to_post_number)
          .each do |parent_number, child_posts|
            limited = child_posts.first(PRELOAD_CHILDREN_PER_PARENT)
            children_map[parent_number] = limited
            all_posts.concat(limited)
            next_level.concat(limited) unless last_level
          end

        current_level = next_level
      end

      { children_map: children_map, all_posts: all_posts }
    end

    # Batch-load siblings for all ancestors in ONE query using a window function,
    # instead of issuing a separate query per ancestor (N+1).
    # Returns { ancestor_post_number => [sibling_posts] }.
    def batch_load_siblings(ancestors, sort)
      # Partition ancestors into root-level (no parent) and non-root (has parent)
      root_ancestors, child_ancestors = ancestors.partition { |a| a.reply_to_post_number.nil? }

      siblings_map = {}

      # Handle non-root ancestors: batch query with window function
      if child_ancestors.present?
        parent_numbers = child_ancestors.map(&:reply_to_post_number).uniq

        order_expr = DiscourseNestedReplies::Sort.sql_order_expression(sort)

        visibility_conditions = +"post_type IN (:post_types) AND post_number > 1"
        sql_params = {
          topic_id: topic.id,
          parent_numbers: parent_numbers,
          limit: SIBLINGS_PER_ANCESTOR,
          post_types: visible_post_types,
        }

        sibling_ids = DB.query_single(<<~SQL, **sql_params)
            SELECT id FROM (
              SELECT id, reply_to_post_number,
                     ROW_NUMBER() OVER (PARTITION BY reply_to_post_number ORDER BY #{order_expr}) AS rn
              FROM posts
              WHERE topic_id = :topic_id
                AND reply_to_post_number IN (:parent_numbers)
                AND #{visibility_conditions}
            ) ranked
            WHERE rn <= :limit
          SQL

        if sibling_ids.present?
          loaded_siblings =
            load_posts_for_tree(topic.posts.with_deleted.where(id: sibling_ids)).to_a
          grouped = loaded_siblings.group_by(&:reply_to_post_number)

          # Re-sort in memory: load_posts_for_tree re-queries by ID without
          # preserving the window function's ORDER BY, so we restore sort here.
          grouped.transform_values! do |posts|
            DiscourseNestedReplies::Sort.sort_in_memory(posts, sort)
          end

          # Map back: each ancestor gets the siblings for its parent_number
          child_ancestors.each do |ancestor|
            siblings_map[ancestor.post_number] = grouped[ancestor.reply_to_post_number] || []
          end
        end
      end

      # Handle root-level ancestors: they share the same scope (root_posts_scope)
      if root_ancestors.present?
        root_siblings =
          load_posts_for_tree(root_posts_scope(sort).limit(SIBLINGS_PER_ANCESTOR)).to_a
        root_ancestors.each { |ancestor| siblings_map[ancestor.post_number] = root_siblings }
      end

      siblings_map
    end

    # Recursive CTE: collects ALL descendants of a parent post (children,
    # grandchildren, etc.) and returns them as a flat scope. Used when
    # cap_nesting_depth is ON to flatten deep legacy threads at the last level.
    def flat_descendants_scope(parent_post_number, sort:, offset: 0, limit: CHILDREN_PER_PAGE)
      post_types = visible_post_types
      order_expr = DiscourseNestedReplies::Sort.sql_order_expression(sort)

      descendant_post_numbers =
        DB.query_single(
          <<~SQL,
          WITH RECURSIVE descendants AS (
            SELECT post_number
            FROM posts
            WHERE topic_id = :topic_id
              AND reply_to_post_number = :parent_number
              AND post_number > 1
            UNION ALL
            SELECT p.post_number
            FROM posts p
            JOIN descendants d ON p.reply_to_post_number = d.post_number
            WHERE p.topic_id = :topic_id
              AND p.post_number > 1
          )
          SELECT d.post_number
          FROM descendants d
          JOIN posts p ON p.post_number = d.post_number AND p.topic_id = :topic_id
          WHERE p.post_type IN (:post_types)
          ORDER BY #{order_expr}
          OFFSET :offset
          LIMIT :limit
        SQL
          topic_id: topic.id,
          parent_number: parent_post_number,
          post_types: post_types,
          offset: offset,
          limit: limit,
        )

      scope =
        topic.posts.with_deleted.where(post_number: descendant_post_numbers).where(post_number: 2..)
      DiscourseNestedReplies::Sort.apply(scope, sort)
    end

    def configured_max_depth
      SiteSetting.nested_replies_max_depth
    end

    def direct_reply_counts(post_numbers)
      return {} if post_numbers.empty?

      Post
        .with_deleted
        .where(topic_id: topic.id)
        .where(reply_to_post_number: post_numbers)
        .where(post_type: visible_post_types)
        .group(:reply_to_post_number)
        .count
    end

    # Batch-load total descendant counts from the stats table.
    # Returns { post_id => count } keyed by post ID (not post_number).
    # For non-staff, subtracts whisper counts to avoid leaking whisper existence.
    def total_descendant_counts(post_ids)
      return {} if post_ids.empty?

      if guardian.user&.whisperer?
        NestedViewPostStat
          .where(post_id: post_ids.uniq)
          .pluck(:post_id, :total_descendant_count)
          .to_h
      else
        NestedViewPostStat
          .where(post_id: post_ids.uniq)
          .pluck(:post_id, Arel.sql("total_descendant_count - whisper_total_descendant_count"))
          .to_h
      end
    end
  end
end
