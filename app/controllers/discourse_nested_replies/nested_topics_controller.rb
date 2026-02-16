# frozen_string_literal: true

module ::DiscourseNestedReplies
  class NestedTopicsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_nested_replies_enabled
    before_action :find_topic, except: [:respond]

    # Serves the Ember app shell for hard refreshes on /nested/:slug/:topic_id
    def respond
      render
    end

    PRELOAD_DEPTH = 3
    MAX_DEPTH_CEILING = 10
    ROOTS_PER_PAGE = 20
    CHILDREN_PER_PAGE = 50
    PRELOAD_CHILDREN_PER_PARENT = 3

    POST_INCLUDES = [
      { user: %i[primary_group flair_group] },
      :reply_to_user,
      :deleted_by,
      :incoming_email,
      :image_upload,
    ].freeze

    # GET /nested/:slug/:topic_id/roots
    # On page 0 (initial load), includes topic metadata, OP post, sort, and message_bus_last_id.
    # On subsequent pages, returns only roots for pagination.
    def roots
      sort = validated_sort
      page = [params[:page].to_i, 0].max
      initial_load = page == 0

      roots = root_posts_scope(sort).offset(page * ROOTS_PER_PAGE).limit(ROOTS_PER_PAGE)
      roots = load_posts_for_tree(roots).to_a

      tree_data = batch_preload_tree(roots, sort, max_depth: PRELOAD_DEPTH)
      children_map = tree_data[:children_map]

      all_posts = initial_load ? [op_post] + tree_data[:all_posts] : tree_data[:all_posts].dup

      prepare_for_serialization(all_posts)
      post_numbers = all_posts.map(&:post_number)
      reply_counts = direct_reply_counts(post_numbers)
      descendant_counts = total_descendant_counts(all_posts.map(&:id))

      result = {
        roots:
          roots.map { |root| serialize_tree(root, children_map, reply_counts, descendant_counts) },
        has_more_roots: roots.size == ROOTS_PER_PAGE,
        page: page,
      }

      if initial_load
        result[:topic] = serialize_topic
        result[:op_post] = serialize_post(op_post, reply_counts, descendant_counts)
        result[:sort] = sort
        result[:message_bus_last_id] = @topic_view.message_bus_last_id
      end

      render json: result
    end

    # GET /nested/:slug/:topic_id/children/:post_number
    def children
      parent_post_number = params[:post_number].to_i
      sort = validated_sort
      page = [params[:page].to_i, 0].max
      depth = [params[:depth].to_i, 1].max

      flatten = SiteSetting.nested_replies_cap_nesting_depth && depth >= configured_max_depth

      children_scope =
        if flatten
          flat_descendants_scope(parent_post_number)
        else
          @topic.posts.where(reply_to_post_number: parent_post_number).where(post_number: 2..)
        end
      children_scope = apply_visibility(children_scope)

      if depth >= configured_max_depth
        children_scope = DiscourseNestedReplies::Sort.apply(children_scope, "old", last_level: true)
      else
        children_scope = DiscourseNestedReplies::Sort.apply(children_scope, sort)
      end

      children_scope = children_scope.offset(page * CHILDREN_PER_PAGE).limit(CHILDREN_PER_PAGE)
      children_posts = load_posts_for_tree(children_scope).to_a

      if flatten
        # Flattened descendants are leaf nodes — no tree preloading
        all_posts = children_posts
        children_map = {}
      else
        remaining_depth =
          depth < configured_max_depth ? [PRELOAD_DEPTH, configured_max_depth - depth].min : 0
        tree_data = batch_preload_tree(children_posts, sort, max_depth: remaining_depth)
        children_map = tree_data[:children_map]
        all_posts = tree_data[:all_posts]
      end

      prepare_for_serialization(all_posts)
      reply_counts = direct_reply_counts(all_posts.map(&:post_number))
      descendant_counts = total_descendant_counts(all_posts.map(&:id))

      render json: {
               children:
                 children_posts.map { |child|
                   if flatten
                     serialize_post(child, reply_counts, descendant_counts).merge(children: [])
                   else
                     serialize_tree(child, children_map, reply_counts, descendant_counts)
                   end
                 },
               has_more: children_posts.size == CHILDREN_PER_PAGE,
               page: page,
             }
    end

    # GET /nested/:slug/:topic_id/context/:post_number
    # Optional param: context (integer) — controls ancestor depth.
    #   nil/absent = full ancestor chain (deep-links, notifications)
    #   0 = no ancestors, target at depth 0 ("Continue this thread")
    def context
      target_post_number = params[:post_number].to_i
      sort = validated_sort
      context_depth = params[:context]&.to_i # nil = full chain, 0 = no ancestors

      target = @topic.posts.find_by(post_number: target_post_number)
      raise Discourse::NotFound unless target

      ancestors = []
      unless context_depth == 0
        # Walk up the ancestor chain, optionally limited to context_depth levels
        current = target
        while current.reply_to_post_number.present? && current.reply_to_post_number != 1
          break if context_depth && ancestors.length >= context_depth
          parent = @topic.posts.find_by(post_number: current.reply_to_post_number)
          break unless parent
          ancestors.unshift(parent)
          current = parent
        end
      end

      # Skip siblings query when context=0
      siblings_map = {}
      unless context_depth == 0
        ancestors.each do |ancestor|
          parent_number = ancestor.reply_to_post_number || nil
          sibling_scope =
            if parent_number
              @topic.posts.where(reply_to_post_number: parent_number)
            else
              root_posts_scope(sort)
            end

          sibling_scope = apply_visibility(sibling_scope)
          sibling_scope = DiscourseNestedReplies::Sort.apply(sibling_scope, sort)
          siblings = load_posts_for_tree(sibling_scope.limit(5)).to_a
          siblings_map[ancestor.post_number] = siblings
        end
      end

      # Batch-load target's children
      tree_data = batch_preload_tree([target], sort, max_depth: PRELOAD_DEPTH)
      children_map = tree_data[:children_map]

      all_posts =
        [op_post, target] + ancestors + siblings_map.values.flatten + tree_data[:all_posts]
      all_posts.uniq!(&:id)

      prepare_for_serialization(all_posts)
      reply_counts = direct_reply_counts(all_posts.map(&:post_number))
      descendant_counts = total_descendant_counts(all_posts.map(&:id))

      render json: {
               topic: serialize_topic,
               op_post: serialize_post(op_post, reply_counts, descendant_counts),
               ancestor_chain:
                 ancestors.map { |a| serialize_post(a, reply_counts, descendant_counts) },
               siblings:
                 siblings_map.transform_values { |posts|
                   posts.map { |p| serialize_post(p, reply_counts, descendant_counts) }
                 },
               target_post: serialize_tree(target, children_map, reply_counts, descendant_counts),
               message_bus_last_id: @topic_view.message_bus_last_id,
             }
    end

    private

    def ensure_nested_replies_enabled
      raise Discourse::NotFound unless SiteSetting.nested_replies_enabled
    end

    def find_topic
      topic_id = params[:topic_id].to_i
      @topic_view =
        TopicView.new(topic_id, current_user, skip_custom_fields: true, skip_post_loading: true)
      @topic = @topic_view.topic
    rescue Discourse::InvalidAccess, Discourse::NotFound => e
      raise e
    end

    def op_post
      @op_post ||=
        begin
          scope = @topic.posts.where(post_number: 1)
          load_posts_for_tree(scope).first
        end
    end

    def root_posts_scope(sort)
      scope =
        @topic
          .posts
          .where("reply_to_post_number IS NULL OR reply_to_post_number = 1")
          .where(post_number: 2..) # exclude OP itself
      scope = apply_visibility(scope)
      DiscourseNestedReplies::Sort.apply(scope, sort)
    end

    def apply_visibility(scope)
      scope = scope.where(deleted_at: nil) unless guardian.can_see_deleted_posts?(@topic.category)
      scope = scope.where(post_type: [Post.types[:regular], Post.types[:moderator_action]])
      scope
    end

    def load_posts_for_tree(scope)
      scope = scope.includes(*POST_INCLUDES)
      scope = scope.includes(:localizations) if SiteSetting.content_localization_enabled
      scope = scope.includes({ user: :user_status }) if SiteSetting.enable_user_status
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

        scope = @topic.posts.where(reply_to_post_number: parent_numbers).where(post_number: 2..)
        scope = apply_visibility(scope)
        scope = DiscourseNestedReplies::Sort.apply(scope, sort, last_level: last_level)
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

    # Set our posts on the topic_view so its lazy-loaded batch methods
    # (all_post_actions, reviewable_counts, bookmarks, mentioned_users, etc.)
    # operate on the correct set of posts. Also clears stale caches and
    # runs plugin preload hooks.
    def prepare_for_serialization(posts)
      post_ids = posts.map(&:id).uniq
      user_ids = posts.map(&:user_id).compact.uniq

      # Wrap in PreloadablePostsArray so on_preload hooks that call
      # .includes() or .pluck() work transparently with our loaded posts.
      @topic_view.posts = PreloadablePostsArray.new(posts)

      # Load custom fields
      allowed_post_fields = TopicView.allowed_post_custom_fields(current_user, @topic)
      @topic_view.post_custom_fields =
        if allowed_post_fields.present?
          Post.custom_fields_for_ids(post_ids, allowed_post_fields)
        else
          {}
        end

      allowed_user_fields = User.allowed_user_custom_fields(guardian)
      @topic_view.user_custom_fields =
        if allowed_user_fields.present?
          User.custom_fields_for_ids(user_ids, allowed_user_fields)
        else
          {}
        end

      # Run plugin preload hooks (our own direct_reply_counts hook, etc.)
      TopicView.preload(@topic_view)

      # Preload associations that plugins access during serialization
      preload_plugin_associations(posts)
    end

    # Batch-preload associations that plugin serializer extensions access per-post.
    # Without this, each PostSerializer#as_json call triggers N+1 queries.
    def preload_plugin_associations(posts)
      ActiveRecord::Associations::Preloader.new(records: posts, associations: [:post_actions]).call

      if defined?(DiscourseReactions) && SiteSetting.respond_to?(:discourse_reactions_enabled) &&
           SiteSetting.discourse_reactions_enabled
        ActiveRecord::Associations::Preloader.new(
          records: posts,
          associations: [{ reactions: { reaction_users: :user } }],
        ).call

        post_ids = posts.map(&:id).uniq
        if TopicViewSerializer.respond_to?(:posts_reaction_users_count)
          counts = TopicViewSerializer.posts_reaction_users_count(post_ids)
          action_users =
            DiscourseReactions::TopicViewSerializerExtension.load_post_action_reaction_users_for_posts(
              post_ids,
            )
          posts.each do |post|
            post.reaction_users_count = counts[post.id].to_i
            post.post_actions_with_reaction_users = action_users[post.id] || {}
          end
        end

        batch_precompute_reactions(posts, post_ids)
      end
    end

    # Batch-compute the full reactions_for_post result for all posts in 1 SQL query.
    # This replicates ReactionsSerializerHelpers.reactions_for_post but avoids the
    # per-post COUNT query that causes N+1.
    def batch_precompute_reactions(posts, post_ids)
      main_reaction = DiscourseReactions::Reaction.main_reaction_id
      excluded = DiscourseReactions::Reaction.reactions_excluded_from_like

      # Single batch query: adjusted likes count per post.
      # Excludes likes where the user also has a non-excluded/non-main reaction
      # or a main_reaction ReactionUser (mirroring reactions_for_post logic).
      excluded_filter =
        if excluded.present?
          "AND dr.reaction_value NOT IN (:excluded)"
        else
          ""
        end

      sql_params = {
        post_ids: post_ids,
        like_type: PostActionType::LIKE_POST_ACTION_ID,
        main_reaction: main_reaction,
      }
      sql_params[:excluded] = excluded if excluded.present?

      rows = DB.query(<<~SQL, **sql_params)
          SELECT pa.post_id, COUNT(*) as likes_count
          FROM post_actions pa
          WHERE pa.deleted_at IS NULL
            AND pa.post_id IN (:post_ids)
            AND pa.post_action_type_id = :like_type
            AND NOT EXISTS (
              SELECT 1 FROM discourse_reactions_reaction_users dru
              JOIN discourse_reactions_reactions dr ON dr.id = dru.reaction_id
              WHERE dru.post_id = pa.post_id
                AND dru.user_id = pa.user_id
                AND dr.reaction_value != :main_reaction
                #{excluded_filter}
            )
            AND NOT EXISTS (
              SELECT 1 FROM discourse_reactions_reaction_users dru
              JOIN discourse_reactions_reactions dr ON dr.id = dru.reaction_id
              WHERE dru.post_id = pa.post_id
                AND dru.user_id = pa.user_id
                AND dr.reaction_value = :main_reaction
            )
          GROUP BY pa.post_id
        SQL

      likes_map = rows.each_with_object({}) { |row, h| h[row.post_id] = row.likes_count }

      posts.each do |post|
        emoji_reactions = post.emoji_reactions.select { |r| r.reaction_users_count.to_i > 0 }

        reactions =
          emoji_reactions.map do |reaction|
            {
              id: reaction.reaction_value,
              type: reaction.reaction_type.to_sym,
              count: reaction.reaction_users_count,
            }
          end

        likes = likes_map[post.id] || 0

        if likes > 0
          reaction_likes, reactions = reactions.partition { |r| r[:id] == main_reaction }
          reactions << {
            id: main_reaction,
            type: :emoji,
            count: likes + reaction_likes.sum { |r| r[:count] },
          }
        end

        post.precomputed_reactions = reactions.sort_by { |r| [-r[:count].to_i, r[:id]] }
      end
    end

    def direct_reply_counts(post_numbers)
      return {} if post_numbers.empty?

      Post
        .where(topic_id: @topic.id, deleted_at: nil)
        .where(reply_to_post_number: post_numbers)
        .group(:reply_to_post_number)
        .count
    end

    # Batch-load total descendant counts from the stats table.
    # Returns { post_id => count } keyed by post ID (not post_number).
    def total_descendant_counts(post_ids)
      return {} if post_ids.empty?

      NestedViewPostStat.where(post_id: post_ids.uniq).pluck(:post_id, :total_descendant_count).to_h
    end

    # Recursive CTE: collects ALL descendants of a parent post (children,
    # grandchildren, etc.) and returns them as a flat scope. Used when
    # cap_nesting_depth is ON to flatten deep legacy threads at the last level.
    def flat_descendants_scope(parent_post_number)
      descendant_post_numbers =
        DB.query_single(<<~SQL, topic_id: @topic.id, parent_number: parent_post_number)
          WITH RECURSIVE descendants AS (
            SELECT post_number
            FROM posts
            WHERE topic_id = :topic_id
              AND reply_to_post_number = :parent_number
              AND post_number > 1
              AND deleted_at IS NULL
            UNION ALL
            SELECT p.post_number
            FROM posts p
            JOIN descendants d ON p.reply_to_post_number = d.post_number
            WHERE p.topic_id = :topic_id
              AND p.post_number > 1
              AND p.deleted_at IS NULL
          )
          SELECT post_number FROM descendants
        SQL

      @topic.posts.where(post_number: descendant_post_numbers).where(post_number: 2..)
    end

    def configured_max_depth
      SiteSetting.nested_replies_max_depth
    end

    def validated_sort
      sort = params[:sort].to_s.downcase
      DiscourseNestedReplies::Sort.valid?(sort) ? sort : SiteSetting.nested_replies_default_sort
    end

    def serialize_topic
      serializer = TopicViewSerializer.new(@topic_view, scope: guardian, root: false)
      json = serializer.as_json
      json.except(:post_stream, :timeline_lookup, :user_badges)
    end

    def serialize_post(post, reply_counts, descendant_counts = {})
      post.topic = @topic
      serializer = PostSerializer.new(post, scope: guardian, root: false)
      serializer.topic_view = @topic_view
      json = serializer.as_json
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
