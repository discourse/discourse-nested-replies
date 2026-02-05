# Discourse Nested Topics Plugin - Implementation Plan

## Executive Summary

This document outlines the complete implementation plan for a Discourse plugin that adds 1-level nested reply display to topic views. The plugin will provide an alternative "nested" view that shows posts with their immediate replies indented beneath them, while maintaining all existing functionality and zero risk to core Discourse.

**Key Characteristics:**
- **Depth:** Strictly 1-level nesting (parent → children)
- **Architecture:** Separate plugin with its own route/controller
- **Compatibility:** Works alongside existing flat view
- **Performance:** Pagination on top-level posts, lazy-load deep reply threads
- **Timeline:** 8-10 weeks to production-ready

---

## Goals & Non-Goals

### Goals
- ✅ Display posts with immediate replies nested visually beneath them
- ✅ Make nested view easily accessible (toggle between flat/nested)
- ✅ Maintain all existing post functionality (like, edit, delete, reply, etc.)
- ✅ Handle pagination efficiently for large topics
- ✅ Provide clear visual hierarchy without overwhelming mobile users
- ✅ Zero impact on existing flat topic view performance or behavior

### Non-Goals
- ❌ Multi-level nesting (replies to replies shown recursively)
- ❌ Replacing the default flat view
- ❌ Modifying core PostStream component
- ❌ Supporting all existing filters (summary, search) in nested view initially
- ❌ Threaded composition UI (use existing composer)

---

## Core Architecture Decisions

### Decision 1: Handling Out-of-Window Replies

**Problem:** What happens when post #25 replies to post #5, but we're viewing page 3 (posts #41-60)?

**Decision:** **Do not render posts that reply to parents outside the current pagination window.**

**Rationale:**
- Avoids "orphaned" replies appearing as top-level
- Cleaner, less confusing UX
- Simpler implementation
- Later enhancement: Show indicator like "New replies below" when scrolling

**Implementation:**
```ruby
def build_tree(posts, current_page_post_numbers)
  # Only include posts where:
  # 1. reply_to_post_number is NULL (true top-level), OR
  # 2. reply_to_post_number exists in current_page_post_numbers

  posts.select do |post|
    post.reply_to_post_number.nil? ||
    current_page_post_numbers.include?(post.reply_to_post_number)
  end
end
```

### Decision 2: Handling Multi-Level Replies

**Problem:** Post #3 replies to post #2, post #5 replies to post #3. How do we show this?

**Decision:** **Flatten everything to 1 level under the root parent.**

**Example:**
```
Post #2 (top-level)
  ├─ Post #3 (reply to #2)
  └─ Post #5 (reply to #3, but shown as reply to #2)
```

**Rationale:**
- Maintains strict 1-level depth promise
- Prevents horizontal space issues
- Simpler to reason about and implement
- Users can still see reply-to context in post header

**Implementation:**
```ruby
def flatten_replies(post, all_posts, collected = [])
  direct_replies = all_posts.select { |p| p.reply_to_post_number == post.post_number }

  direct_replies.each do |reply|
    collected << reply
    flatten_replies(reply, all_posts, collected) # Recurse to collect grandchildren
  end

  collected.sort_by(&:created_at) # Chronological order within thread
end
```

### Decision 3: Pagination Strategy

**Decision:** **Paginate top-level posts, load ALL immediate children (flattened) for visible parents, with "Load more" if >10 replies**

**Behavior:**
- Page 1: Top-level posts #1-20, plus all their nested replies (flattened)
- If post #5 has 25 replies, initially show 10 with "Load 15 more replies" button
- Nested replies don't count toward the 20-per-page limit

**Rationale:**
- Top-level posts provide natural pagination boundaries
- Loading all children creates cohesive threads
- Limit deep threads to prevent overwhelming pages
- Maintains predictable scroll behavior

---

## Technical Architecture

### Plugin Structure

```
plugins/discourse-nested-topics/
├── plugin.rb                          # Plugin definition
├── README.md                          # Documentation
├── config/
│   ├── locales/
│   │   └── en.yml                     # Translation strings
│   └── settings.yml                   # Site settings
├── app/
│   ├── controllers/
│   │   └── discourse_nested_topics/
│   │       └── topics_controller.rb   # Nested view controller
│   ├── serializers/
│   │   └── discourse_nested_topics/
│   │       ├── nested_post_node_serializer.rb
│   │       └── nested_topic_view_serializer.rb
│   └── services/
│       └── discourse_nested_topics/
│           └── tree_builder.rb        # Core tree-building logic
├── assets/
│   ├── javascripts/
│   │   └── discourse/
│   │       ├── routes/
│   │       │   └── topic-nested.js
│   │       ├── controllers/
│   │       │   └── topic-nested.js
│   │       ├── models/
│   │       │   └── nested-post-stream.js
│   │       ├── components/
│   │       │   ├── nested-post-stream.gjs
│   │       │   ├── nested-post-node.gjs
│   │       │   ├── nested-post-reply.gjs
│   │       │   └── topic-nested-header.gjs
│   │       └── connectors/
│   │           └── topic-title/
│   │               └── nested-view-toggle.gjs
│   └── stylesheets/
│       ├── common/
│       │   └── nested-topics.scss
│       ├── mobile/
│       │   └── nested-topics-mobile.scss
│       └── desktop/
│           └── nested-topics-desktop.scss
├── lib/
│   └── discourse_nested_topics/
│       └── engine.rb
└── spec/
    ├── requests/
    │   └── topics_controller_spec.rb
    ├── services/
    │   └── tree_builder_spec.rb
    ├── serializers/
    │   └── nested_topic_view_serializer_spec.rb
    └── system/
        └── nested_topic_view_spec.rb
```

### Data Flow

```
User Request
    ↓
[GET /t/:slug/:id/nested?page=2]
    ↓
DiscourseNestedTopics::TopicsController#show
    ↓
DiscourseNestedTopics::TreeBuilder.new(topic, guardian, page: 2).build
    ↓
[Fetch posts for page 2]
[Build tree structure with flattened children]
    ↓
NestedTopicViewSerializer.new(tree_data)
    ↓
JSON Response:
{
  nested_posts: [
    {
      post: {...},
      replies: [{...}, {...}],
      total_reply_count: 15,
      loaded_reply_count: 10,
      has_more_replies: true
    }
  ],
  meta: {
    page: 2,
    per_page: 20,
    total_top_level_posts: 87,
    has_next_page: true,
    has_previous_page: true
  }
}
    ↓
Frontend: NestedPostStream model
    ↓
Template: <NestedPostStream />
    ↓
Rendered nested view
```

---

## Phase-by-Phase Implementation

## Phase 1: Backend Foundation (Weeks 1-2)

### 1.1 Plugin Scaffolding

**File:** `plugin.rb`

```ruby
# frozen_string_literal: true

# name: discourse-nested-topics
# about: Provides a nested/threaded view for topic posts with 1-level reply nesting
# version: 0.1.0
# authors: Discourse Team
# url: https://github.com/discourse/discourse-nested-topics

enabled_site_setting :nested_topics_enabled

register_asset "stylesheets/common/nested-topics.scss"
register_asset "stylesheets/desktop/nested-topics-desktop.scss", :desktop
register_asset "stylesheets/mobile/nested-topics-mobile.scss", :mobile

register_svg_icon "indent"
register_svg_icon "outdent"

after_initialize do
  module ::DiscourseNestedTopics
    PLUGIN_NAME = "discourse-nested-topics"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseNestedTopics
    end
  end

  require_relative "app/controllers/discourse_nested_topics/topics_controller"
  require_relative "app/services/discourse_nested_topics/tree_builder"
  require_relative "app/serializers/discourse_nested_topics/nested_post_node_serializer"
  require_relative "app/serializers/discourse_nested_topics/nested_topic_view_serializer"

  DiscourseNestedTopics::Engine.routes.draw do
    get "/t/:slug/:id/nested" => "topics#show", constraints: { id: /\d+/ }
  end

  Discourse::Application.routes.append do
    mount ::DiscourseNestedTopics::Engine, at: "/"
  end
end
```

### 1.2 Tree Builder Service

**File:** `app/services/discourse_nested_topics/tree_builder.rb`

```ruby
# frozen_string_literal: true

module DiscourseNestedTopics
  class TreeBuilder
    DEFAULT_CHUNK_SIZE = 20
    MAX_INITIAL_REPLIES = 10

    attr_reader :topic, :guardian, :page, :chunk_size

    def initialize(topic, guardian, opts = {})
      @topic = topic
      @guardian = guardian
      @page = [opts[:page].to_i, 1].max
      @chunk_size = opts[:chunk_size] || DEFAULT_CHUNK_SIZE
      @post_number = opts[:post_number]&.to_i # For linking to specific posts
    end

    def build
      # Load all posts for current page plus their children
      posts = load_posts

      # Build tree structure
      tree = build_tree_structure(posts)

      {
        nested_posts: tree,
        meta: build_metadata(posts)
      }
    end

    private

    def load_posts
      # Start with top-level posts for this page
      offset = (@page - 1) * @chunk_size

      # Get top-level posts (no reply_to_post_number or reply to post outside topic)
      top_level_query = @topic.posts
        .secured(@guardian)
        .where("reply_to_post_number IS NULL OR reply_to_post_number NOT IN (?)",
               @topic.posts.pluck(:post_number))
        .order(:post_number)
        .offset(offset)
        .limit(@chunk_size)

      top_level_posts = top_level_query.to_a
      top_level_post_numbers = top_level_posts.map(&:post_number)

      # If linking to specific post, ensure it's included
      if @post_number && !top_level_post_numbers.include?(@post_number)
        linked_post = @topic.posts.secured(@guardian).find_by(post_number: @post_number)
        if linked_post
          # Find its root parent
          root = find_root_parent(linked_post)
          if root && !top_level_post_numbers.include?(root.post_number)
            top_level_posts.unshift(root)
            top_level_post_numbers.unshift(root.post_number)
          end
        end
      end

      return top_level_posts if top_level_posts.empty?

      # Fetch all descendants (flattened) for visible top-level posts
      child_posts = @topic.posts
        .secured(@guardian)
        .where(
          "reply_to_post_number IN (?) OR " \
          "id IN (SELECT reply_post_id FROM post_replies WHERE post_id IN (?))",
          top_level_post_numbers,
          top_level_posts.map(&:id)
        )
        .order(:created_at)
        .to_a

      # Combine and return
      (top_level_posts + child_posts).uniq
    end

    def build_tree_structure(all_posts)
      # Separate top-level from replies
      posts_by_parent = all_posts.group_by(&:reply_to_post_number)
      top_level = posts_by_parent[nil] || []

      # Paginate top-level only
      offset = (@page - 1) * @chunk_size
      paginated_top_level = top_level[offset, @chunk_size] || []

      # Build tree nodes
      paginated_top_level.map do |post|
        replies = collect_flattened_replies(post, posts_by_parent)

        {
          post: post,
          replies: replies.take(MAX_INITIAL_REPLIES),
          total_reply_count: replies.count,
          loaded_reply_count: [replies.count, MAX_INITIAL_REPLIES].min,
          has_more_replies: replies.count > MAX_INITIAL_REPLIES,
          highlighted: @post_number && (
            post.post_number == @post_number ||
            replies.any? { |r| r.post_number == @post_number }
          )
        }
      end
    end

    def collect_flattened_replies(parent_post, posts_by_parent, collected = [], visited = Set.new)
      # Prevent infinite loops
      return collected if visited.include?(parent_post.id)
      visited.add(parent_post.id)

      # Find direct children
      direct_children = posts_by_parent[parent_post.post_number] || []

      # Add them and recurse to get grandchildren
      direct_children.each do |child|
        collected << child
        collect_flattened_replies(child, posts_by_parent, collected, visited)
      end

      # Sort by creation time to maintain chronological flow within thread
      collected.sort_by(&:created_at)
    end

    def build_metadata(posts)
      top_level_count = @topic.posts
        .secured(@guardian)
        .where("reply_to_post_number IS NULL")
        .count

      {
        page: @page,
        per_page: @chunk_size,
        total_top_level_posts: top_level_count,
        total_pages: (top_level_count.to_f / @chunk_size).ceil,
        has_next_page: @page * @chunk_size < top_level_count,
        has_previous_page: @page > 1
      }
    end

    def find_root_parent(post)
      current = post
      visited = Set.new

      while current.reply_to_post_number && !visited.include?(current.id)
        visited.add(current.id)
        parent = @topic.posts.find_by(post_number: current.reply_to_post_number)
        break unless parent
        current = parent
      end

      current
    end
  end
end
```

### 1.3 Serializers

**File:** `app/serializers/discourse_nested_topics/nested_post_node_serializer.rb`

```ruby
# frozen_string_literal: true

module DiscourseNestedTopics
  class NestedPostNodeSerializer < ApplicationSerializer
    attributes :post,
               :replies,
               :total_reply_count,
               :loaded_reply_count,
               :has_more_replies,
               :highlighted

    def post
      PostSerializer.new(object[:post], scope: scope, root: false).as_json
    end

    def replies
      object[:replies].map do |reply|
        PostSerializer.new(reply, scope: scope, root: false).as_json
      end
    end
  end
end
```

**File:** `app/serializers/discourse_nested_topics/nested_topic_view_serializer.rb`

```ruby
# frozen_string_literal: true

module DiscourseNestedTopics
  class NestedTopicViewSerializer < ApplicationSerializer
    attributes :nested_posts, :meta

    def nested_posts
      object[:nested_posts].map do |node|
        NestedPostNodeSerializer.new(node, scope: scope, root: false).as_json
      end
    end

    def meta
      object[:meta]
    end
  end
end
```

### 1.4 Controller

**File:** `app/controllers/discourse_nested_topics/topics_controller.rb`

```ruby
# frozen_string_literal: true

module DiscourseNestedTopics
  class TopicsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in, only: [:show]

    def show
      topic = Topic.find_by(id: params[:id])
      raise Discourse::NotFound unless topic

      guardian.ensure_can_see!(topic)

      page = params[:page]&.to_i || 1
      post_number = params[:post_number]&.to_i

      tree_data = TreeBuilder.new(
        topic,
        guardian,
        page: page,
        post_number: post_number
      ).build

      render json: NestedTopicViewSerializer.new(
        tree_data,
        scope: guardian,
        root: false
      )
    end
  end
end
```

### 1.5 Site Settings

**File:** `config/settings.yml`

```yaml
plugins:
  nested_topics_enabled:
    default: false
    client: true
    description: "Enable nested/threaded topic view"

  nested_topics_default_view:
    default: false
    client: true
    description: "Use nested view as default for topics"

  nested_topics_max_initial_replies:
    default: 10
    min: 5
    max: 50
    description: "Maximum number of replies to show initially before 'load more'"

  nested_topics_posts_per_page:
    default: 20
    min: 10
    max: 50
    description: "Number of top-level posts per page in nested view"

  nested_topics_show_on_categories:
    type: list
    list_type: category
    default: ""
    description: "Only show nested view toggle on these categories (empty = all)"
```

### 1.6 Translations

**File:** `config/locales/en.yml`

```yaml
en:
  site_settings:
    nested_topics_enabled: "Enable nested topics view"
    nested_topics_default_view: "Use nested view as default"
    nested_topics_max_initial_replies: "Max initial replies shown"
    nested_topics_posts_per_page: "Posts per page (nested view)"
    nested_topics_show_on_categories: "Enable nested view for categories"

  js:
    nested_topics:
      view_toggle:
        chronological: "Chronological"
        nested: "Nested Replies"
      load_more_replies:
        one: "Load 1 more reply"
        other: "Load %{count} more replies"
      reply_indicator: "Reply to"
      nested_thread_indicator: "This post has nested replies"
      page_title: "Page %{page} of %{total}"
```

---

## Phase 2: Frontend Components (Weeks 3-4)

### 2.1 Route & Controller

**File:** `assets/javascripts/discourse/routes/topic-nested.js`

```javascript
import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";

export default class TopicNestedRoute extends DiscourseRoute {
  model(params) {
    const topicId = this.modelFor("topic").id;
    const page = params.page || 1;
    const postNumber = params.post_number;

    return ajax(`/t/-/${topicId}/nested.json`, {
      data: { page, post_number: postNumber }
    }).then(data => ({
      topic: this.modelFor("topic"),
      nestedData: data,
      page: parseInt(page, 10)
    }));
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.setProperties({
      topic: model.topic,
      nestedPosts: model.nestedData.nested_posts,
      meta: model.nestedData.meta,
      currentPage: model.page
    });

    // Scroll to highlighted post if present
    this.highlightTargetPost(model.nestedData.nested_posts);
  }

  highlightTargetPost(nestedPosts) {
    const postNumber = this.paramsFor("topic-nested").post_number;
    if (!postNumber) return;

    this.scheduleOnce("afterRender", () => {
      const element = document.querySelector(
        `.nested-post[data-post-number="${postNumber}"]`
      );
      if (element) {
        element.scrollIntoView({ behavior: "smooth", block: "center" });
        element.classList.add("highlighted");
        setTimeout(() => element.classList.remove("highlighted"), 3000);
      }
    });
  }
}
```

**File:** `assets/javascripts/discourse/controllers/topic-nested.js`

```javascript
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

export default class TopicNestedController extends Controller {
  queryParams = ["page", "post_number"];

  @tracked nestedPosts;
  @tracked meta;
  @tracked currentPage = 1;
  @tracked loadingMoreReplies = {};

  @action
  async loadMoreReplies(postId) {
    this.loadingMoreReplies[postId] = true;

    try {
      const result = await ajax(`/posts/${postId}/replies.json`);

      // Update the nested post node with all replies
      const node = this.nestedPosts.find(n => n.post.id === postId);
      if (node) {
        node.replies = result.posts;
        node.loaded_reply_count = result.posts.length;
        node.has_more_replies = false;
      }
    } finally {
      delete this.loadingMoreReplies[postId];
    }
  }

  @action
  changePage(newPage) {
    this.transitionToRoute("topic-nested", this.topic, {
      queryParams: { page: newPage }
    });
  }
}
```

### 2.2 Main Component

**File:** `assets/javascripts/discourse/components/nested-post-stream.gjs`

```javascript
import Component from "@glimmer/component";
import { service } from "@ember/service";
import { action } from "@ember/object";
import NestedPostNode from "./nested-post-node";
import DButton from "discourse/components/d-button";

export default class NestedPostStream extends Component {
  <template>
    <div class="nested-post-stream">
      {{#if @meta}}
        <div class="nested-stream-header">
          <span class="nested-page-info">
            Page {{@meta.page}} of {{@meta.total_pages}}
            ({{@meta.total_top_level_posts}} top-level posts)
          </span>
        </div>
      {{/if}}

      <div class="nested-posts-container">
        {{#each @nestedPosts as |node|}}
          <NestedPostNode
            @node={{node}}
            @onLoadMoreReplies={{@onLoadMoreReplies}}
            @loadingMoreReplies={{@loadingMoreReplies}}
          />
        {{/each}}
      </div>

      {{#if @meta}}
        <div class="nested-stream-pagination">
          {{#if @meta.has_previous_page}}
            <DButton
              @action={{fn @onChangePage (sub @meta.page 1)}}
              @label="topic.previous_page"
              @icon="chevron-left"
              class="btn-default"
            />
          {{/if}}

          <span class="page-numbers">
            {{@meta.page}} / {{@meta.total_pages}}
          </span>

          {{#if @meta.has_next_page}}
            <DButton
              @action={{fn @onChangePage (add @meta.page 1)}}
              @label="topic.next_page"
              @icon="chevron-right"
              class="btn-default"
            />
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
```

### 2.3 Post Node Component

**File:** `assets/javascripts/discourse/components/nested-post-node.gjs`

```javascript
import Component from "@glimmer/component";
import Post from "discourse/components/post";
import NestedPostReply from "./nested-post-reply";
import DButton from "discourse/components/d-button";
import { htmlSafe } from "@ember/template";

export default class NestedPostNode extends Component {
  get hasMoreReplies() {
    return this.args.node.has_more_replies;
  }

  get remainingReplyCount() {
    return (
      this.args.node.total_reply_count -
      this.args.node.loaded_reply_count
    );
  }

  get isLoadingReplies() {
    return this.args.loadingMoreReplies?.[this.args.node.post.id];
  }

  <template>
    <div
      class="nested-post-node {{if @node.highlighted 'highlighted'}}"
      data-post-id={{@node.post.id}}
      data-post-number={{@node.post.post_number}}
    >
      <div class="nested-post-parent">
        <Post
          @post={{@node.post}}
          @postStream={{@postStream}}
        />
      </div>

      {{#if @node.replies}}
        <div class="nested-post-replies">
          {{#each @node.replies as |reply|}}
            <NestedPostReply @post={{reply}} />
          {{/each}}

          {{#if this.hasMoreReplies}}
            <div class="nested-load-more-replies">
              <DButton
                @action={{fn @onLoadMoreReplies @node.post.id}}
                @label="nested_topics.load_more_replies"
                @translatedLabel={{htmlSafe
                  (i18n "nested_topics.load_more_replies"
                    count=this.remainingReplyCount)
                }}
                @icon="chevron-down"
                @disabled={{this.isLoadingReplies}}
                class="btn-default"
              />
            </div>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
```

### 2.4 Reply Component

**File:** `assets/javascripts/discourse/components/nested-post-reply.gjs`

```javascript
import Component from "@glimmer/component";
import Post from "discourse/components/post";

export default class NestedPostReply extends Component {
  <template>
    <div
      class="nested-post-reply"
      data-post-id={{@post.id}}
      data-post-number={{@post.post_number}}
    >
      <div class="nested-reply-connector"></div>
      <div class="nested-reply-content">
        <Post @post={{@post}} />
      </div>
    </div>
  </template>
}
```

### 2.5 View Toggle Component

**File:** `assets/javascripts/discourse/connectors/topic-title/nested-view-toggle.gjs`

```javascript
import Component from "@glimmer/component";
import { service } from "@ember/service";
import { LinkTo } from "@ember/routing";

export default class NestedViewToggle extends Component {
  @service router;
  @service siteSettings;

  get shouldShow() {
    return this.siteSettings.nested_topics_enabled;
  }

  get isNestedView() {
    return this.router.currentRouteName === "topic-nested";
  }

  <template>
    {{#if this.shouldShow}}
      <div class="nested-view-toggle">
        <LinkTo
          @route="topic"
          @model={{@outletArgs.model}}
          class="btn-flat {{unless this.isNestedView 'active'}}"
        >
          {{i18n "nested_topics.view_toggle.chronological"}}
        </LinkTo>

        <LinkTo
          @route="topic-nested"
          @model={{@outletArgs.model}}
          class="btn-flat {{if this.isNestedView 'active'}}"
        >
          {{i18n "nested_topics.view_toggle.nested"}}
        </LinkTo>
      </div>
    {{/if}}
  </template>
}
```

---

## Phase 3: Styling (Week 5)

### 3.1 Common Styles

**File:** `assets/stylesheets/common/nested-topics.scss`

```scss
.nested-post-stream {
  max-width: 100%;

  .nested-stream-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem;
    background: var(--primary-very-low);
    border-radius: 8px;
    margin-bottom: 1rem;

    .nested-page-info {
      font-size: var(--font-down-1);
      color: var(--primary-medium);
    }
  }

  .nested-posts-container {
    display: flex;
    flex-direction: column;
    gap: 2rem;
  }

  .nested-stream-pagination {
    display: flex;
    justify-content: center;
    align-items: center;
    gap: 1rem;
    padding: 2rem 0;

    .page-numbers {
      font-size: var(--font-0);
      font-weight: 500;
    }
  }
}

.nested-post-node {
  position: relative;

  &.highlighted {
    animation: highlight-flash 3s ease-out;
  }

  .nested-post-parent {
    // Use existing post styles
  }

  .nested-post-replies {
    margin-left: 40px;
    margin-top: 1rem;
    padding-left: 20px;
    border-left: 2px solid var(--primary-low-mid);

    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .nested-load-more-replies {
    padding: 0.5rem 0;

    .btn {
      width: 100%;
      justify-content: center;
    }
  }
}

.nested-post-reply {
  position: relative;
  display: flex;
  gap: 0.5rem;

  .nested-reply-connector {
    position: absolute;
    left: -20px;
    top: 20px;
    width: 20px;
    height: 2px;
    background: var(--primary-low-mid);
  }

  .nested-reply-content {
    flex: 1;
    min-width: 0; // Allow text truncation
  }

  // Slightly reduce padding/margins for nested posts
  .topic-post {
    article {
      padding: 0.75rem;
    }
  }
}

.nested-view-toggle {
  display: flex;
  gap: 0.5rem;
  margin: 1rem 0;
  padding: 0.5rem;
  background: var(--primary-very-low);
  border-radius: 8px;

  .btn-flat {
    flex: 1;

    &.active {
      background: var(--tertiary);
      color: var(--secondary);
    }
  }
}

@keyframes highlight-flash {
  0%, 100% {
    background: transparent;
  }
  10%, 30% {
    background: var(--tertiary-low);
  }
}
```

### 3.2 Mobile Styles

**File:** `assets/stylesheets/mobile/nested-topics-mobile.scss`

```scss
.nested-post-node {
  .nested-post-replies {
    margin-left: 20px;
    padding-left: 10px;
  }
}

.nested-post-reply {
  .nested-reply-connector {
    left: -10px;
    width: 10px;
  }
}

.nested-view-toggle {
  flex-direction: column;

  .btn-flat {
    width: 100%;
  }
}
```

### 3.3 Desktop Styles

**File:** `assets/stylesheets/desktop/nested-topics-desktop.scss`

```scss
.nested-post-node {
  .nested-post-replies {
    margin-left: 50px;
    padding-left: 25px;
  }
}

.nested-view-toggle {
  display: inline-flex;
  margin-left: 1rem;
}
```

---

## Phase 4: Critical Features (Week 6)

### 4.1 Post Linking

When users navigate to `/t/topic-slug/123/45` (post #45), the nested view should:
1. Calculate which page contains post #45 (or its root parent)
2. Load that page
3. Scroll to and highlight post #45

**Implementation:** Already included in `TopicNestedRoute.model()` and `TopicNestedRoute.highlightTargetPost()`

### 4.2 Composer Integration

Ensure replying works correctly in nested view:

```javascript
// In nested-post-node.gjs or nested-post-reply.gjs
// The existing Post component handles this, but we need to ensure
// reply_to_post_number is set correctly

// No additional code needed - Post component handles this
```

### 4.3 Post Actions

All existing post actions (like, bookmark, flag, edit, delete) should work identically:
- Handled by reusing the `Post` component
- No additional work needed

### 4.4 Timeline Adjustment

The existing timeline won't work well with nested view. Options:
1. Hide timeline in nested view
2. Show simplified progress indicator

**Implementation:**

```javascript
// In connectors/topic-timeline/hide-in-nested-view.gjs
import Component from "@glimmer/component";
import { service } from "@ember/service";

export default class HideInNestedView extends Component {
  @service router;

  get shouldHide() {
    return this.router.currentRouteName === "topic-nested";
  }

  <template>
    {{#if this.shouldHide}}
      <style>
        .timeline-container { display: none; }
      </style>
    {{/if}}
  </template>
}
```

---

## Phase 5: Testing & Polish (Weeks 7-8)

### 5.1 Backend Tests

**File:** `spec/requests/topics_controller_spec.rb`

```ruby
# frozen_string_literal: true

require "rails_helper"

describe DiscourseNestedTopics::TopicsController do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:post1) { Fabricate(:post, topic: topic, post_number: 1) }
  fab!(:post2) { Fabricate(:post, topic: topic, post_number: 2) }
  fab!(:post3) { Fabricate(:post, topic: topic, post_number: 3, reply_to_post_number: 2) }
  fab!(:post4) { Fabricate(:post, topic: topic, post_number: 4, reply_to_post_number: 2) }

  before { SiteSetting.nested_topics_enabled = true }

  describe "#show" do
    it "returns nested structure for topic" do
      sign_in(user)

      get "/t/-/#{topic.id}/nested.json"

      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["nested_posts"].length).to eq(2) # post1 and post2

      post2_node = json["nested_posts"].find { |n| n["post"]["post_number"] == 2 }
      expect(post2_node["replies"].length).to eq(2)
      expect(post2_node["total_reply_count"]).to eq(2)
    end

    it "paginates top-level posts" do
      sign_in(user)

      # Create 25 top-level posts
      25.times { Fabricate(:post, topic: topic) }

      get "/t/-/#{topic.id}/nested.json", params: { page: 2 }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["meta"]["page"]).to eq(2)
      expect(json["meta"]["has_previous_page"]).to eq(true)
    end

    it "flattens multi-level replies" do
      sign_in(user)

      post5 = Fabricate(:post, topic: topic, post_number: 5, reply_to_post_number: 3)

      get "/t/-/#{topic.id}/nested.json"

      json = response.parsed_body
      post2_node = json["nested_posts"].find { |n| n["post"]["post_number"] == 2 }

      # Should include post3, post4, and post5 (flattened)
      expect(post2_node["replies"].length).to eq(3)
      expect(post2_node["replies"].map { |r| r["post_number"] }).to include(3, 4, 5)
    end
  end
end
```

**File:** `spec/services/tree_builder_spec.rb`

```ruby
# frozen_string_literal: true

require "rails_helper"

describe DiscourseNestedTopics::TreeBuilder do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
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

      all_posts = result[:nested_posts].flat_map do |node|
        [node[:post]] + node[:replies]
      end

      expect(all_posts).not_to include(private_post)
    end
  end
end
```

### 5.2 System Tests

**File:** `spec/system/nested_topic_view_spec.rb`

```ruby
# frozen_string_literal: true

require "rails_helper"

describe "Nested topic view", type: :system do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:post1) { Fabricate(:post, topic: topic, post_number: 1, raw: "Original post") }
  fab!(:post2) { Fabricate(:post, topic: topic, post_number: 2, raw: "Top level post") }
  fab!(:post3) do
    Fabricate(:post, topic: topic, post_number: 3, reply_to_post_number: 2, raw: "Reply to post 2")
  end

  before do
    SiteSetting.nested_topics_enabled = true
    sign_in(user)
  end

  it "displays posts in nested structure" do
    visit "/t/-/#{topic.id}/nested"

    expect(page).to have_css(".nested-post-node", count: 2)
    expect(page).to have_css(".nested-post-reply", count: 1)

    within(".nested-post-node:nth-child(2)") do
      expect(page).to have_text("Top level post")

      within(".nested-post-replies") do
        expect(page).to have_text("Reply to post 2")
      end
    end
  end

  it "allows toggling between chronological and nested views" do
    visit "/t/-/#{topic.id}"

    click_button "Nested Replies"

    expect(current_path).to eq("/t/-/#{topic.id}/nested")
    expect(page).to have_css(".nested-post-replies")

    click_button "Chronological"

    expect(current_path).to eq("/t/-/#{topic.id}")
    expect(page).not_to have_css(".nested-post-replies")
  end

  it "loads more replies when clicking button" do
    15.times do |i|
      Fabricate(:post, topic: topic, reply_to_post_number: 2, raw: "Reply #{i}")
    end

    visit "/t/-/#{topic.id}/nested"

    within(".nested-post-node:nth-child(2)") do
      expect(page).to have_css(".nested-post-reply", count: 10)
      expect(page).to have_button("Load 6 more replies")

      click_button "Load 6 more replies"

      expect(page).to have_css(".nested-post-reply", count: 16)
      expect(page).not_to have_button("Load more replies")
    end
  end
end
```

### 5.3 Performance Testing

Create a performance test with large topic:

```ruby
# spec/performance/nested_view_performance_spec.rb
require "rails_helper"
require "benchmark"

describe "Nested view performance" do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }

  before { SiteSetting.nested_topics_enabled = true }

  it "handles topics with 1000+ posts efficiently" do
    # Create 100 top-level posts, each with 10 replies
    100.times do |i|
      parent = Fabricate(:post, topic: topic)
      10.times { Fabricate(:post, topic: topic, reply_to_post_number: parent.post_number) }
    end

    guardian = Guardian.new(user)

    time = Benchmark.realtime do
      builder = DiscourseNestedTopics::TreeBuilder.new(topic, guardian, page: 1)
      builder.build
    end

    expect(time).to be < 1.0 # Should complete in under 1 second
  end
end
```

### 5.4 Optimization Checklist

- [ ] Add database index: `posts(reply_to_post_number)` if not exists
- [ ] Cache tree structure per page (Redis, 5 min TTL)
- [ ] Eager load user data to avoid N+1 queries
- [ ] Add fragment caching for individual post nodes
- [ ] Implement virtual scrolling if pages get too large
- [ ] Add loading states for async operations
- [ ] Optimize reply counting queries

---

## Critical Gotchas & Solutions

### Gotcha #1: Orphaned Replies in Pagination

**Problem:** Post #50 replies to post #5, but we're viewing page 3 (posts #41-60).

**Solution:** Don't render post #50. It won't appear in the nested view on page 3.

**Future Enhancement:** Add indicator at top of page: "Some posts on this page are replies to earlier posts. [Jump to parent]"

### Gotcha #2: Post Number Gaps

**Problem:** User sees posts #1, #2, #7, #12 because #3-6 and #8-11 are nested.

**Solution:** Clearly show post numbers on each post. Consider adding visual indicator: "Posts #3-6 are replies to this post ↓"

### Gotcha #3: Circular References

**Problem:** Database has post #2 replying to #3, and post #3 replying to #2 (shouldn't happen but could).

**Solution:** Track visited posts in `collect_flattened_replies()` to prevent infinite loops (already implemented).

### Gotcha #4: Timeline Confusion

**Problem:** Existing timeline shows linear progress, but nested view is non-linear.

**Solution:** Hide timeline in nested view, or replace with simplified "Page X of Y" indicator.

### Gotcha #5: Mobile Horizontal Space

**Problem:** 40px indentation on 375px screen leaves little room for content.

**Solution:** Reduce indentation on mobile (20px), use visual connector line instead of heavy padding.

### Gotcha #6: Mega-Topics (10k+ posts)

**Problem:** Loading all replies for a post with 1000+ replies crashes browser.

**Solution:** Already handled via `MAX_INITIAL_REPLIES` limit (10) with "Load more" button.

### Gotcha #7: Search Results & Filters

**Problem:** Search results or filters expect flat stream.

**Solution:** Phase 1: Show message "Filters not available in nested view, switch to chronological". Phase 2: Build filter support into tree builder.

### Gotcha #8: Deleted Posts

**Problem:** Post #5 replies to deleted post #3. Where does it appear?

**Solution:** Treat as top-level post (since parent doesn't exist in secured post set).

### Gotcha #9: Draft Replies

**Problem:** User is composing reply to post #5, switches to nested view. What happens to draft?

**Solution:** Drafts are topic-scoped, not view-scoped. Draft persists across view switches. No action needed.

### Gotcha #10: Bookmarks & Notifications

**Problem:** User bookmarks post #25, gets notification. Clicks notification. Post #25 is nested on page 2.

**Solution:** Already handled by `post_number` parameter in route. Will load correct page and highlight post #25.

---

## Performance Considerations

### Database Queries

**Current Implementation:**
- 1 query for top-level posts (paginated)
- 1 query for all child posts (filtered by parent IDs)
- Total: 2 queries per page load

**Optimization:**
- Add index on `reply_to_post_number`
- Use `includes(:user)` to preload user data
- Fragment cache individual post HTML

### Memory Usage

**Worst Case:**
- Page with 20 top-level posts
- Each has 50 replies
- Total: 1020 posts loaded
- ~1-2 MB per page load

**Mitigation:**
- `MAX_INITIAL_REPLIES` limits initial load
- Lazy-load deep threads
- Virtual scrolling for very large pages (future enhancement)

### Caching Strategy

```ruby
def build
  cache_key = "nested_topic:#{@topic.id}:page:#{@page}:v1"

  Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
    # ... build tree logic
  end
end
```

**Cache Invalidation:**
- New post created → invalidate all pages after parent's page
- Post edited → invalidate page containing that post
- Post deleted → invalidate page containing that post

---

## Future Enhancements (Post-MVP)

### Phase 2 Features

1. **Collapse/Expand Threads**
   - Click to collapse entire reply tree
   - Persist collapsed state in localStorage
   - Show summary: "5 replies (collapsed)"

2. **Sort Options**
   - Chronological (default)
   - Most likes first
   - Most replies first

3. **Filter Support**
   - User posts filter (show only posts by specific user + context)
   - Summary mode (show only top-level posts)
   - Search results in nested view

4. **Nested Composer**
   - Show reply chain in composer
   - Visual indicator of nesting level
   - Preview nested position before posting

5. **Keyboard Navigation**
   - `j/k` to move between top-level posts
   - `h/l` to expand/collapse reply trees
   - `o` to open highlighted post

6. **Thread Indicators**
   - "Hot thread" badge for posts with many recent replies
   - "Deep thread" indicator when posts have nested replies
   - Unread count per thread

7. **Mobile Gestures**
   - Swipe right to collapse thread
   - Swipe left to expand
   - Long-press for thread actions

8. **Analytics**
   - Track nested vs flat view usage
   - Measure engagement in nested threads
   - A/B test different UX approaches

### Advanced Features

1. **Full Multi-Level Nesting**
   - Expand to Reddit-style unlimited depth
   - Collapse at any level
   - "Continue this thread →" for deep nesting

2. **Live Updates**
   - MessageBus integration for real-time replies
   - Animate new replies sliding in
   - Notification badge on collapsed threads with new posts

3. **AI-Powered Threading**
   - Automatically suggest reply relationships
   - Fix misthreaded posts
   - Group related posts into threads

---

## Migration & Rollout Strategy

### Phase 1: Internal Testing (Week 9)
- Enable on staging environment
- Test with team members
- Gather feedback on UX
- Performance testing with production data clone

### Phase 2: Beta Launch (Week 10)
- Enable for specific categories via site setting
- Announce in meta topic
- Monitor error logs and performance metrics
- Iterate on feedback

### Phase 3: Gradual Rollout (Week 11-12)
- Expand to more categories
- Add to more sites
- Monitor engagement metrics
- Prepare documentation

### Phase 4: General Availability (Week 13+)
- Make available to all sites
- Write comprehensive guide
- Create video tutorial
- Add to plugin marketplace

---

## Success Metrics

### Engagement Metrics
- Time spent in nested view vs flat view
- Reply rate in nested threads
- Return visitor rate
- Pages per session

### Performance Metrics
- Page load time (target: <1s)
- Time to interactive (target: <2s)
- Server response time (target: <200ms)
- Error rate (target: <0.1%)

### User Satisfaction
- User feedback in meta topics
- Support ticket volume
- Feature adoption rate
- View toggle usage

---

## Resources & References

### Discourse Core Files
- `/lib/topic_view.rb` - Topic loading logic
- `/app/models/post.rb` - Post model with reply relationships
- `/app/models/post_reply.rb` - Reply junction table
- `/frontend/discourse/app/models/post-stream.js` - Client-side stream model
- `/frontend/discourse/app/components/post.gjs` - Post component
- `/plugins/chat/` - Example of threading system

### External References
- Reddit threading system
- HackerNews nested comments
- Discourse Meta: Threaded discussions

### Related Site Settings
- `max_reply_history` - Existing setting for reply depth
- `enable_filtered_replies_view` - Existing reply filtering
- `posts_per_page` - Pagination reference

---

## Open Questions

1. **Should nested view be available for private messages?**
   - Likely yes, using same architecture
   - Needs separate consideration for UX

2. **How do we handle very wide topics (100+ direct replies to one post)?**
   - Current: Show 10, load more
   - Alternative: Pagination within threads?

3. **Should there be a preference to default to nested view?**
   - User preference setting?
   - Category default?
   - Site-wide default?

4. **How do suggested topics work in nested view?**
   - Show at bottom like flat view?
   - Hide completely?

5. **Should print view use nested layout?**
   - Likely no - flat is better for printing
   - Or add print-specific CSS

---

## Appendix: Example Data Structures

### Server Response Format

```json
{
  "nested_posts": [
    {
      "post": {
        "id": 123,
        "post_number": 1,
        "cooked": "<p>Original post</p>",
        "user": {...},
        "created_at": "2024-01-01T00:00:00Z",
        ...
      },
      "replies": [],
      "total_reply_count": 0,
      "loaded_reply_count": 0,
      "has_more_replies": false,
      "highlighted": false
    },
    {
      "post": {
        "id": 124,
        "post_number": 2,
        "cooked": "<p>Another post</p>",
        ...
      },
      "replies": [
        {
          "id": 125,
          "post_number": 3,
          "reply_to_post_number": 2,
          "cooked": "<p>Reply to post 2</p>",
          ...
        },
        {
          "id": 127,
          "post_number": 5,
          "reply_to_post_number": 3,
          "cooked": "<p>Reply to post 3, shown under post 2</p>",
          ...
        }
      ],
      "total_reply_count": 2,
      "loaded_reply_count": 2,
      "has_more_replies": false,
      "highlighted": false
    }
  ],
  "meta": {
    "page": 1,
    "per_page": 20,
    "total_top_level_posts": 45,
    "total_pages": 3,
    "has_next_page": true,
    "has_previous_page": false
  }
}
```

### Client-Side State

```javascript
{
  topic: Topic, // Existing topic model
  nestedPosts: [
    {
      post: Post, // Existing post model
      replies: [Post, Post],
      totalReplyCount: 2,
      loadedReplyCount: 2,
      hasMoreReplies: false,
      highlighted: false
    }
  ],
  meta: {
    page: 1,
    perPage: 20,
    totalTopLevelPosts: 45,
    totalPages: 3,
    hasNextPage: true,
    hasPreviousPage: false
  }
}
```

---

## Document Version

- **Version:** 1.0
- **Last Updated:** 2024-01-XX
- **Author:** Implementation Team
- **Status:** Ready for Implementation

---

## Next Steps

1. Review this plan with team
2. Create new repository: `discourse-nested-topics`
3. Set up plugin scaffolding
4. Begin Phase 1: Backend Foundation
5. Schedule weekly check-ins to track progress
6. Update this document as decisions are made

---

**Questions or feedback? Discuss in the implementation thread.**
