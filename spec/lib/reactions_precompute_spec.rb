# frozen_string_literal: true

RSpec.describe "Reactions precompute for flat topic view", type: :request do
  before do
    skip "discourse-reactions plugin not installed" unless defined?(DiscourseReactions)
    SiteSetting.nested_replies_enabled = true
    SiteSetting.discourse_reactions_enabled = true
  end

  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:op) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  describe "PostSerializerReactionsPatch" do
    fab!(:post_with_reaction) { Fabricate(:post, topic: topic, user: user) }

    it "uses precomputed_reactions when plugin is enabled" do
      precomputed = [{ id: "heart", type: :emoji, count: 5 }]
      post_with_reaction.precomputed_reactions = precomputed

      json = PostSerializer.new(post_with_reaction, scope: Guardian.new(user), root: false).as_json

      expect(json[:reactions]).to eq(precomputed)
    end

    it "ignores precomputed_reactions when plugin is disabled" do
      SiteSetting.nested_replies_enabled = false
      precomputed = [{ id: "heart", type: :emoji, count: 5 }]
      post_with_reaction.precomputed_reactions = precomputed

      json = PostSerializer.new(post_with_reaction, scope: Guardian.new(user), root: false).as_json

      expect(json[:reactions]).not_to eq(precomputed)
    end
  end

  describe "TopicView.on_preload" do
    it "sets precomputed_reactions on posts during flat topic loading" do
      reply = Fabricate(:post, topic: topic, user: user)

      topic_view = TopicView.new(topic.id, user)
      loaded_reply = topic_view.posts.find { |p| p.id == reply.id }

      expect(loaded_reply.precomputed_reactions).not_to be_nil
    end

    it "does not precompute reactions when plugin is disabled" do
      SiteSetting.nested_replies_enabled = false
      reply = Fabricate(:post, topic: topic, user: user)

      topic_view = TopicView.new(topic.id, user)
      loaded_reply = topic_view.posts.find { |p| p.id == reply.id }

      expect(loaded_reply.precomputed_reactions).to be_nil
    end

    it "does not fire per-post reaction queries as post count grows" do
      3.times { Fabricate(:post, topic: topic, user: user) }

      # Warm up
      TopicView.new(topic.id, user)

      queries_3 = track_sql_queries { TopicView.new(topic.id, user) }

      5.times { Fabricate(:post, topic: topic, user: user) }

      queries_8 = track_sql_queries { TopicView.new(topic.id, user) }

      reaction_queries_3 =
        queries_3.count { |q| q.include?("discourse_reactions") || q.include?("reactions_for") }
      reaction_queries_8 =
        queries_8.count { |q| q.include?("discourse_reactions") || q.include?("reactions_for") }

      expect(reaction_queries_8).to eq(reaction_queries_3)
    end
  end
end
