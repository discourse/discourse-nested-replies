# frozen_string_literal: true

require "rails_helper"

describe DiscourseNestedReplies::TopicsController do
  fab!(:user)
  fab!(:topic)
  fab!(:post1) { Fabricate(:post, topic: topic, post_number: 1) }
  fab!(:post2) { Fabricate(:post, topic: topic, post_number: 2) }
  fab!(:post3, :post) { Fabricate(:post, topic: topic, post_number: 3, reply_to_post_number: 2) }
  fab!(:post4, :post) { Fabricate(:post, topic: topic, post_number: 4, reply_to_post_number: 2) }

  before do
    SiteSetting.nested_replies_enabled = true
    topic.custom_fields["nested_replies_enabled"] = true
    topic.save_custom_fields
  end

  describe "#show" do
    it "returns nested structure for topic" do
      sign_in(user)

      get "/t/-/#{topic.id}/nested.json"

      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["nested_posts"].length).to eq(2)

      post2_node = json["nested_posts"].find { |n| n["post"]["post_number"] == 2 }
      expect(post2_node["replies"].length).to eq(2)
      expect(post2_node["total_reply_count"]).to eq(2)
    end

    it "requires nested replies to be enabled" do
      sign_in(user)
      topic.custom_fields["nested_replies_enabled"] = false
      topic.save_custom_fields

      get "/t/-/#{topic.id}/nested.json"

      expect(response.status).to eq(403)
    end

    it "paginates top-level posts" do
      sign_in(user)

      25.times { Fabricate(:post, topic: topic) }

      get "/t/-/#{topic.id}/nested.json", params: { page: 2 }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["meta"]["page"]).to eq(2)
      expect(json["meta"]["has_previous_page"]).to eq(true)
    end

    it "flattens multi-level replies" do
      sign_in(user)

      post5 = Fabricate(:post, topic: topic, post_number: 5, reply_to_post_number: 3)

      get "/t/-/#{topic.id}/nested.json"

      json = response.parsed_body
      post2_node = json["nested_posts"].find { |n| n["post"]["post_number"] == 2 }

      expect(post2_node["replies"].length).to eq(3)
      expect(post2_node["replies"].map { |r| r["post_number"] }).to include(3, 4, 5)
    end
  end

  describe "#load_more_replies" do
    fab!(:post_with_many_replies) { Fabricate(:post, topic: topic, post_number: 10) }

    before do
      # Create 15 replies to post_with_many_replies
      15.times do |i|
        Fabricate(:post, topic: topic, reply_to_post_number: post_with_many_replies.post_number)
      end
    end

    it "loads paginated replies" do
      sign_in(user)

      get "/nested-replies/posts/#{post_with_many_replies.id}/replies.json",
          params: {
            offset: 0,
            limit: 5,
          }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["posts"].length).to eq(5)
      expect(json["has_more_replies"]).to eq(true)
      expect(json["loaded_count"]).to eq(5)
      expect(json["total_count"]).to eq(15)
    end

    it "loads next batch of replies" do
      sign_in(user)

      get "/nested-replies/posts/#{post_with_many_replies.id}/replies.json",
          params: {
            offset: 5,
            limit: 5,
          }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["posts"].length).to eq(5)
      expect(json["has_more_replies"]).to eq(true)
      expect(json["loaded_count"]).to eq(10)
      expect(json["total_count"]).to eq(15)
    end

    it "indicates no more replies on last batch" do
      sign_in(user)

      get "/nested-replies/posts/#{post_with_many_replies.id}/replies.json",
          params: {
            offset: 10,
            limit: 5,
          }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["posts"].length).to eq(5)
      expect(json["has_more_replies"]).to eq(false)
      expect(json["loaded_count"]).to eq(15)
      expect(json["total_count"]).to eq(15)
    end

    it "uses site setting for default limit" do
      sign_in(user)
      SiteSetting.nested_replies_load_more_count = 7

      get "/nested-replies/posts/#{post_with_many_replies.id}/replies.json", params: { offset: 0 }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["posts"].length).to eq(7)
    end

    it "requires nested replies to be enabled on topic" do
      sign_in(user)
      topic.custom_fields["nested_replies_enabled"] = false
      topic.save_custom_fields

      get "/nested-replies/posts/#{post_with_many_replies.id}/replies.json",
          params: {
            offset: 0,
            limit: 5,
          }

      expect(response.status).to eq(403)
    end

    it "returns 404 for non-existent post" do
      sign_in(user)

      get "/nested-replies/posts/99999/replies.json", params: { offset: 0, limit: 5 }

      expect(response.status).to eq(404)
    end

    it "includes nested descendants in flattened order" do
      sign_in(user)

      # Create a chain: post_with_many_replies -> reply1 -> reply2
      reply1 =
        Fabricate(:post, topic: topic, reply_to_post_number: post_with_many_replies.post_number)
      reply2 = Fabricate(:post, topic: topic, reply_to_post_number: reply1.post_number)

      get "/nested-replies/posts/#{post_with_many_replies.id}/replies.json",
          params: {
            offset: 0,
            limit: 20,
          }

      expect(response.status).to eq(200)
      json = response.parsed_body

      # Should include reply1 and reply2 in the flattened list
      expect(json["total_count"]).to eq(17) # 15 original + reply1 + reply2
      post_numbers = json["posts"].map { |p| p["post_number"] }
      expect(post_numbers).to include(reply1.post_number, reply2.post_number)
    end
  end
end
