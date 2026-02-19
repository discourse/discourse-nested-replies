# frozen_string_literal: true

module PageObjects
  module Pages
    class NestedView < PageObjects::Pages::Base
      SORT_LABELS = { "top" => "Top", "new" => "New", "old" => "Old" }.freeze

      def visit_nested(topic)
        page.visit("/nested/#{topic.slug}/#{topic.id}")
        self
      end

      def visit_nested_context(topic, post_number:, context: nil)
        url = "/nested/#{topic.slug}/#{topic.id}?post_number=#{post_number}"
        url += "&context=#{context}" if context
        page.visit(url)
        self
      end

      # ── Root view assertions ──────────────────────────────────────

      def has_nested_view?
        has_css?(".nested-view")
      end

      def has_no_nested_view?
        has_no_css?(".nested-view")
      end

      def has_root_post?(post)
        has_css?(".nested-view__roots [data-post-number='#{post.post_number}']")
      end

      def has_no_root_post?(post)
        has_no_css?(".nested-view__roots [data-post-number='#{post.post_number}']")
      end

      # ── Context view assertions ───────────────────────────────────

      def has_context_view?
        has_css?(".nested-context-view")
      end

      def has_view_full_thread_link?
        has_css?(".nested-context-view__full-thread")
      end

      def has_view_parent_context_link?
        has_css?(".nested-context-view__parent-context")
      end

      def has_no_view_parent_context_link?
        has_no_css?(".nested-context-view__parent-context")
      end

      # ── Post assertions ───────────────────────────────────────────

      def has_post_at_depth?(post, depth:)
        has_css?(".nested-post.--depth-#{depth} [data-post-number='#{post.post_number}']")
      end

      def has_post?(post)
        has_css?("[data-post-number='#{post.post_number}']")
      end

      def has_no_post?(post)
        has_no_css?("[data-post-number='#{post.post_number}']")
      end

      def has_continue_thread_for?(post)
        within(post_container(post)) { has_css?(".nested-post__continue-link") }
      end

      def has_no_continue_thread_for?(post)
        within(post_container(post)) { has_no_css?(".nested-post__continue-link") }
      end

      def has_expand_button_for?(post)
        within(post_container(post)) { has_css?(".nested-post__expand-btn") }
      end

      def has_no_expand_button_for?(post)
        within(post_container(post)) { has_no_css?(".nested-post__expand-btn") }
      end

      def has_highlighted_post?(post)
        has_css?(".nested-post--highlighted [data-post-number='#{post.post_number}']", wait: 5)
      end

      def has_reply_button_for?(post)
        has_css?("[data-post-number='#{post.post_number}'] .post-action-menu__reply")
      end

      def has_children_visible_for?(post)
        wrapper = nested_post_wrapper(post)
        wrapper.has_css?(".nested-post-children")
      end

      def has_no_children_visible_for?(post)
        wrapper = nested_post_wrapper(post)
        wrapper.has_no_css?(".nested-post-children")
      end

      def has_collapsed_bar_for?(post)
        wrapper = nested_post_wrapper(post)
        wrapper.has_css?(".nested-post__collapsed-bar")
      end

      def has_no_collapsed_bar_for?(post)
        wrapper = nested_post_wrapper(post)
        wrapper.has_no_css?(".nested-post__collapsed-bar")
      end

      def has_post_content_visible_for?(post)
        wrapper = nested_post_wrapper(post)
        wrapper.has_css?(".nested-post__article")
      end

      def has_no_post_content_visible_for?(post)
        wrapper = nested_post_wrapper(post)
        wrapper.has_no_css?(".nested-post__article")
      end

      def has_flat_view_link?
        has_css?(".nested-view__flat-link")
      end

      def has_sort_active?(sort)
        has_css?(".nested-sort-selector__option--active", text: SORT_LABELS[sort])
      end

      def has_op_post?
        has_css?(".nested-view__op")
      end

      def has_topic_title_editor?
        has_css?(".edit-topic-title")
      end

      def has_no_topic_title_editor?
        has_no_css?(".edit-topic-title")
      end

      def has_topic_map?
        has_css?(".nested-view__topic-map .topic-map__contents")
      end

      def has_no_top_replies_button?
        has_no_css?(".nested-view__topic-map .top-replies")
      end

      # ── Actions ───────────────────────────────────────────────────

      def click_edit_topic
        find(".nested-view__title .fancy-title").click
        self
      end

      def click_cancel_edit_topic
        find(".edit-topic-title .cancel-edit").click
        self
      end

      def click_save_edit_topic
        find(".edit-topic-title .submit-edit").click
        self
      end

      def fill_in_topic_title(title)
        find(".edit-topic-title input#edit-title").fill_in(with: title)
        self
      end

      def click_post_edit_button(post)
        within("[data-post-number='#{post.post_number}']") do
          find(".show-more-actions").click if has_css?(".show-more-actions", wait: 2)
          find("button.edit").click
        end
        self
      end

      def click_reply_on_post(post)
        find("[data-post-number='#{post.post_number}'] .post-action-menu__reply").click
        self
      end

      def click_reply_on_op
        find(".nested-view__op .post-action-menu__reply").click
        self
      end

      def click_continue_thread(post)
        within(post_container(post)) { find(".nested-post__continue-link").click }
        self
      end

      def click_expand(post)
        within(post_container(post)) { find(".nested-post__expand-btn").click }
        self
      end

      def click_depth_line(post)
        wrapper = nested_post_wrapper(post)
        wrapper.find(".nested-post__depth-line").click
        self
      end

      def click_collapsed_bar(post)
        wrapper = nested_post_wrapper(post)
        wrapper.find(".nested-post__collapsed-bar").click
        self
      end

      def click_view_full_thread
        find(".nested-context-view__full-thread").click
        self
      end

      def click_view_parent_context
        find(".nested-context-view__parent-context").click
        self
      end

      def click_flat_view_link
        find(".nested-view__flat-link").click
        self
      end

      def click_sort(sort)
        find(".nested-sort-selector__option", text: SORT_LABELS[sort]).click
        self
      end

      # ── Post counting ─────────────────────────────────────────────

      def posts_at_depth(depth)
        all(".nested-post.--depth-#{depth} .nested-post__article")
      end

      private

      def post_container(post)
        find("[data-post-number='#{post.post_number}']")
      end

      def nested_post_wrapper(post)
        find("[data-post-number='#{post.post_number}']").ancestor(".nested-post", match: :first)
      end
    end
  end
end
