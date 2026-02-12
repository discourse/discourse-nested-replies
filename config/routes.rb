# frozen_string_literal: true

DiscourseNestedReplies::Engine.routes.draw do
  get "/" => "nested_topics#respond"
  get "/roots" => "nested_topics#roots"
  get "/children/:post_number" => "nested_topics#children"
  get "/context/:post_number" => "nested_topics#context"
end

Discourse::Application.routes.draw do
  mount ::DiscourseNestedReplies::Engine, at: "/nested/:slug/:topic_id"
end
