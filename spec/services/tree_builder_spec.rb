# frozen_string_literal: true

require "rails_helper"

describe DiscourseNestedReplies::TreeBuilder do
  fab!(:user)
  fab!(:topic)
  fab!(:post1) { Fabricate(:post, topic: topic, post_number: 1) }

  let(:guardian) { Guardian.new(user) }

  describe "#build" do
    it "handles posts with no replies" do
      builder = described_class.new(topic, guardian)
      result = builder.build

      expect(result[:nested_posts].length).to eq(1)
      expect(result[:nested_posts][0][:replies]).to be_empty
    end

    it "collects flattened replies" do
      post2 = Fabricate(:post, topic: topic, post_number: 2)
      post3 = Fabricate(:post, topic: topic, post_number: 3, reply_to_post_number: 2)
      post4 = Fabricate(:post, topic: topic, post_number: 4, reply_to_post_number: 3)

      builder = described_class.new(topic, guardian)
      result = builder.build

      post2_node = result[:nested_posts].find { |n| n[:post].id == post2.id }
      expect(post2_node[:replies].map(&:id)).to contain_exactly(post3.id, post4.id)
    end

    it "prevents infinite loops from circular references" do
      post2 = Fabricate(:post, topic: topic, post_number: 2, reply_to_post_number: 3)
      post3 = Fabricate(:post, topic: topic, post_number: 3, reply_to_post_number: 2)

      builder = described_class.new(topic, guardian)

      expect { builder.build }.not_to raise_error
    end

    it "respects guardian permissions" do
      private_post = Fabricate(:post, topic: topic, post_type: Post.types[:whisper])

      builder = described_class.new(topic, guardian)
      result = builder.build

      all_posts = result[:nested_posts].flat_map { |node| [node[:post]] + node[:replies] }

      expect(all_posts).not_to include(private_post)
    end

    it "limits initial replies based on site setting" do
      post2 = Fabricate(:post, topic: topic, post_number: 2)
      15.times { Fabricate(:post, topic: topic, reply_to_post_number: 2) }

      SiteSetting.nested_replies_max_initial_replies = 5

      builder = described_class.new(topic, guardian)
      result = builder.build

      post2_node = result[:nested_posts].find { |n| n[:post].id == post2.id }
      expect(post2_node[:replies].length).to eq(5)
      expect(post2_node[:total_reply_count]).to eq(15)
      expect(post2_node[:loaded_reply_count]).to eq(5)
      expect(post2_node[:has_more_replies]).to eq(true)
    end

    context "when sorting posts" do
      before do
        # Update post1 (already exists from fab!) to have controlled attributes
        post1.update!(created_at: 4.days.ago, like_count: 0)

        # Post 2: 3 days ago, 0 likes
        @post2 = Fabricate(:post, topic: topic, post_number: 2, created_at: 3.days.ago)

        # Post 3: 2 days ago, 5 likes
        @post3 = Fabricate(:post, topic: topic, post_number: 3, created_at: 2.days.ago)
        PostActionCreator.like(user, @post3)
        PostActionCreator.like(Fabricate(:user), @post3)
        PostActionCreator.like(Fabricate(:user), @post3)
        PostActionCreator.like(Fabricate(:user), @post3)
        PostActionCreator.like(Fabricate(:user), @post3)

        # Post 4: 1 day ago (newest), 2 likes
        @post4 = Fabricate(:post, topic: topic, post_number: 4, created_at: 1.day.ago)
        PostActionCreator.like(user, @post4)
        PostActionCreator.like(Fabricate(:user), @post4)

        # Reload to get updated like counts
        post1.reload
        @post2.reload
        @post3.reload
        @post4.reload
      end

      it "sorts by chronological (post_number) by default" do
        builder = described_class.new(topic, guardian)
        result = builder.build

        post_numbers = result[:nested_posts].map { |n| n[:post].post_number }
        expect(post_numbers).to eq([1, 2, 3, 4])
      end

      it "sorts by chronological (post_number) when explicitly specified" do
        builder = described_class.new(topic, guardian, sort: "chronological")
        result = builder.build

        post_numbers = result[:nested_posts].map { |n| n[:post].post_number }
        expect(post_numbers).to eq([1, 2, 3, 4])
      end

      it "sorts by new (created_at DESC)" do
        builder = described_class.new(topic, guardian, sort: "new")
        result = builder.build

        post_numbers = result[:nested_posts].map { |n| n[:post].post_number }
        # Should be: 4 (1 day ago), 3 (2 days ago), 2 (3 days ago), 1 (4 days ago)
        expect(post_numbers).to eq([4, 3, 2, 1])
      end

      it "sorts by best (like_count DESC)" do
        builder = described_class.new(topic, guardian, sort: "best")
        result = builder.build

        post_numbers = result[:nested_posts].map { |n| n[:post].post_number }
        # Should be: 3 (5 likes), 4 (2 likes), 2 (0 likes), 1 (0 likes)
        # When tie at 0 likes, maintains stable sort order
        expect(post_numbers).to eq([3, 4, 2, 1])
      end

      it "ignores invalid sort values and defaults to chronological" do
        builder = described_class.new(topic, guardian, sort: "invalid")
        result = builder.build

        post_numbers = result[:nested_posts].map { |n| n[:post].post_number }
        expect(post_numbers).to eq([1, 2, 3, 4])
      end
    end
  end
end
