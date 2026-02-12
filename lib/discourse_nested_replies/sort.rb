# frozen_string_literal: true

module DiscourseNestedReplies
  module Sort
    ALGORITHMS = %w[top new old].freeze
    DEFAULT = "top"

    def self.apply(scope, algorithm, last_level: false)
      return scope.order(created_at: :asc) if last_level

      case algorithm
      when "top"
        scope.order(like_count: :desc, post_number: :asc)
      when "new"
        scope.order(created_at: :desc)
      when "old"
        scope.order(post_number: :asc)
      else
        scope.order(like_count: :desc, post_number: :asc)
      end
    end

    def self.sort_in_memory(posts, algorithm, last_level: false)
      return posts.sort_by(&:created_at) if last_level

      case algorithm
      when "top"
        posts.sort_by { |p| [-p.like_count, p.post_number] }
      when "new"
        posts.sort_by { |p| -p.created_at.to_i }
      when "old"
        posts.sort_by(&:post_number)
      else
        posts.sort_by { |p| [-p.like_count, p.post_number] }
      end
    end

    def self.valid?(algorithm)
      ALGORITHMS.include?(algorithm)
    end
  end
end
