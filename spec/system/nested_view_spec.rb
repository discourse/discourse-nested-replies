# frozen_string_literal: true

RSpec.describe "Nested replies view", type: :system do
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:op) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  let(:nested_view) { PageObjects::Pages::NestedView.new }
  let(:composer) { PageObjects::Components::Composer.new }

  before do
    SiteSetting.nested_replies_enabled = true
    sign_in(user)
  end

  def create_reply_chain(depth:, parent: op)
    posts = [parent]
    depth.times do |i|
      reply_to = i == 0 && parent == op ? nil : posts.last.post_number
      posts << Fabricate(
        :post,
        topic: topic,
        user: Fabricate(:user),
        raw: "Reply at depth #{i + 1}",
        reply_to_post_number: reply_to || posts.last.post_number,
      )
    end
    posts[1..] # exclude the parent
  end

  describe "basic nested view" do
    fab!(:root_reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Root reply") }

    it "displays the nested view with root posts" do
      nested_view.visit_nested(topic)

      expect(nested_view).to have_nested_view
      expect(nested_view).to have_root_post(root_reply)
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

  describe "context view" do
    fab!(:chain_posts) do
      posts = []
      parent = op
      5.times do |i|
        post =
          Fabricate(
            :post,
            topic: topic,
            user: Fabricate(:user),
            raw: "Chain post #{i + 1}",
            reply_to_post_number: parent.post_number,
          )
        posts << post
        parent = post
      end
      posts
    end

    context "with full ancestor context (default)" do
      it "shows the target with ancestor chain" do
        nested_view.visit_nested_context(topic, post_number: chain_posts[3].post_number)

        expect(nested_view).to have_context_view
        expect(nested_view).to have_post(chain_posts[3])
        # Ancestors should be visible
        expect(nested_view).to have_post(chain_posts[0])
        expect(nested_view).to have_post(chain_posts[1])
        expect(nested_view).to have_post(chain_posts[2])
      end

      it "shows 'View full thread' link" do
        nested_view.visit_nested_context(topic, post_number: chain_posts[2].post_number)

        expect(nested_view).to have_view_full_thread_link
      end

      it "does not show 'View parent context' link" do
        nested_view.visit_nested_context(topic, post_number: chain_posts[2].post_number)

        expect(nested_view).to have_no_view_parent_context_link
      end
    end

    context "with context=0 (no ancestors)" do
      it "renders target at depth 0 with no ancestors" do
        nested_view.visit_nested_context(topic, post_number: chain_posts[3].post_number, context: 0)

        expect(nested_view).to have_context_view
        expect(nested_view).to have_post_at_depth(chain_posts[3], depth: 0)
        # Ancestors should not be present
        expect(nested_view).to have_no_post(chain_posts[0])
        expect(nested_view).to have_no_post(chain_posts[1])
        expect(nested_view).to have_no_post(chain_posts[2])
      end

      it "shows 'View parent context' link" do
        nested_view.visit_nested_context(topic, post_number: chain_posts[3].post_number, context: 0)

        expect(nested_view).to have_view_parent_context_link
      end

      it "clicking 'View parent context' shows full ancestor chain" do
        nested_view.visit_nested_context(topic, post_number: chain_posts[3].post_number, context: 0)
        nested_view.click_view_parent_context

        expect(nested_view).to have_context_view
        expect(nested_view).to have_post(chain_posts[0])
        expect(nested_view).to have_post(chain_posts[1])
        expect(nested_view).to have_post(chain_posts[2])
        expect(nested_view).to have_post(chain_posts[3])
      end
    end

    it "clicking 'View full thread' returns to root view" do
      nested_view.visit_nested_context(topic, post_number: chain_posts[2].post_number)
      nested_view.click_view_full_thread

      expect(nested_view).to have_nested_view
      expect(nested_view).to have_no_css(".nested-context-view")
    end
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

  describe "replying to posts" do
    fab!(:root_reply) do
      Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Root reply to discuss")
    end

    it "stays on nested view after replying to a nested post" do
      nested_view.visit_nested(topic)
      expect(nested_view).to have_nested_view

      nested_view.click_reply_on_post(root_reply)
      expect(composer).to be_opened

      composer.fill_content("This is my nested reply")
      composer.submit

      expect(composer).to be_closed
      expect(nested_view).to have_nested_view
      expect(page).to have_current_path(%r{/nested/})
    end

    it "stays on nested view after replying to the OP" do
      nested_view.visit_nested(topic)
      expect(nested_view).to have_nested_view

      nested_view.click_reply_on_op
      expect(composer).to be_opened

      composer.fill_content("This is a reply to the original post")
      composer.submit

      expect(composer).to be_closed
      expect(nested_view).to have_nested_view
      expect(page).to have_current_path(%r{/nested/})
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

      # Create a reply to the max-depth post — should be re-parented
      reply =
        PostCreator.new(
          user,
          raw: "This should be re-parented",
          topic_id: topic.id,
          reply_to_post_number: max_depth_post.post_number,
        ).create

      # The reply should have been re-parented to the max-depth post's parent
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
  end
end
