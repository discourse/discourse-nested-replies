# frozen_string_literal: true

require_relative "page_objects/pages/nested_topic"

describe "Nested view", type: :system do
  fab!(:user)
  fab!(:topic) do
    Fabricate(:topic).tap do |t|
      t.custom_fields["nested_replies_enabled"] = true
      t.save_custom_fields
    end
  end

  let(:nested_topic_page) { PageObjects::Pages::NestedTopic.new }

  before do
    SiteSetting.nested_replies_enabled = true
    sign_in(user)
  end

  context "when topic has nested replies enabled" do
    it "shows the view toggle" do
      Fabricate(:post, topic: topic)

      nested_topic_page.visit_topic(topic)

      expect(nested_topic_page).to have_nested_view_toggle
    end

    it "switches between chronological and nested views" do
      Fabricate(:post, topic: topic)

      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      expect(nested_topic_page).to have_nested_post_stream
      expect(nested_topic_page.is_nested_view_active?).to eq(true)

      nested_topic_page.switch_to_chronological_view

      expect(nested_topic_page).to have_no_nested_post_stream
      expect(nested_topic_page.is_chronological_view_active?).to eq(true)
    end

    it "sets hideTimeline flag when switching to nested view" do
      Fabricate(:post, topic: topic)

      nested_topic_page.visit_topic(topic)

      # hideTimeline should be false in chronological view
      hide_timeline_before =
        page.evaluate_script("Discourse.lookup('controller:topic').model.postStream.hideTimeline")
      expect(hide_timeline_before).to eq(false)

      nested_topic_page.switch_to_nested_view

      # hideTimeline should be true in nested view
      hide_timeline_nested =
        page.evaluate_script("Discourse.lookup('controller:topic').model.postStream.hideTimeline")
      expect(hide_timeline_nested).to eq(true)

      nested_topic_page.switch_to_chronological_view

      # hideTimeline should be false again when switching back
      hide_timeline_after =
        page.evaluate_script("Discourse.lookup('controller:topic').model.postStream.hideTimeline")
      expect(hide_timeline_after).to eq(false)
    end
  end

  context "when topic has many top-level posts" do
    before do
      # Create 25 top-level posts (no reply_to_post_number)
      # This exceeds the default chunk size of 20, so pagination should trigger
      25.times { |i| Fabricate(:post, topic: topic, raw: "Top level post #{i + 1}") }
    end

    it "supports infinite scrolling" do
      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      # Should initially show 20 top-level posts (chunk size)
      expect(nested_topic_page.nested_top_level_posts_count).to eq(20)

      # Scroll to bottom of page to trigger IntersectionObserver
      page.execute_script("window.scrollTo(0, document.body.scrollHeight)")

      # Wait for loading to complete and new posts to appear
      expect(page).to have_css(".nested-post-node", count: 25, wait: 10)

      # Should now show all 25 top-level posts
      expect(nested_topic_page.nested_top_level_posts_count).to eq(25)
    end
  end

  context "when posts have nested replies" do
    before do
      # Create parent post first
      @parent_post = Fabricate(:post, topic: topic, raw: "Parent post")

      # Create 15 direct replies to the parent post
      15.times do |i|
        reply =
          Fabricate(
            :post,
            topic: topic,
            reply_to_post_number: @parent_post.post_number,
            raw: "Reply #{i + 1}",
          )
        PostReply.create!(post: @parent_post, reply: reply)
      end

      @parent_post.reload
      @parent_post.update!(reply_count: @parent_post.replies.count)
    end

    let(:parent_post) { @parent_post }

    it "displays nested replies under parent posts" do
      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      parent_post_number = parent_post.reload.post_number

      # Wait for nested posts to render
      expect(page).to have_css(".nested-post-node", wait: 10)

      # Verify parent post node is rendered
      expect(nested_topic_page).to have_nested_post_node(parent_post_number)

      # Verify nested replies are visible
      expect(page).to have_text("Reply 1")
      expect(page).to have_text("Reply 2")
    end

    it "shows reply buttons with actions_summary" do
      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      # Wait for posts to render
      expect(page).to have_css(".nested-post-node", wait: 10)

      # Verify reply buttons are present
      expect(page).to have_css(".post-action-menu__reply", minimum: 1)
    end

    it "opens composer when reply button is clicked" do
      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      # Wait for posts to render
      expect(page).to have_css(".nested-post-node", wait: 10)

      # Click the first reply button
      first(".post-action-menu__reply").click

      # Verify composer opens
      expect(page).to have_css("#reply-control", wait: 10)
      expect(page).to have_css(".d-editor-input")
    end

    it "loads more replies incrementally when 'load more' is clicked" do
      SiteSetting.nested_replies_max_initial_replies = 3
      SiteSetting.nested_replies_load_more_count = 5

      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      parent_post_number = parent_post.reload.post_number

      # Wait for nested posts to render
      expect(page).to have_css(".nested-post-node", wait: 10)

      # Should initially show only 3 replies (based on site setting)
      expect(nested_topic_page.nested_replies_count_for_post(parent_post_number)).to eq(3)

      # Should show "load more" button with count
      expect(nested_topic_page).to have_load_more_replies_button_for_post(parent_post_number)
      expect(page).to have_text("Load 12 more replies")

      # Click "load more" button
      nested_topic_page.click_load_more_replies_for_post(parent_post_number)

      # Should now show 8 replies (3 initial + 5 from batch)
      expect(nested_topic_page.nested_replies_count_for_post(parent_post_number)).to eq(8)

      # Button text should update
      expect(page).to have_text("Load 7 more replies")

      # Click again
      nested_topic_page.click_load_more_replies_for_post(parent_post_number)

      # Should now show 13 replies (8 + 5 more)
      expect(nested_topic_page.nested_replies_count_for_post(parent_post_number)).to eq(13)

      # Button text should update again
      expect(page).to have_text("Load 2 more replies")

      # Click one more time
      nested_topic_page.click_load_more_replies_for_post(parent_post_number)

      # Should now show all 15 replies
      expect(nested_topic_page.nested_replies_count_for_post(parent_post_number)).to eq(15)

      # Button should disappear
      expect(nested_topic_page).to have_no_load_more_replies_button_for_post(parent_post_number)
    end

    it "preserves scroll position when loading more replies" do
      SiteSetting.nested_replies_max_initial_replies = 3
      SiteSetting.nested_replies_load_more_count = 5

      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      parent_post_number = parent_post.reload.post_number

      # Wait for nested posts to render
      expect(page).to have_css(".nested-post-node", wait: 10)

      # Scroll to a specific position near the load more button
      load_more_button = find(".nested-load-more-replies button")
      page.execute_script("arguments[0].scrollIntoView({block: 'center'});", load_more_button)

      # Wait for scroll to settle
      sleep 0.5

      # Get initial scroll position and anchor element position
      initial_scroll_y = page.evaluate_script("window.scrollY")
      anchor_element = page.evaluate_script(<<~JS)
        document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2)
      JS
      initial_anchor_top =
        page.evaluate_script("arguments[0].getBoundingClientRect().top", anchor_element)

      # Click "load more" button
      load_more_button.click

      # Wait for new content to load
      expect(nested_topic_page.nested_replies_count_for_post(parent_post_number)).to eq(8)

      # Wait for scroll restoration to complete
      sleep 0.1

      # Get scroll position and anchor element position after loading
      final_scroll_y = page.evaluate_script("window.scrollY")
      final_anchor_top =
        page.evaluate_script("arguments[0].getBoundingClientRect().top", anchor_element)

      # The anchor element should stay at approximately the same viewport position
      # Allow 5px tolerance for small rendering differences
      expect((final_anchor_top - initial_anchor_top).abs).to be < 5
    end
  end

  context "when topic has small action posts" do
    before do
      # Create a regular post
      Fabricate(:post, topic: topic, raw: "Regular post")

      # Create a small action post (e.g., topic closed)
      Fabricate(:small_action, topic: topic)
    end

    it "renders small action posts with proper styling" do
      nested_topic_page.visit_topic(topic)
      nested_topic_page.switch_to_nested_view

      # Wait for nested posts to render
      expect(page).to have_css(".nested-post-node", wait: 10)

      # Verify small action post is rendered with the correct class
      # Use visible: :all because the element might be considered not visible by Capybara
      expect(page).to have_css(".small-action", visible: :all)

      # Verify it has the icon
      expect(page).to have_css(".small-action .topic-avatar svg", visible: :all)

      # Verify small action description is present
      expect(page).to have_css(".small-action-desc", visible: :all)

      # Verify it's using PostSmallAction component, not regular Post
      expect(page).to have_no_css(".small-action article.boxed")
    end
  end

  context "when topic doesn't have nested replies enabled" do
    fab!(:regular_topic, :topic)

    before { Fabricate(:post, topic: regular_topic) }

    it "doesn't show the view toggle" do
      nested_topic_page.visit_topic(regular_topic)

      expect(nested_topic_page).to have_no_nested_view_toggle
    end
  end

  context "when sorting posts in nested view" do
    fab!(:sort_topic) do
      Fabricate(:topic).tap do |t|
        t.custom_fields["nested_replies_enabled"] = true
        t.save_custom_fields
      end
    end

    before do
      # Create posts with different attributes for sorting
      freeze_time

      # Post 1 (topic OP)
      Fabricate(:post, topic: sort_topic, post_number: 1, created_at: 4.days.ago)

      # Post 2: oldest, no likes
      @post2 =
        Fabricate(:post, topic: sort_topic, post_number: 2, created_at: 3.days.ago, raw: "Post 2")

      # Post 3: middle age, 5 likes
      @post3 =
        Fabricate(:post, topic: sort_topic, post_number: 3, created_at: 2.days.ago, raw: "Post 3")
      5.times { PostActionCreator.like(Fabricate(:user), @post3) }

      # Post 4: newest, 2 likes
      @post4 =
        Fabricate(:post, topic: sort_topic, post_number: 4, created_at: 1.day.ago, raw: "Post 4")
      2.times { PostActionCreator.like(Fabricate(:user), @post4) }
    end

    it "shows sort dropdown in nested view but not in chronological view" do
      nested_topic_page.visit_topic(sort_topic)

      # Sort dropdown should not show in chronological view
      expect(nested_topic_page).to have_no_sort_dropdown

      nested_topic_page.switch_to_nested_view

      # Sort dropdown should show in nested view
      expect(nested_topic_page).to have_sort_dropdown
    end

    it "sorts posts by chronological order by default" do
      nested_topic_page.visit_topic(sort_topic)
      nested_topic_page.switch_to_nested_view

      # Should be in chronological order by default (post_number)
      expect(nested_topic_page.top_level_post_numbers).to eq([1, 2, 3, 4])
    end

    it "sorts posts by new (newest first)" do
      nested_topic_page.visit_topic(sort_topic)
      nested_topic_page.switch_to_nested_view

      nested_topic_page.select_sort("new")

      # Wait for posts to reload
      expect(page).to have_css(".nested-post-node", count: 4, wait: 5)

      # Should be in reverse chronological order (newest first)
      expect(nested_topic_page.top_level_post_numbers).to eq([4, 3, 2, 1])
    end

    it "sorts posts by best (most liked first)" do
      nested_topic_page.visit_topic(sort_topic)
      nested_topic_page.switch_to_nested_view

      nested_topic_page.select_sort("best")

      # Wait for posts to reload
      expect(page).to have_css(".nested-post-node", count: 4, wait: 5)

      # Should be sorted by like count (3 has 5 likes, 4 has 2 likes, 2 and 1 have 0)
      expect(nested_topic_page.top_level_post_numbers).to eq([3, 4, 2, 1])
    end
  end

end
