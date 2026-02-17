# frozen_string_literal: true

require_relative "../support/nested_replies_helpers"

RSpec.describe "Nested view", type: :system do
  include NestedRepliesHelpers

  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:op) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  let(:nested_view) { PageObjects::Pages::NestedView.new }

  before do
    SiteSetting.nested_replies_enabled = true
    sign_in(user)
  end

  describe "basic rendering" do
    fab!(:root_reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Root reply") }

    it "displays the nested view with root posts" do
      nested_view.visit_nested(topic)

      expect(nested_view).to have_nested_view
      expect(nested_view).to have_root_post(root_reply)
    end

    it "shows the original post content" do
      op.update!(raw: "This is the original post content")
      op.rebake!

      nested_view.visit_nested(topic)

      expect(nested_view).to have_op_post
      expect(page).to have_css(".nested-view__op", text: "This is the original post content")
    end
  end

  describe "empty topic" do
    it "shows 'no replies' message when topic has no replies" do
      nested_view.visit_nested(topic)

      expect(nested_view).to have_nested_view
      expect(page).to have_css(".nested-view__empty", text: "No replies yet.")
    end
  end

  describe "sorting" do
    fab!(:old_reply) do
      Fabricate(
        :post,
        topic: topic,
        user: Fabricate(:user),
        raw: "Older reply",
        created_at: 2.days.ago,
      )
    end

    fab!(:new_reply) do
      Fabricate(
        :post,
        topic: topic,
        user: Fabricate(:user),
        raw: "Newer reply",
        created_at: 1.minute.ago,
      )
    end

    it "changes sort order and updates the URL" do
      nested_view.visit_nested(topic)
      expect(nested_view).to have_sort_active("top")

      nested_view.click_sort("new")
      expect(nested_view).to have_sort_active("new")
      expect(page).to have_current_path(/sort=new/)

      nested_view.click_sort("old")
      expect(nested_view).to have_sort_active("old")
      expect(page).to have_current_path(/sort=old/)
    end
  end

  describe "expand and collapse" do
    fab!(:root_reply) do
      Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Post with children")
    end

    fab!(:child_reply) do
      Fabricate(
        :post,
        topic: topic,
        user: Fabricate(:user),
        raw: "A child post",
        reply_to_post_number: root_reply.post_number,
      )
    end

    it "collapses post content and children when clicking the depth line" do
      nested_view.visit_nested(topic)

      expect(nested_view).to have_post(child_reply)
      expect(nested_view).to have_children_visible_for(root_reply)
      expect(nested_view).to have_no_collapsed_bar_for(root_reply)

      nested_view.click_depth_line(root_reply)
      expect(nested_view).to have_collapsed_bar_for(root_reply)
      expect(nested_view).to have_no_post_content_visible_for(root_reply)
      expect(nested_view).to have_no_children_visible_for(root_reply)
    end

    it "re-expands post content and children when clicking the collapsed bar" do
      nested_view.visit_nested(topic)

      nested_view.click_depth_line(root_reply)
      expect(nested_view).to have_collapsed_bar_for(root_reply)

      nested_view.click_collapsed_bar(root_reply)
      expect(nested_view).to have_no_collapsed_bar_for(root_reply)
      expect(nested_view).to have_post_content_visible_for(root_reply)
      expect(nested_view).to have_children_visible_for(root_reply)
      expect(nested_view).to have_post(child_reply)
    end
  end

  describe "flat view toggle" do
    fab!(:root_reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "A reply") }

    it "navigates to flat view" do
      nested_view.visit_nested(topic)

      expect(nested_view).to have_flat_view_link
      nested_view.click_flat_view_link

      expect(page).to have_current_path(%r{/t/#{topic.slug}/#{topic.id}})
      expect(page).to have_current_path(/flat=1/)
      expect(nested_view).to have_no_nested_view
    end
  end

  describe "routing" do
    fab!(:root_reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "A reply") }

    it "direct URL loads correctly" do
      page.visit("/nested/#{topic.slug}/#{topic.id}")

      expect(nested_view).to have_nested_view
      expect(nested_view).to have_root_post(root_reply)
      expect(page).to have_current_path(%r{/nested/#{topic.slug}/#{topic.id}})
    end

    it "direct URL with post_number loads context view" do
      chain = create_reply_chain(depth: 3)

      page.visit("/nested/#{topic.slug}/#{topic.id}?post_number=#{chain[1].post_number}")

      expect(nested_view).to have_context_view
      expect(nested_view).to have_post(chain[1])
    end
  end

  describe "anonymous access" do
    fab!(:root_reply) do
      Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Public reply")
    end

    it "allows anonymous users to view the nested view" do
      Capybara.reset_sessions!

      nested_view.visit_nested(topic)

      expect(nested_view).to have_nested_view
      expect(nested_view).to have_root_post(root_reply)
      expect(nested_view).to have_op_post
    end
  end

  describe "plugin disabled" do
    it "returns 404 when plugin is disabled" do
      SiteSetting.nested_replies_enabled = false

      page.visit("/nested/#{topic.slug}/#{topic.id}")

      expect(page).to have_css(".page-not-found")
    end
  end
end
