# frozen_string_literal: true

module ::DiscourseNestedReplies
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseNestedReplies
    config.autoload_paths << File.join(config.root, "lib")
  end
end
