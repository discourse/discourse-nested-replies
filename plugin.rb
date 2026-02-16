# frozen_string_literal: true

# name: discourse-nested-replies
# about: Reddit-style nested/threaded view for Discourse topics
# version: 0.1.0
# authors: Discourse
# url: https://github.com/discourse/discourse-nested-replies
# required_version: 2.7.0

enabled_site_setting :nested_replies_enabled
register_asset "stylesheets/common/nested-view.scss"

module ::DiscourseNestedReplies
  PLUGIN_NAME = "discourse-nested-replies"
  CATEGORY_DEFAULT_FIELD = "nested_replies_default_for_category"
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

  # --- TopicView.on_preload: make the flat view nested-aware ---
  # After TopicView loads posts for the flat view, batch-load direct reply
  # counts so the flat topic JSON response includes reply count metadata.
  # This powers the "View as nested (N replies)" toggle link.
  TopicView.on_preload do |topic_view|
    next unless SiteSetting.nested_replies_enabled

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

  # --- Preserve ?post_number through URL canonicalization redirects ---
  register_modifier(:redirect_to_correct_topic_additional_query_parameters) do |params|
    params + %w[post_number]
  end

  # --- Batch reactions precompute support ---
  # When the nested controller precomputes reactions data in batch (avoiding N+1),
  # it stores the result on post.precomputed_reactions. The prepend below
  # short-circuits the serializer's `reactions` method to use precomputed data
  # instead of calling ReactionsSerializerHelpers.reactions_for_post (which fires
  # a per-post COUNT query).
  #
  # We prepend on PostSerializer (not ReactionsSerializerHelpers) because our
  # plugin loads alphabetically before discourse-reactions, so
  # ReactionsSerializerHelpers doesn't exist yet at boot time. Prepending on
  # PostSerializer works regardless of load order — Ruby's MRO ensures our
  # method is checked first, and `super` resolves at call time.
  add_to_class(:post, :precomputed_reactions) { @precomputed_reactions }
  add_to_class(:post, "precomputed_reactions=") { |val| @precomputed_reactions = val }

  module ::DiscourseNestedReplies::PostSerializerReactionsPatch
    def reactions
      if object.respond_to?(:precomputed_reactions) && (data = object.precomputed_reactions)
        return data
      end
      super
    end
  end
  reloadable_patch { PostSerializer.prepend(DiscourseNestedReplies::PostSerializerReactionsPatch) }

  # --- Depth cap: re-parent replies at max depth ---
  # When nested_replies_cap_nesting_depth is enabled and a user replies to a
  # post that is already at max depth, re-parent the reply to the parent's parent.
  # This prevents chains from exceeding the configured max depth in the data.
  add_model_callback(:post, :before_create) do
    next unless SiteSetting.nested_replies_enabled
    next unless SiteSetting.nested_replies_cap_nesting_depth
    next if reply_to_post_number.blank?

    max_depth = SiteSetting.nested_replies_max_depth

    # Walk ancestors (excluding deleted, stopping before OP) to measure chain depth
    ancestors =
      DiscourseNestedReplies.walk_ancestors(
        topic_id: topic_id,
        start_post_number: reply_to_post_number,
        limit: max_depth + 2,
        exclude_deleted: true,
        stop_at_op: true,
      )
    next if ancestors.empty?

    depth = ancestors.map(&:depth).max
    parent_reply_to = ancestors.find { |a| a.depth == 1 }&.reply_to_post_number

    # Re-parent when the reply would exceed max depth.
    # depth counts hops (visual_depth + 1), so > means visual_depth >= max_depth.
    self.reply_to_post_number = parent_reply_to if depth > max_depth && parent_reply_to.present?
  end

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
