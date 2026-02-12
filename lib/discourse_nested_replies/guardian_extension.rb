# frozen_string_literal: true

module DiscourseNestedReplies::GuardianExtension
  def is_in_edit_post_groups?
    return false if anonymous?
    super
  end

  def is_in_edit_topic_groups?
    return false if anonymous?
    super
  end
end
