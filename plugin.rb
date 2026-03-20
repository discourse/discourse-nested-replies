# frozen_string_literal: true

# name: discourse-nested-replies
# about: Reddit-style nested/threaded view for Discourse topics
# version: 0.1.1
# authors: Discourse
# url: https://github.com/discourse/discourse-nested-replies
# required_version: 2.7.0

enabled_site_setting :nested_replies_enabled
register_asset "stylesheets/common/nested-view.scss"
register_svg_icon "nested-circle-plus"
register_svg_icon "nested-circle-minus"
register_svg_icon "nested-thread"

module ::DiscourseNestedReplies
  PLUGIN_NAME = "discourse-nested-replies"
  CATEGORY_DEFAULT_FIELD = "nested_replies_default_for_category"
  PINNED_POST_NUMBER_FIELD = "nested_replies_pinned_post_number"
end

require_relative "lib/discourse_nested_replies/engine"
require_relative "lib/discourse_nested_replies/ancestor_walker"
require_relative "lib/discourse_nested_replies/tree_loader"
require_relative "lib/discourse_nested_replies/post_preloader"
require_relative "lib/discourse_nested_replies/post_tree_serializer"

after_initialize do
  add_to_class(:topic_view, :nested_replies_direct_reply_counts) do
    @nested_replies_direct_reply_counts
  end

  add_to_class(:topic_view, :nested_replies_direct_reply_counts=) do |counts|
    @nested_replies_direct_reply_counts = counts
  end

  add_to_class(:topic_view, :nested_replies_skip_preload) { @nested_replies_skip_preload }

  add_to_class(:topic_view, :nested_replies_skip_preload=) do |val|
    @nested_replies_skip_preload = val
  end

  # --- TopicView.on_preload: make the flat view nested-aware ---
  # After TopicView loads posts for the flat view, batch-load direct reply
  # counts so the flat topic JSON response includes reply count metadata.
  # This powers the "View as nested (N replies)" toggle link.
  TopicView.on_preload do |topic_view|
    next unless SiteSetting.nested_replies_enabled
    next if topic_view.nested_replies_skip_preload

    post_numbers = topic_view.posts.map(&:post_number)
    next if post_numbers.empty?

    counts =
      Post
        .where(topic_id: topic_view.topic.id, deleted_at: nil)
        .where(reply_to_post_number: post_numbers)
        .group(:reply_to_post_number)
        .count

    topic_view.nested_replies_direct_reply_counts = counts
  end

  # --- Serialize direct_reply_count on posts (gated) ---
  # Included when the TopicView.on_preload hook above populated reply counts.
  # Zero overhead on serialization paths where no counts were preloaded.
  add_to_serializer(
    :post,
    :direct_reply_count,
    include_condition: -> { @topic_view&.nested_replies_direct_reply_counts.present? },
  ) do
    counts = @topic_view.nested_replies_direct_reply_counts
    counts[object.post_number] || 0
  end

  # --- Category custom field: nested_replies_default_for_category ---
  register_category_custom_field_type(DiscourseNestedReplies::CATEGORY_DEFAULT_FIELD, :boolean)
  register_preloaded_category_custom_fields(DiscourseNestedReplies::CATEGORY_DEFAULT_FIELD)

  # Serialize the category default on BasicCategorySerializer so the
  # frontend can check it without extra requests.
  add_to_serializer(:basic_category, :nested_replies_default) do
    object.custom_fields[DiscourseNestedReplies::CATEGORY_DEFAULT_FIELD]
  end

  # --- Pinned reply: staff can pin one top-level reply per topic ---
  register_topic_custom_field_type(DiscourseNestedReplies::PINNED_POST_NUMBER_FIELD, :integer)
  register_editable_topic_custom_field(
    DiscourseNestedReplies::PINNED_POST_NUMBER_FIELD,
    staff_only: true,
  )

  # --- Preserve ?post_number through URL canonicalization redirects ---
  register_modifier(:redirect_to_correct_topic_additional_query_parameters) do |params|
    params + %w[post_number]
  end

  # --- Batch reactions precompute support ---
  # ReactionsSerializerHelpers.reactions_for_post fires a per-post COUNT query.
  # To avoid N+1, we batch-precompute the reactions result and store it on
  # post.precomputed_reactions. The prepend below short-circuits the serializer's
  # `reactions` method to use precomputed data.
  #
  # We prepend on PostSerializer (not ReactionsSerializerHelpers) because our
  # plugin loads alphabetically before discourse-reactions, so
  # ReactionsSerializerHelpers doesn't exist yet at boot time. Prepending on
  # PostSerializer works regardless of load order — Ruby's MRO ensures our
  # method is checked first, and `super` resolves at call time.
  add_to_class(:post, :precomputed_reactions) { @precomputed_reactions }
  add_to_class(:post, "precomputed_reactions=") { |val| @precomputed_reactions = val }

  # Batch-compute the full reactions result for all posts in one SQL query.
  # Replicates ReactionsSerializerHelpers.reactions_for_post logic without
  # the per-post COUNT that causes N+1. Expects reactions associations to be
  # preloaded on the posts before calling.
  def DiscourseNestedReplies.batch_precompute_reactions(posts, post_ids)
    main_reaction = DiscourseReactions::Reaction.main_reaction_id
    excluded = DiscourseReactions::Reaction.reactions_excluded_from_like

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

  module ::DiscourseNestedReplies::PostSerializerReactionsPatch
    def reactions
      if SiteSetting.nested_replies_enabled && object.respond_to?(:precomputed_reactions) &&
           (data = object.precomputed_reactions)
        return data
      end
      super
    end
  end
  reloadable_patch { PostSerializer.prepend(DiscourseNestedReplies::PostSerializerReactionsPatch) }

  # --- Stats maintenance callbacks ---
  # Keep nested_view_post_stats counts in sync when posts are created or deleted.
  # direct_reply_count: incremented on the immediate parent only.
  # total_descendant_count: incremented on ALL ancestors up the reply chain.

  add_model_callback(:post, :after_create) do
    next if reply_to_post_number.blank?

    # Walk ancestors (excluding deleted, including OP) for stats increment
    ancestors =
      DiscourseNestedReplies.walk_ancestors(
        topic_id: topic_id,
        start_post_number: reply_to_post_number,
        exclude_deleted: true,
      )

    next if ancestors.empty?

    ancestor_ids = ancestors.map(&:id)
    direct_parent_id = ancestors.find { |a| a.depth == 1 }&.id

    # Single upsert: increment total_descendant_count for all ancestors,
    # direct_reply_count only for the immediate parent.
    DB.exec(<<~SQL, ids: ancestor_ids, parent_id: direct_parent_id)
      INSERT INTO nested_view_post_stats (post_id, direct_reply_count, total_descendant_count, created_at, updated_at)
      SELECT aid,
             CASE WHEN aid = :parent_id THEN 1 ELSE 0 END,
             1,
             NOW(), NOW()
      FROM unnest(ARRAY[:ids]::int[]) AS aid
      ON CONFLICT (post_id) DO UPDATE SET
        total_descendant_count = nested_view_post_stats.total_descendant_count + 1,
        direct_reply_count = nested_view_post_stats.direct_reply_count +
          CASE WHEN nested_view_post_stats.post_id = :parent_id THEN 1 ELSE 0 END,
        updated_at = NOW()
    SQL
  end

  add_model_callback(:post, :after_destroy) do
    if reply_to_post_number.present?
      my_descendants = NestedViewPostStat.where(post_id: id).pick(:total_descendant_count) || 0
      removed = 1 + my_descendants

      # Walk ancestors (including deleted — post may already be soft-deleted) for stats decrement
      ancestors =
        DiscourseNestedReplies.walk_ancestors(
          topic_id: topic_id,
          start_post_number: reply_to_post_number,
          exclude_deleted: false,
        )

      if ancestors.present?
        ancestor_ids = ancestors.map(&:id)
        direct_parent_id = ancestors.find { |a| a.depth == 1 }&.id

        # Single UPDATE: decrement stats for all ancestors, clamped at 0
        DB.exec(<<~SQL, ids: ancestor_ids, parent_id: direct_parent_id, removed: removed)
          UPDATE nested_view_post_stats
          SET total_descendant_count = GREATEST(total_descendant_count - :removed, 0),
              direct_reply_count = GREATEST(
                direct_reply_count - CASE WHEN post_id = :parent_id THEN 1 ELSE 0 END,
                0
              ),
              updated_at = NOW()
          WHERE post_id = ANY(ARRAY[:ids]::int[])
        SQL
      end
    end

    NestedViewPostStat.where(post_id: id).delete_all
  end
end
