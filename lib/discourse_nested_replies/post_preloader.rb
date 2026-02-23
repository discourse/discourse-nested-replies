# frozen_string_literal: true

module ::DiscourseNestedReplies
  class PostPreloader
    def initialize(topic_view:, topic:, current_user:, guardian:)
      @topic_view = topic_view
      @topic = topic
      @current_user = current_user
      @guardian = guardian
    end

    # Set our posts on the topic_view so its lazy-loaded batch methods
    # (all_post_actions, reviewable_counts, bookmarks, mentioned_users, etc.)
    # operate on the correct set of posts. Also clears stale caches and
    # runs plugin preload hooks.
    def prepare(posts)
      user_ids = posts.map(&:user_id).compact.uniq

      # Wrap posts so on_preload hooks that call .includes() or .pluck()
      # on topic_view.posts work transparently with our loaded array.
      @topic_view.posts = PostsArray.new(posts)

      # Load custom fields
      allowed_post_fields = TopicView.allowed_post_custom_fields(@current_user, @topic)
      @topic_view.post_custom_fields =
        if allowed_post_fields.present?
          Post.custom_fields_for_ids(posts.map(&:id).uniq, allowed_post_fields)
        else
          {}
        end

      allowed_user_fields = User.allowed_user_custom_fields(@guardian)
      @topic_view.user_custom_fields =
        if allowed_user_fields.present?
          User.custom_fields_for_ids(user_ids, allowed_user_fields)
        else
          {}
        end

      # Skip the nested-replies on_preload hook — the nested controller
      # runs its own direct_reply_counts query, so the hook is redundant here.
      @topic_view.nested_replies_skip_preload = true
      TopicView.preload(@topic_view)

      # Preload associations that plugins access during serialization
      preload_plugin_associations(posts)
    end

    private

    # Thin Array subclass that intercepts the ActiveRecord-style methods
    # other plugins' on_preload hooks call on topic_view.posts.
    # Only used inside #prepare — not a public API.
    class PostsArray < Array
      def includes(*associations)
        ActiveRecord::Associations::Preloader.new(records: self, associations: associations).call
        self
      end

      def pluck(*columns)
        if columns.one?
          map(&columns.first)
        else
          map { |record| columns.map { |col| record.public_send(col) } }
        end
      end
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
  end
end
