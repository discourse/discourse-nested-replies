# frozen_string_literal: true

require_relative "../support/nested_replies_helpers"

RSpec.describe "Nested view category default", type: :system do
  include NestedRepliesHelpers

  fab!(:admin)
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:category)
  fab!(:nested_category) { Fabricate(:category, name: "Nested Category") }
  fab!(:topic) { Fabricate(:topic, user: user, category: nested_category) }
  fab!(:op) { Fabricate(:post, topic: topic, user: user, post_number: 1) }
  fab!(:reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "A reply") }

  let(:nested_view) { PageObjects::Pages::NestedView.new }
  let(:category_page) { PageObjects::Pages::Category.new }

  before do
    SiteSetting.nested_replies_enabled = true
    nested_category.custom_fields[DiscourseNestedReplies::CATEGORY_DEFAULT_FIELD] = true
    nested_category.save_custom_fields
  end

  describe "category settings UI" do
    before { sign_in(admin) }

    it "allows admin to enable nested view default for a category" do
      unchecked_category = Fabricate(:category, name: "Unchecked Category")

      category_page.visit_settings(unchecked_category)

      expect(page).to have_css(".enable-nested-replies-default")
      checkbox = find(".enable-nested-replies-default input[type='checkbox']")
      expect(checkbox).not_to be_checked

      find(".enable-nested-replies-default label.checkbox-label").click
      category_page.save_settings

      expect(page).to have_current_path(%r{/c/#{unchecked_category.slug}})

      unchecked_category.reload
      expect(
        unchecked_category.custom_fields[DiscourseNestedReplies::CATEGORY_DEFAULT_FIELD],
      ).to eq(true)
    end

    it "shows checkbox as checked when category has nested default enabled" do
      category_page.visit_settings(nested_category)

      checkbox = find(".enable-nested-replies-default input[type='checkbox']")
      expect(checkbox).to be_checked
    end
  end

  describe "topic redirect" do
    before { sign_in(user) }

    it "redirects to nested view when visiting a topic URL directly" do
      page.visit("/t/#{topic.slug}/#{topic.id}")

      expect(page).to have_current_path(%r{/nested/#{topic.slug}/#{topic.id}})
      expect(nested_view).to have_nested_view
    end

    it "redirects to nested view when clicking a topic from the category page" do
      page.visit("/c/#{nested_category.slug}/#{nested_category.id}")
      find(".topic-list-item .raw-topic-link[data-topic-id='#{topic.id}']").click

      expect(page).to have_current_path(%r{/nested/#{topic.slug}/#{topic.id}})
      expect(nested_view).to have_nested_view
    end

    it "does not redirect topics in categories without nested default" do
      normal_topic = Fabricate(:topic, user: user, category: category)
      Fabricate(:post, topic: normal_topic, user: user, post_number: 1)

      page.visit("/t/#{normal_topic.slug}/#{normal_topic.id}")

      expect(page).to have_current_path(%r{/t/#{normal_topic.slug}/#{normal_topic.id}})
      expect(nested_view).to have_no_nested_view
    end

    it "respects ?flat=1 to force flat view even in nested-default category" do
      page.visit("/t/#{topic.slug}/#{topic.id}?flat=1")

      expect(page).to have_current_path(%r{/t/#{topic.slug}/#{topic.id}})
      expect(page).to have_current_path(/flat=1/)
      expect(nested_view).to have_no_nested_view
    end

    it "does not redirect to nested when navigating within flat view (e.g. topic timeline)" do
      page.visit("/t/#{topic.slug}/#{topic.id}?flat=1")
      expect(nested_view).to have_no_nested_view

      # Simulate timeline navigation: routeTo called from within flat topic view
      page.execute_script(
        "require('discourse/lib/url').default.routeTo('/t/#{topic.slug}/#{topic.id}/#{reply.post_number}')",
      )

      expect(page).to have_current_path(%r{/t/#{topic.slug}/#{topic.id}})
      expect(nested_view).to have_no_nested_view
    end
  end
end
