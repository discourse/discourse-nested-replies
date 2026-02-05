# frozen_string_literal: true

# name: discourse-nested-replies
# about: Provides a nested/threaded view for topic posts with 1-level reply nesting
# meta_topic_id: TODO
# version: 0.1.0
# authors: Discourse
# url: https://github.com/discourse/discourse-nested-replies
# required_version: 2.7.0

enabled_site_setting :nested_replies_enabled

register_asset "stylesheets/common/nested-replies.scss"
register_asset "stylesheets/desktop/nested-replies-desktop.scss", :desktop
register_asset "stylesheets/mobile/nested-replies-mobile.scss", :mobile

register_svg_icon "indent"
register_svg_icon "outdent"

module ::DiscourseNestedReplies
  PLUGIN_NAME = "discourse-nested-replies"
end

require_relative "lib/discourse_nested_replies/engine"

after_initialize do
  require_relative "app/controllers/discourse_nested_replies/topics_controller"
  require_relative "app/services/discourse_nested_replies/tree_builder"
  require_relative "app/serializers/discourse_nested_replies/nested_post_node_serializer"
  require_relative "app/serializers/discourse_nested_replies/nested_topic_view_serializer"

  Discourse::Application.routes.append do
    get "/t/:slug/:id/nested(.:format)" => "discourse_nested_replies/topics#show",
        :constraints => {
          id: /\d+/,
        }
    get "/t/:slug/:id/thread/:post_number(.:format)" => "discourse_nested_replies/topics#thread",
        :constraints => {
          id: /\d+/,
          post_number: /\d+/,
        }
    get "/nested-replies/posts/:post_id/replies(.:format)" =>
          "discourse_nested_replies/topics#load_more_replies",
        :constraints => {
          post_id: /\d+/,
        }
  end
end
