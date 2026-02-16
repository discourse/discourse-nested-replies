# frozen_string_literal: true

RSpec.describe DiscourseNestedReplies::NestedTopicsController, type: :request do
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:op) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  before { SiteSetting.nested_replies_enabled = true }

  def roots_url(topic, page: 0, sort: "top")
    "/nested/#{topic.slug}/#{topic.id}/roots.json?page=#{page}&sort=#{sort}"
  end

  def children_url(topic, post_number, page: 0, sort: "top", depth: 1)
    "/nested/#{topic.slug}/#{topic.id}/children/#{post_number}.json?page=#{page}&sort=#{sort}&depth=#{depth}"
  end

  def context_url(topic, post_number, sort: "top", context: nil)
    url = "/nested/#{topic.slug}/#{topic.id}/context/#{post_number}.json?sort=#{sort}"
    url += "&context=#{context}" if context
    url
  end

  describe "GET roots" do
    it "returns 404 when plugin is disabled" do
      SiteSetting.nested_replies_enabled = false
      sign_in(user)
      get roots_url(topic)
      expect(response.status).to eq(404)
    end

    it "returns 403 for anonymous users on private topics" do
      private_category = Fabricate(:private_category, group: Fabricate(:group))
      private_topic = Fabricate(:topic, category: private_category)
      Fabricate(:post, topic: private_topic, post_number: 1)
      get roots_url(private_topic)
      expect(response.status).to eq(403)
    end

    it "returns topic metadata and OP on initial load (page 0)" do
      Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      sign_in(user)

      get roots_url(topic, page: 0)
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json).to have_key("topic")
      expect(json).to have_key("op_post")
      expect(json).to have_key("sort")
      expect(json).to have_key("message_bus_last_id")
      expect(json["roots"].length).to eq(2)
      expect(json["page"]).to eq(0)
    end

    it "does not include topic metadata on subsequent pages" do
      25.times { Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil) }
      sign_in(user)

      get roots_url(topic, page: 1)
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json).not_to have_key("topic")
      expect(json).not_to have_key("op_post")
      expect(json["page"]).to eq(1)
    end

    it "paginates with has_more_roots" do
      20.times { Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil) }
      sign_in(user)

      get roots_url(topic, page: 0)
      json = response.parsed_body
      expect(json["has_more_roots"]).to eq(true)
      expect(json["roots"].length).to eq(20)
    end

    it "returns has_more_roots false on last page" do
      5.times { Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil) }
      sign_in(user)

      get roots_url(topic, page: 0)
      json = response.parsed_body
      expect(json["has_more_roots"]).to eq(false)
    end

    it "validates sort parameter and falls back to default" do
      Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      sign_in(user)

      get roots_url(topic, sort: "invalid")
      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["sort"]).to eq(SiteSetting.nested_replies_default_sort)
    end

    it "sorts by top (like_count desc)" do
      low = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil, like_count: 1)
      high = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil, like_count: 10)
      sign_in(user)

      get roots_url(topic, sort: "top")
      json = response.parsed_body
      root_ids = json["roots"].map { |r| r["id"] }
      expect(root_ids).to eq([high.id, low.id])
    end

    it "preloads children in the response" do
      root = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      child = Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      sign_in(user)

      get roots_url(topic, sort: "top")
      json = response.parsed_body
      root_json = json["roots"].first
      expect(root_json["children"]).to be_an(Array)
      expect(root_json["children"].length).to eq(1)
      expect(root_json["children"].first["id"]).to eq(child.id)
    end

    it "includes direct_reply_count and total_descendant_count" do
      root = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      sign_in(user)

      get roots_url(topic)
      json = response.parsed_body
      root_json = json["roots"].first
      expect(root_json).to have_key("direct_reply_count")
      expect(root_json["direct_reply_count"]).to eq(1)
    end

    it "excludes deleted posts for regular users" do
      root = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      root.update!(deleted_at: Time.current)
      sign_in(user)

      get roots_url(topic)
      json = response.parsed_body
      expect(json["roots"]).to be_empty
    end
  end

  describe "GET children" do
    fab!(:root) { Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil) }

    it "returns children of a post" do
      child1 = Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      child2 = Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      sign_in(user)

      get children_url(topic, root.post_number)
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["children"].length).to eq(2)
      expect(json["page"]).to eq(0)
    end

    it "paginates children" do
      50.times do
        Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      end
      sign_in(user)

      get children_url(topic, root.post_number, page: 0)
      json = response.parsed_body
      expect(json["has_more"]).to eq(true)
      expect(json["children"].length).to eq(50)
    end

    it "returns has_more false when fewer than page size" do
      3.times { Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number) }
      sign_in(user)

      get children_url(topic, root.post_number)
      json = response.parsed_body
      expect(json["has_more"]).to eq(false)
    end

    it "flattens descendants at max depth when cap is enabled" do
      SiteSetting.nested_replies_cap_nesting_depth = true
      SiteSetting.nested_replies_max_depth = 2
      child = Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      grandchild =
        Fabricate(:post, topic: topic, user: user, reply_to_post_number: child.post_number)
      sign_in(user)

      get children_url(topic, child.post_number, depth: 2)
      json = response.parsed_body
      child_json = json["children"].find { |c| c["id"] == grandchild.id }
      expect(child_json).to be_present
      expect(child_json["children"]).to eq([])
    end

    it "returns 404 when plugin is disabled" do
      SiteSetting.nested_replies_enabled = false
      sign_in(user)
      get children_url(topic, root.post_number)
      expect(response.status).to eq(404)
    end
  end

  describe "GET context" do
    it "returns ancestor chain, target post, and siblings" do
      chain = [op]
      3.times do |i|
        reply_to = i == 0 ? nil : chain.last.post_number
        chain << Fabricate(
          :post,
          topic: topic,
          user: Fabricate(:user),
          reply_to_post_number: reply_to,
        )
      end
      target = chain.last
      sign_in(user)

      get context_url(topic, target.post_number)
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json).to have_key("topic")
      expect(json).to have_key("op_post")
      expect(json).to have_key("ancestor_chain")
      expect(json).to have_key("siblings")
      expect(json).to have_key("target_post")
      expect(json).to have_key("message_bus_last_id")
    end

    it "returns empty ancestors when context=0" do
      root = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      child = Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      sign_in(user)

      get context_url(topic, child.post_number, context: 0)
      json = response.parsed_body
      expect(json["ancestor_chain"]).to be_empty
    end

    it "returns 404 for nonexistent post_number" do
      sign_in(user)
      get context_url(topic, 99_999)
      expect(response.status).to eq(404)
    end

    it "returns 404 when plugin disabled" do
      SiteSetting.nested_replies_enabled = false
      root = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      sign_in(user)
      get context_url(topic, root.post_number)
      expect(response.status).to eq(404)
    end

    it "returns 403 for unauthorized topic" do
      private_category = Fabricate(:private_category, group: Fabricate(:group))
      private_topic = Fabricate(:topic, category: private_category)
      Fabricate(:post, topic: private_topic, post_number: 1)
      root = Fabricate(:post, topic: private_topic, reply_to_post_number: nil)
      sign_in(user)
      get context_url(private_topic, root.post_number)
      expect(response.status).to eq(403)
    end

    it "includes target post children" do
      root = Fabricate(:post, topic: topic, user: user, reply_to_post_number: nil)
      child = Fabricate(:post, topic: topic, user: user, reply_to_post_number: root.post_number)
      sign_in(user)

      get context_url(topic, root.post_number)
      json = response.parsed_body
      expect(json["target_post"]["children"]).to be_an(Array)
      expect(json["target_post"]["children"].length).to eq(1)
    end
  end
end
