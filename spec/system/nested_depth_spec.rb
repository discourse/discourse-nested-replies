# frozen_string_literal: true

require_relative "../support/nested_replies_helpers"

RSpec.describe "Nested view depth and nesting", type: :system do
  include NestedRepliesHelpers

  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:op) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  let(:nested_view) { PageObjects::Pages::NestedView.new }

  before do
    SiteSetting.nested_replies_enabled = true
    sign_in(user)
  end

  describe "max depth setting" do
    it "respects a low max depth" do
      SiteSetting.nested_replies_max_depth = 2
      chain = create_reply_chain(depth: 4)

      nested_view.visit_nested(topic)

      expect(nested_view).to have_post_at_depth(chain[0], depth: 0)
      expect(nested_view).to have_post_at_depth(chain[1], depth: 1)
      expect(nested_view).to have_post_at_depth(chain[2], depth: 2)
      expect(nested_view).to have_continue_thread_for(chain[2])
    end

    it "allows deeper nesting with higher max depth" do
      SiteSetting.nested_replies_max_depth = 5
      chain = create_reply_chain(depth: 4)

      nested_view.visit_nested(topic)

      (0..3).each { |i| expect(nested_view).to have_no_continue_thread_for(chain[i]) }
    end
  end

  describe "continue this thread" do
    context "when cap_nesting_depth is OFF" do
      before { SiteSetting.nested_replies_cap_nesting_depth = false }

      it "shows 'Continue this thread' at max depth" do
        SiteSetting.nested_replies_max_depth = 3
        chain = create_reply_chain(depth: 5)

        nested_view.visit_nested(topic)

        expect(nested_view).to have_continue_thread_for(chain[3])
      end

      it "does not show 'Continue this thread' below max depth" do
        SiteSetting.nested_replies_max_depth = 5
        chain = create_reply_chain(depth: 3)

        nested_view.visit_nested(topic)

        chain.each { |post| expect(nested_view).to have_no_continue_thread_for(post) }
      end

      it "navigates to context=0 view when clicking 'Continue this thread'" do
        SiteSetting.nested_replies_max_depth = 3
        chain = create_reply_chain(depth: 5)

        nested_view.visit_nested(topic)
        nested_view.click_continue_thread(chain[3])

        expect(nested_view).to have_context_view
        expect(nested_view).to have_post_at_depth(chain[3], depth: 0)
      end
    end

    context "when cap_nesting_depth is ON" do
      before { SiteSetting.nested_replies_cap_nesting_depth = true }

      it "does not show 'Continue this thread' at max depth" do
        SiteSetting.nested_replies_max_depth = 3
        chain = create_reply_chain(depth: 4)

        nested_view.visit_nested(topic)

        chain.each { |post| expect(nested_view).to have_no_continue_thread_for(post) }
      end
    end
  end

  describe "cap nesting depth" do
    before do
      SiteSetting.nested_replies_cap_nesting_depth = true
      SiteSetting.nested_replies_max_depth = 3
    end

    it "re-parents new replies at max depth to become siblings" do
      chain = create_reply_chain(depth: 4)
      max_depth_post = chain.last

      reply =
        PostCreator.new(
          user,
          raw: "This should be re-parented",
          topic_id: topic.id,
          reply_to_post_number: max_depth_post.post_number,
        ).create

      expect(reply.reply_to_post_number).to eq(max_depth_post.reply_to_post_number)
    end

    it "does not show 'Continue this thread' when cap is on" do
      chain = create_reply_chain(depth: 4)

      nested_view.visit_nested(topic)

      chain.each { |post| expect(nested_view).to have_no_continue_thread_for(post) }
    end

    it "posts at max depth are leaf nodes with no expand controls" do
      chain = create_reply_chain(depth: 4)

      nested_view.visit_nested(topic)

      expect(nested_view).to have_no_expand_button_for(chain.last)
      expect(nested_view).to have_no_continue_thread_for(chain.last)
    end

    it "re-parents reply to capped post and shows it at correct depth" do
      SiteSetting.nested_replies_max_depth = 2
      chain = create_reply_chain(depth: 3)
      capped_post = chain.last

      reply =
        PostCreator.new(
          user,
          raw: "Reply to capped post",
          topic_id: topic.id,
          reply_to_post_number: capped_post.post_number,
        ).create

      expect(reply.reply_to_post_number).to eq(capped_post.reply_to_post_number)

      nested_view.visit_nested(topic)

      expect(nested_view).to have_post(reply)
      expect(nested_view).to have_post_at_depth(reply, depth: 2)
    end
  end
end
