# frozen_string_literal: true

module PageObjects
  module Pages
    class NestedTopic < PageObjects::Pages::Base
      def visit_topic(topic)
        page.visit(topic.url)
        self
      end

      def switch_to_nested_view
        find(".nested-view-toggle .btn-flat", text: /Nested/i).click
        self
      end

      def switch_to_chronological_view
        find(".nested-view-toggle .btn-flat", text: /Chronological/i).click
        self
      end

      def is_nested_view_active?
        has_css?(".nested-view-toggle .btn-flat.active", text: /Nested/i)
      end

      def is_chronological_view_active?
        has_css?(".nested-view-toggle .btn-flat.active", text: /Chronological/i)
      end

      def has_nested_view_toggle?
        has_css?(".nested-view-toggle")
      end

      def has_no_nested_view_toggle?
        has_no_css?(".nested-view-toggle")
      end

      def has_nested_post_stream?
        has_css?(".nested-post-stream")
      end

      def has_no_nested_post_stream?
        has_no_css?(".nested-post-stream")
      end

      def has_nested_post_node?(post_number)
        has_css?(".nested-post-node[data-post-number='#{post_number}']")
      end

      def nested_post_nodes_count
        all(".nested-post-node").count
      end

      def nested_top_level_posts_count
        all(".nested-post-stream > .nested-posts-container > .nested-post-node").count
      end

      def has_load_more_button?
        has_css?(".load-more")
      end

      def has_no_load_more_button?
        has_no_css?(".load-more")
      end

      def click_load_more
        find(".load-more").click
        self
      end

      def has_loading_spinner?
        has_css?(".conditional-loading-spinner")
      end

      def scroll_to_bottom
        page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
        self
      end

      def has_reply_button_for_post(post_number)
        within_nested_post(post_number) { has_css?(".post-action-menu__reply") }
      end

      def has_replies_count_for_post(post_number, count:)
        within_nested_post(post_number) do
          has_css?(".post-action-menu__show-replies", text: "#{count}")
        end
      end

      def within_nested_post(post_number)
        within(find(".nested-post-node[data-post-number='#{post_number}']")) { yield }
      end

      def has_load_more_replies_button_for_post?(post_number)
        within_nested_post(post_number) { has_css?(".nested-load-more-replies") }
      end

      def has_no_load_more_replies_button_for_post?(post_number)
        within_nested_post(post_number) { has_no_css?(".nested-load-more-replies") }
      end

      def click_load_more_replies_for_post(post_number)
        within_nested_post(post_number) { find(".nested-load-more-replies button").click }
        self
      end

      def nested_replies_count_for_post(post_number)
        within_nested_post(post_number) { all(".nested-post-reply").count }
      end

      def has_sort_dropdown?
        has_css?(".nested-sort-dropdown")
      end

      def has_no_sort_dropdown?
        has_no_css?(".nested-sort-dropdown")
      end

      def select_sort(sort_name)
        find(".nested-sort-dropdown").click
        find(".select-kit-row[data-value='#{sort_name}']").click
        self
      end

      def top_level_post_numbers
        all(".nested-post-stream > .nested-posts-container > .nested-post-node").map do |node|
          node["data-post-number"].to_i
        end
      end
    end
  end
end
