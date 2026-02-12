# frozen_string_literal: true

desc "Rebuild nested view post stats (direct_reply_count + total_descendant_count) from scratch"
task "nested_view:rebuild_stats" => :environment do
  puts "Truncating nested_view_post_stats..."
  NestedViewPostStat.delete_all

  puts "Loading reply tree..."
  # Fetch all non-deleted posts grouped by topic, with their reply structure
  posts_by_topic =
    Post
      .where(deleted_at: nil)
      .where(post_type: [Post.types[:regular], Post.types[:moderator_action]])
      .pluck(:id, :topic_id, :post_number, :reply_to_post_number)
      .group_by { |_, topic_id, _, _| topic_id }

  stats = {} # post_id => { direct: N, total: N }

  puts "Computing counts for #{posts_by_topic.size} topics..."
  posts_by_topic.each do |_topic_id, topic_posts|
    # Build lookup structures
    id_by_number = {}
    children_of = Hash.new { |h, k| h[k] = [] }

    topic_posts.each do |post_id, _, post_number, reply_to|
      id_by_number[post_number] = post_id
      children_of[reply_to] << post_number if reply_to.present?
    end

    # Direct reply counts: just count immediate children
    children_of.each do |parent_number, child_numbers|
      parent_id = id_by_number[parent_number]
      next unless parent_id
      stats[parent_id] ||= { direct: 0, total: 0 }
      stats[parent_id][:direct] = child_numbers.size
    end

    # Total descendant counts: DFS with memoization
    memo = {}
    count_descendants = ->(post_number) do
      return memo[post_number] if memo.key?(post_number)
      total = 0
      children_of[post_number].each { |child| total += 1 + count_descendants.call(child) }
      memo[post_number] = total
    end

    topic_posts.each do |post_id, _, post_number, _|
      total = count_descendants.call(post_number)
      next if total == 0
      stats[post_id] ||= { direct: 0, total: 0 }
      stats[post_id][:total] = total
    end
  end

  puts "Inserting #{stats.size} stat rows..."
  now = Time.current
  stats.each_slice(1000) do |batch|
    rows =
      batch.map do |post_id, counts|
        {
          post_id: post_id,
          direct_reply_count: counts[:direct],
          total_descendant_count: counts[:total],
          created_at: now,
          updated_at: now,
        }
      end
    NestedViewPostStat.insert_all(rows)
  end

  puts "Done. #{stats.size} posts with replies indexed."
end

desc "Seed a topic with ~10,000 randomly nested posts for performance testing"
task "nested_view:seed_topic" => :environment do
  post_count = ENV.fetch("POST_COUNT", 10_000).to_i
  max_root_ratio = 0.15
  max_reply_depth_bias = 0.6

  RateLimiter.disable

  users = User.real.where("id > 0").order("RANDOM()").limit(50).to_a
  if users.size < 2
    puts "Need at least 2 real users in the database. Aborting."
    exit 1
  end

  puts "Using #{users.size} random users"

  author = users.sample
  topic_title =
    "Nested View Performance Test - #{post_count} posts (#{Time.now.strftime("%Y-%m-%d %H:%M")})"

  puts "Creating topic as #{author.username}..."

  post_creator =
    PostCreator.new(
      author,
      title: topic_title,
      raw:
        "This topic was auto-generated to test nested view performance with #{post_count} nested posts.\n\nLorem ipsum dolor sit amet, consectetur adipiscing elit.",
      skip_validations: true,
    )

  first_post = post_creator.create!
  topic = first_post.topic

  puts "Created topic ##{topic.id}: #{topic.title}"
  puts "URL: /t/#{topic.slug}/#{topic.id}"
  puts ""

  post_numbers = [1]

  sentences = [
    "I think this is a really interesting point worth discussing further.",
    "Has anyone else experienced this? I'd love to hear more perspectives.",
    "Great observation! I hadn't considered that angle before.",
    "I disagree with the premise here, let me explain why.",
    "This reminds me of something I read recently about a similar topic.",
    "Can you elaborate on what you mean by that?",
    "I've been thinking about this for a while and here's my take.",
    "That's a fair point, but I think there's more nuance to it.",
    "Interesting thread! Following along to see where this goes.",
    "I have some experience with this - here's what worked for me.",
    "This is exactly right. Well said.",
    "I'm not sure I agree, but I appreciate the thoughtful response.",
    "Adding some context that might be helpful for the discussion.",
    "Good question! I think the answer depends on several factors.",
    "Let me play devil's advocate here for a moment.",
    "This changed my mind about the original topic. Thanks for sharing.",
    "I wonder if there's a middle ground between these two positions.",
    "Has this been discussed before? I feel like I've seen similar debates.",
    "Strong point. I'd add that we should also consider the practical implications.",
    "I respectfully disagree. Here's my reasoning.",
  ]

  random_raw = ->(sents) do
    paragraph_count = rand(1..3)
    paragraphs = paragraph_count.times.map { sents.sample(rand(1..3)).join(" ") }
    paragraphs.join("\n\n")
  end

  puts "Creating #{post_count} posts..."

  start_time = Time.now
  created = 0
  errors = 0

  post_count.times do |i|
    user = users.sample

    reply_to =
      if post_numbers.size == 1 || rand < max_root_ratio
        1
      elsif rand < max_reply_depth_bias
        window = [post_numbers.size, 20].min
        post_numbers.last(window).sample
      else
        post_numbers.sample
      end

    raw = random_raw.call(sentences)

    begin
      post =
        Post.new(
          topic_id: topic.id,
          user_id: user.id,
          raw: raw,
          cooked: PrettyText.cook(raw),
          post_number: i + 2,
          reply_to_post_number: reply_to,
          post_type: Post.types[:regular],
          created_at: Time.now - rand(0..72_000).seconds,
        )
      post.save!(validate: false)

      post_numbers << post.post_number
      created += 1
    rescue => e
      errors += 1
      STDERR.puts "  Error on post #{i + 2}: #{e.message}" if errors <= 10
    end

    if (i + 1) % 500 == 0
      elapsed = Time.now - start_time
      rate = (i + 1) / elapsed
      puts "  #{i + 1}/#{post_count} posts (#{rate.round(0)}/sec, #{errors} errors)"
    end
  end

  topic.update_columns(
    posts_count: topic.posts.count,
    last_posted_at: topic.posts.order(:created_at).last&.created_at,
    bumped_at: Time.now,
    highest_post_number: topic.posts.maximum(:post_number),
  )

  elapsed = Time.now - start_time

  puts ""
  puts "Done! Created #{created} posts in #{elapsed.round(1)}s (#{(created / elapsed).round(0)}/sec)"
  puts "Errors: #{errors}" if errors > 0
  puts ""
  puts "Topic URL: /t/#{topic.slug}/#{topic.id}"

  root_count =
    topic
      .posts
      .where("post_number > 1")
      .where("reply_to_post_number IS NULL OR reply_to_post_number = 1")
      .count

  max_depth_query = <<~SQL
    WITH RECURSIVE thread_depth AS (
      SELECT post_number, reply_to_post_number, 0 AS depth
      FROM posts
      WHERE topic_id = #{topic.id}
        AND (reply_to_post_number IS NULL OR reply_to_post_number = 1)
        AND post_number > 1
      UNION ALL
      SELECT p.post_number, p.reply_to_post_number, td.depth + 1
      FROM posts p
      JOIN thread_depth td ON p.reply_to_post_number = td.post_number
      WHERE p.topic_id = #{topic.id}
    )
    SELECT MAX(depth) AS max_depth, AVG(depth) AS avg_depth FROM thread_depth
  SQL

  stats = ActiveRecord::Base.connection.select_one(max_depth_query)

  puts ""
  puts "Nesting stats:"
  puts "  Root posts: #{root_count}"
  puts "  Max depth: #{stats["max_depth"]}"
  puts "  Avg depth: #{stats["avg_depth"]&.round(1)}"

  RateLimiter.enable
end
