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
