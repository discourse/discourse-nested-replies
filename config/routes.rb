# frozen_string_literal: true

DiscourseNestedReplies::Engine.routes.draw do
  scope "/nested/:slug/:topic_id", constraints: { topic_id: /\d+/ } do
    get "/" => "nested_topics#respond"
    get "/roots" => "nested_topics#roots"
    get "/children/:post_number" => "nested_topics#children"
    get "/context/:post_number" => "nested_topics#context"
    put "/pin" => "nested_topics#pin"
  end
end

Discourse::Application.routes.draw { mount ::DiscourseNestedReplies::Engine, at: "/" }
