# frozen_string_literal: true

module ::DiscourseNestedReplies
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseNestedReplies
  end
end
