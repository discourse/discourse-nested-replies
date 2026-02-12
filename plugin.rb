# frozen_string_literal: true

# name: discourse-nested-replies
# about: Reddit-style nested/threaded view for Discourse topics
# meta_topic_id: TODO
# version: 0.1.0
# authors: Discourse
# url: TODO
# required_version: 2.7.0

enabled_site_setting :nested_replies_enabled
register_asset "stylesheets/common/nested-view.scss"

module ::DiscourseNestedReplies
  PLUGIN_NAME = "discourse-nested-replies"
  CATEGORY_DEFAULT_FIELD = "nested_replies_default_for_category"
end

require_relative "lib/discourse_nested_replies/engine"

after_initialize do
  # --- Guardian: fix anonymous user crash in edit group checks ---
  # Core's is_in_edit_post_groups? and is_in_edit_topic_groups? call
  # user.in_any_groups? without a nil guard, crashing for anon users.
  Guardian.prepend DiscourseNestedReplies::GuardianExtension

  # --- PostSerializer: pass direct_reply_counts via INSTANCE_VARS ---
  # This lets callers pass a preloaded hash as a serializer option.
  # The constructor auto-sets it as @direct_reply_counts on the instance.
  add_to_class(:post_serializer, :direct_reply_counts) { @direct_reply_counts }
  add_to_class(:post_serializer, "direct_reply_counts=") { |val| @direct_reply_counts = val }
  PostSerializer::INSTANCE_VARS << :direct_reply_counts

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

    topic_view.instance_variable_set(:@nested_replies_direct_reply_counts, counts)
  end

  # Helper to retrieve flat-view preloaded counts from TopicView
  add_to_class(:post_serializer, :nested_replies_flat_view_counts) do
    return nil unless @topic_view
    @topic_view.instance_variable_get(:@nested_replies_direct_reply_counts)
  end

  # --- Serialize direct_reply_count on posts (gated) ---
  # Included when @direct_reply_counts is populated by our nested controller
  # OR when the TopicView.on_preload hook above ran for the flat view.
  # Zero overhead on serialization paths that provide neither.
  add_to_serializer(
    :post,
    :direct_reply_count,
    include_condition: -> do
      @direct_reply_counts.present? || nested_replies_flat_view_counts.present?
    end,
  ) do
    counts = @direct_reply_counts || nested_replies_flat_view_counts
    counts&.dig(object.post_number) || 0
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
  PostSerializer.prepend(DiscourseNestedReplies::PostSerializerReactionsPatch)

  # --- Depth cap: re-parent replies at max depth ---
  # When nested_replies_cap_nesting_depth is enabled and a user replies to a
  # post that is already at max depth, re-parent the reply to the parent's parent.
  # This prevents chains from exceeding the configured max depth in the data.
  add_model_callback(:post, :before_create) do
    next unless SiteSetting.nested_replies_enabled
    next unless SiteSetting.nested_replies_cap_nesting_depth
    next if reply_to_post_number.blank?

    # Count depth of the post we're replying to by walking up the chain
    depth = 0
    current_number = reply_to_post_number
    max_depth = SiteSetting.nested_replies_max_depth

    while current_number.present? && depth < max_depth + 2
      ancestor = Post.find_by(topic_id: topic_id, post_number: current_number, deleted_at: nil)
      break unless ancestor
      depth += 1
      current_number = ancestor.reply_to_post_number
      break if current_number.nil? || current_number == 1
    end

    # Re-parent when the reply would exceed max depth.
    # depth counts hops (visual_depth + 1), so > means visual_depth >= max_depth.
    if depth > max_depth
      parent = Post.find_by(topic_id: topic_id, post_number: reply_to_post_number, deleted_at: nil)
      if parent&.reply_to_post_number.present?
        self.reply_to_post_number = parent.reply_to_post_number
      end
    end
  end

  # --- Stats maintenance callbacks ---
  # Keep nested_view_post_stats counts in sync when posts are created or deleted.
  # direct_reply_count: incremented on the immediate parent only.
  # total_descendant_count: incremented on ALL ancestors up the reply chain.

  add_model_callback(:post, :after_create) do
    if reply_to_post_number.present?
      current_number = reply_to_post_number
      is_direct_parent = true

      while current_number.present?
        ancestor = Post.find_by(topic_id: topic_id, post_number: current_number, deleted_at: nil)
        break unless ancestor

        stat = NestedViewPostStat.find_or_initialize_by(post_id: ancestor.id)
        stat.direct_reply_count = (stat.direct_reply_count || 0) + 1 if is_direct_parent
        stat.total_descendant_count = (stat.total_descendant_count || 0) + 1
        stat.save!

        is_direct_parent = false
        current_number = ancestor.reply_to_post_number
      end
    end
  end

  add_model_callback(:post, :after_destroy) do
    if reply_to_post_number.present?
      # This post's own descendant count needs to be subtracted from all ancestors
      my_stat = NestedViewPostStat.find_by(post_id: id)
      my_descendants = my_stat&.total_descendant_count || 0
      removed = 1 + my_descendants

      current_number = reply_to_post_number
      is_direct_parent = true

      while current_number.present?
        ancestor = Post.find_by(topic_id: topic_id, post_number: current_number)
        break unless ancestor

        stat = NestedViewPostStat.find_by(post_id: ancestor.id)
        if stat
          stat.direct_reply_count = [stat.direct_reply_count - 1, 0].max if is_direct_parent
          stat.total_descendant_count = [stat.total_descendant_count - removed, 0].max
          stat.save!
        end

        is_direct_parent = false
        current_number = ancestor.reply_to_post_number
      end
    end

    # Clean up this post's own stat row
    NestedViewPostStat.where(post_id: id).delete_all
  end
end
