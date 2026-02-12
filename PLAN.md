# Reddit-Style Nested Replies Plugin for Discourse

> **Plugin name**: `discourse-nested-replies`
> **Module name**: `DiscourseNestedReplies`
> **Current status**: Phase 4 in progress (depth settings, system specs, OP badge, mobile, depth lines overhaul, infinite scroll, load-more counts complete)
> **Tree data source**: `reply_to_post_number` column (single-parent tree; `PostReply` join table is ignored)

## Context

Discourse uses a flat, chronological post stream within topics. This plugin adds an alternative Reddit-style nested/threaded view where replies are displayed as indented children under their parent comments, forming a visual tree. The goal is to provide a familiar Reddit-like UX for communities that prefer threaded discussion.

The plugin must maximize reuse of Discourse core functionality and minimize custom code. The reference plugin `discourse-threaded-view` by Falco validates the approach: a \~28-file plugin can achieve the core experience.

---

## Part 1: Reddit Comment System Features (What We Need)

### Core Features (Must-Have for v1)

| Feature | Description |
|----|----|
| **Nested tree rendering** | Comments indented under parents, depth indicators (colored vertical lines) |
| **Depth limit** | Max \~10 levels visible, “Continue this thread” link beyond that |
| **Collapse/expand** | Click depth line or toggle to collapse entire subtree |
| **Sort algorithms** | Top (like_count), New (date), Old (reverse) |
| **Scoring via likes** | Use Discourse’s existing like system for scoring — no custom voting |
| **Lazy loading** | “Load more comments” for truncated branches, children loaded on expand |
| **Comment actions** | Reply, like, share/permalink, bookmark, flag, edit, delete (reuse PostMenu) |
| **Deep linking + context view** | URL to specific comment with ancestor chain, highlighted on navigation |
| **Notification navigation** | Seamless redirect from notification URLs to nested view with context |
| **OP indicator** | Badge showing when comment author is the topic creator |
| **Flat/threaded toggle** | Switch between Discourse’s normal view and nested view |
| **Navigation control** | Separate /nested/ route + per-category & site-wide default view setting |
| **Live updates** | MessageBus-driven real-time new post insertion and indicators |

### Deferred Features (v2+)

| Feature | Description |
|----|----|
| **Best sort (Wilson score)** | Confidence-interval based sort using like ratio |
| **Q&A sort** | OP-response-prioritized sorting |
| **Keyboard navigation** | j/k to move between comments, arrow keys to navigate tree |

### Sort Algorithms (v1 Implementation)

* **Top**: `ORDER BY like_count DESC, post_number ASC` — most liked first
* **New**: `ORDER BY created_at DESC`
* **Old**: `ORDER BY post_number ASC`

---

## Part 2: What Discourse Already Provides (Reuse)

### Backend — Full Reuse

| Component | Path | What It Gives Us |
|----|----|----|
| **Post model** | `app/models/post.rb` | `reply_to_post_number`, `reply_count`, `score`, `like_count`, `sort_order`. Already has `has_many :post_replies` and `has_many :replies, through: :post_replies` |
| **PostReply join table** | `app/models/post_reply.rb` | `post_id → reply_post_id` mapping. This IS the tree structure — each row is a parent→child edge |
| **Post#reply_ids** | `app/models/post.rb:1011` | Recursive CTE query that traverses the full reply tree from any post. Already handles depth levels |
| **Index on replies** | DB index | `index_posts_on_topic_id_and_reply_to_post_number (topic_id, reply_to_post_number)` — fast lookup of children by parent |
| **PostSerializer** | `app/serializers/post_serializer.rb` | Complete post serialization: avatar, username, flair, content (cooked), actions, permissions, timestamps, etc. |
| **Guardian** | `lib/guardian.rb` | Authorization for who can see/edit/delete posts |
| **TopicView** | `lib/topic_view.rb` | Post loading pipeline, access control, preloading. Key: `filter_posts_by_ids()` preloads `user.primary_group`, `user.flair_group`, `reply_to_user`, `deleted_by`, `incoming_email`, `image_upload` (+ conditionally `localizations`, `user.user_status`). Also batch-loads user/post custom fields. Existing filters: `@replies_to_post_number`, `@filter_top_level_replies`, `@filter_upwards_post_id`, `@reply_history_for` (recursive CTE). |
| **Like system** | `app/models/post_action.rb` | Existing `like_count` on posts used for scoring |
| **MessageBus** | `lib/message_bus.rb` | Real-time publishing. Topics publish to `/topic/{id}` on post create/edit/delete. Frontend subscribes in topic controller. |
| **PreloadStore** | `frontend/discourse/app/lib/preload-store.js` | Server→client data preloading to avoid duplicate initial requests |
| **Plugin Instance API** | `lib/plugin/instance.rb` | `add_to_serializer`, `add_to_class`, `register_modifier`, Engine mounting, route registration |

### Plugin API Hooks to Leverage

These specific plugin API methods should be used throughout the implementation rather than rolling custom equivalents. Each is referenced in the relevant section of Part 3 where it’s used.

| Hook | Location in `lib/plugin/instance.rb` | How We Use It |
|----|----|----|
| **`TopicView.on_preload`** | `lib/topic_view.rb:7-20` | Registers a block that runs after TopicView loads posts (during `initialize`). We register a preload block in `plugin.rb` that batch-loads `direct_reply_count` for all posts in the current flat view. This makes the flat topic view “nested-aware” — the “View as nested” toggle link can display “N replies” badges on posts even before the user switches to nested view. The block receives the full TopicView instance, so we can access `topic_view.posts`, `topic_view.topic`, etc. See §1b for details. |
| **`topic_view_post_custom_fields_allowlister`** | `lib/plugin/instance.rb:485-491` | Registers a block that returns an array of post custom field names to batch-load during TopicView initialization. If we store any metadata as post custom fields, this ensures TopicView’s existing batch-loading pipeline (`Post.custom_fields_for_ids`) picks them up — no separate query needed. The block receives `(user, topic)` and respects `plugin.enabled?`. See §1b for details. |
| **`register_modifier(:redirect_to_correct_topic_additional_query_parameters)`** | Called via `DiscoursePluginRegistry` | When Discourse redirects topic URLs (e.g. slug correction, topic move), it strips unknown query params. This modifier lets us add `post_number` to the allowlist so `/nested/slug/123?post_number=15` survives URL canonicalization redirects. Without this, deep-link query params get dropped on redirect. See §10 for details. |
| **`add_to_serializer(:post, :attr, include_condition: ...)`** | `lib/plugin/instance.rb:180-227` | The `include_condition` keyword argument is critical — it creates an `include_#{attr}?` method that gates whether the attribute is serialized. We use this so `direct_reply_count` is only computed and included when the serializer is invoked with our custom options (not on every post serialization site-wide). See §3 for details. |
| **`PostSerializer::INSTANCE_VARS` + options hash** | `app/serializers/post_serializer.rb:5-15, 105-111` | PostSerializer’s constructor iterates `INSTANCE_VARS` and auto-sets each as an instance variable from the options hash. This means we can pass preloaded data (like a `direct_reply_counts` hash) as a serializer option and access it inside `add_to_serializer` blocks via the instance variable — no monkey-patching needed. This is the pattern Falco’s reference plugin uses. See §3 for details. |
| **`register_topic_view_posts_filter`** | `lib/plugin/instance.rb:321-323` | Registers a filter that runs on ALL TopicView post queries. We use this to annotate post queries with `direct_reply_count` data when the flat view is loaded, so the standard topic JSON response includes reply count metadata. The block receives `(posts, opts)` and can modify the scope. See §1b for details. |

### Frontend — Full Reuse

| Component | Path | What It Gives Us |
|----|----|----|
| **Post model (JS)** | `frontend/discourse/app/models/post.js` | RestModel with tracked properties, `store.createRecord("post", data)` |
| **Topic model (JS)** | `frontend/discourse/app/models/topic.js` | `loadTopicView`, PreloadStore integration |
| **PostAvatar** | `frontend/discourse/app/components/post/avatar.gjs` | Avatar rendering |
| **PostMetaData** | `frontend/discourse/app/components/post/meta-data.gjs` | Username, flair, timestamp |
| **PostCookedHtml** | `frontend/discourse/app/components/post/cooked-html.gjs` | Rendered post content |
| **PostMenu** | `frontend/discourse/app/components/post/menu.gjs` | Action buttons (like, reply, share, flag, bookmark, etc.) |
| **PostLinks** | `frontend/discourse/app/components/post/links.gjs` | Link display |
| **DButton** | `frontend/discourse/app/components/d-button.gjs` | Standard button component |
| **ajax utility** | `frontend/discourse/app/lib/ajax.js` | API calls |
| **store service** | `frontend/discourse/app/services/store.js` | Model record creation and caching |
| **Plugin outlet system** | Various templates | Injection points throughout topic/post rendering |

### Key Plugin Outlets Available

**Post component** (`frontend/discourse/app/components/post.gjs`):

* `post-article`, `post-article-content`, `post-content-cooked-html`, `post-metadata`, `post-links`

**Note**: The nested view uses its own `/nested/` route with its own template — not the topic template. The toggle button between flat/nested is part of the nested view’s own UI and a link injected into the flat topic view via a topic connector.

---

## Part 3: What Needs Custom Implementation

### Backend (Custom)

#### 1. ThreadedTopicsController (new Engine controller)

**Purpose**: Serve threaded view data — tree-structured posts with sorting/pagination.

**Endpoints**:

* `GET /nested/:slug/:topic_id` — Ember app shell for hard refreshes (serves `respond` action, no data — following chat plugin's pattern)
* `GET /nested/:slug/:topic_id/roots` — Initial load (page 0: topic metadata + OP + root posts + preloaded children tree) and pagination (page 1+: roots only)
* `GET /nested/:slug/:topic_id/children/:post_number` — Lazy-load children of a specific post
* `GET /nested/:slug/:topic_id/context/:post_number` — Ancestor chain + target + children for deep-linking

**Tree building strategy — batch breadth-first loading** (in `batch_preload_tree`):

Instead of recursive per-post queries (which caused O(posts) SQL queries), the controller uses breadth-first batch loading with **one query per depth level** — O(depth) queries total:

1. Root posts = posts WHERE `reply_to_post_number IS NULL OR reply_to_post_number = 1` (OP)
2. Breadth-first: collect all parent post_numbers at current level, fetch all children in one `WHERE reply_to_post_number IN (...)` query
3. Group results by `reply_to_post_number` in Ruby, limit to `PRELOAD_CHILDREN_PER_PARENT` (3) per parent
4. Repeat for next level up to `PRELOAD_DEPTH` (3 levels) or `MAX_DEPTH` (10)
5. Returns `{ children_map: { post_number => [child_posts] }, all_posts: [all loaded posts] }`
6. Sort roots by selected algorithm, sort children by same algorithm within each level
7. **EXCEPTION** — last nesting level (MAX_DEPTH or leaf level): always `ORDER BY created_at ASC`
   * **Rationale**: At the deepest visible level, replies cannot nest further. Sorting by "top" (like_count) would break conversation flow since reply chains appear as siblings. Chronological order preserves readability of back-and-forth exchanges.

**Constants**: `PRELOAD_DEPTH = 3`, `ROOTS_PER_PAGE = 20`, `CHILDREN_PER_PAGE = 50`, `PRELOAD_CHILDREN_PER_PARENT = 3`. Max depth is configurable via `nested_replies_max_depth` site setting (default 10, min 1, max 10).

**Key**: Reuse `PostSerializer` for all post serialization. Reuse `Guardian` for access control. Reuse `TopicView` where possible for consistent access control patterns (find_topic via Guardian).

#### 1b. Preloading Strategy (TopicView Integration)

**Problem**: Discourse’s `TopicView` is the class that handles all post preloading — eagerly loading user associations, custom fields, and serializer context. The reference plugin (`discourse-threaded-view`) skips TopicView entirely and queries `@topic.posts.where(...)` directly. This works but misses preloading that PostSerializer expects, e.g. user flair groups, custom fields, user status, link counts, post badges, etc.

**What TopicView preloads** (in `filter_posts_by_ids()`, `lib/topic_view.rb:928-944`):

```ruby
Post.where(id: post_ids, topic_id: @topic.id).includes(
  { user: %i[primary_group flair_group] },
  :reply_to_user,
  :deleted_by,
  :incoming_email,
  :image_upload,
)
# + conditionally: :localizations, { user: :user_status }
```

**Additionally**, TopicView batch-loads after post fetch:

* **User custom fields**: `User.custom_fields_for_ids(post_user_ids, allowed_fields)` — plugins register custom user fields
* **Post custom fields**: `Post.custom_fields_for_ids(post_ids, allowed_fields)` — e.g. `Post::NOTICE`, `action_code_who`
* **User badges**: Pre-fetched for rendering flair on posts
* **Link counts**: `TopicLink.counts_for` — link click counts per post
* **PostSerializer context**: `serializer.topic_view = topic_view` — gives serializer access to all preloaded data

**Chosen approach — Hybrid (use TopicView for access + extract its preloading pattern)**:

There are two distinct preloading concerns: (A) preloading for the **nested view’s own endpoints**, and (B) making the **flat view nested-aware** via plugin hooks.

##### A. Nested view endpoints (our controller)

1. **Access control**: Instantiate `TopicView` for the topic to get Guardian checks, `check_and_raise_exceptions`, topic metadata, and `message_bus_last_id`. This ensures the plugin respects all access control (private categories, deleted topics, etc.).

2. **Post loading**: Query posts directly via `@topic.posts.where(reply_to_post_number: ...)` for tree building (TopicView's flat-stream model doesn't map to tree traversal), but **replicate TopicView's `.includes()`** on our queries:

   ```ruby
   POST_INCLUDES = [
     { user: %i[primary_group flair_group] },
     :reply_to_user,
     :deleted_by,
     :incoming_email,
     :image_upload,
   ]

   def load_posts_for_tree(scope)
     scope = scope.includes(*POST_INCLUDES)
     scope = scope.includes(:localizations) if SiteSetting.content_localization_enabled
     scope = scope.includes({ user: :user_status }) if SiteSetting.enable_user_status
     scope
   end
   ```

3. **`prepare_for_serialization` — TopicView integration**: After collecting all posts for the response, we integrate with TopicView's lazy-loaded batch methods so that PostSerializer has full access to all preloaded data (post_actions, reviewable_counts, bookmarks, mentioned_users, etc.). This method:

   a. **Sets `@posts` on TopicView** to our posts wrapped in `PreloadablePostsArray` (see below)
   b. **Clears stale memoized caches** (`@all_post_actions`, `@reviewable_counts`, `@post_custom_fields`, `@user_custom_fields`, `@category_group_moderator_user_ids`, `@mentioned_users`) from the initial TopicView construction
   c. **Loads custom fields** via `TopicView.allowed_post_custom_fields` + `Post.custom_fields_for_ids` and `User.allowed_user_custom_fields` + `User.custom_fields_for_ids`
   d. **Runs `TopicView.preload`** to execute all plugin `on_preload` hooks
   e. **Preloads plugin associations** (`:post_actions`, reactions data) to avoid N+1 queries during serialization

4. **`PreloadablePostsArray`** (`lib/discourse_nested_replies/preloadable_posts_array.rb`): An Array subclass that makes `TopicView.on_preload` hooks work transparently with already-loaded post arrays. Plugins like `discourse-calendar` call `topic_view.posts.includes(:event)` and `discourse-assign` calls `topic_view.posts.pluck(:id)` — both fail on plain Arrays. `PreloadablePostsArray` intercepts:
   - `.includes(*associations)` → delegates to `ActiveRecord::Associations::Preloader`
   - `.pluck(*columns)` → translates to `map(&:column)` in Ruby

5. **Reactions batch precompute**: The `discourse-reactions` plugin's `reactions_for_post` method fires per-post COUNT queries that bypass preloaded associations. To avoid this N+1, `batch_precompute_reactions` runs a single SQL query computing adjusted likes count for ALL posts (replicating the full `reactions_for_post` logic including NOT EXISTS subqueries for excluded reactions). Results are stored on `post.precomputed_reactions` and short-circuited via a prepend on `PostSerializer` (not `ReactionsSerializerHelpers` — our plugin loads alphabetically before discourse-reactions, so that module doesn't exist at boot time). The prepend intercepts the `reactions` serializer method: if precomputed data exists, returns it directly; otherwise falls through to `super`.

6. **Serializer context**: Pass the TopicView instance AND our preloaded reply counts as options to PostSerializer. The `topic_view` gives the serializer access to badges, link counts, bookmarks, etc. The `direct_reply_counts` hash is passed as a serializer option and accessed via `PostSerializer::INSTANCE_VARS` (see §3 for how this works):

   ```ruby
   def serialize_post(post, reply_counts)
     post.topic = @topic
     serializer = PostSerializer.new(
       post,
       scope: guardian,
       root: false,
       direct_reply_counts: reply_counts,
     )
     serializer.topic_view = @topic_view
     serializer.as_json
   end
   ```

##### B. Making the flat view nested-aware (plugin hooks in plugin.rb)

The flat topic view should display nested view metadata (reply counts, toggle links) without requiring the user to navigate to `/nested/` first. We achieve this by hooking into TopicView’s existing lifecycle:

1. **`TopicView.on_preload` block** (registered in `plugin.rb`): After TopicView finishes loading posts for the flat view, our preload block batch-loads `direct_reply_count` for all visible posts. This runs inside TopicView’s `initialize` method (after `filter_posts_by_ids` completes), so we have access to `topic_view.posts`. The data is stored on the TopicView instance and picked up by our `add_to_serializer` block:

   ```ruby
   # In plugin.rb
   TopicView.on_preload do |topic_view|
     next unless SiteSetting.nested_view_enabled
     # Batch-compute direct reply counts for all loaded posts
     post_numbers = topic_view.posts.map(&:post_number)
     counts = Post
       .where(topic_id: topic_view.topic.id, deleted_at: nil)
       .where(reply_to_post_number: post_numbers)
       .group(:reply_to_post_number)
       .count
     topic_view.instance_variable_set(:@nested_view_reply_counts, counts)
   end
   ```

   This means every flat topic view response now includes reply count data at zero extra cost — it’s a single GROUP BY query that piggybacks on TopicView’s initialization.

2. **`topic_view_post_custom_fields_allowlister`** (registered in `plugin.rb`): If we ever store nested view metadata as post custom fields (e.g. thread collapse state per-staff), this hook ensures TopicView’s batch loader picks them up. The block receives `(user, topic)` so we can conditionally include fields based on user permissions:

   ```ruby
   # In plugin.rb
   topic_view_post_custom_fields_allowlister do |user, topic|
     # Only include if nested view is enabled
     SiteSetting.nested_view_enabled ? ["nested_view_metadata"] : []
   end
   ```

3. **`register_topic_view_posts_filter`** (registered in `plugin.rb`): This filter runs on ALL TopicView post queries. We don’t use it to filter posts (we want the flat view to stay flat), but we can use it to ensure the flat view’s post query joins or preloads any data the nested toggle UI needs. For v1, the `on_preload` hook above is sufficient. This filter is reserved for v2 if we need to annotate the post scope itself.

**Why not use TopicView directly for post loading?**

* TopicView’s `filter_posts_*` methods are designed around a flat, paginated stream — they return posts ordered by `sort_order ASC`
* The existing filter options (`@replies_to_post_number`, `@filter_top_level_replies`) are useful but only provide one level of filtering, not recursive tree building
* Forcing tree traversal through TopicView would require multiple TopicView instantiations or heavy subclassing
* Direct queries with replicated preloading is cleaner and is what the reference plugin validates

**Why not skip preloading like the reference plugin?**

* Missing `user.primary_group` and `user.flair_group` means no flair rendering on posts
* Missing custom fields means plugins that add post/user data won’t work
* Missing `topic_view` context on PostSerializer means `user_badges`, `link_counts`, and other computed fields are absent
* For a production plugin, we want full feature parity with the flat view’s post rendering

#### 2. Sort Algorithm Module (`lib/discourse_nested_view/sort.rb`)

**Purpose**: Define sort scopes for post ordering.

**v1 sort scopes** (applied to ActiveRecord queries):

* **Top**: `ORDER BY like_count DESC, post_number ASC`
* **New**: `ORDER BY created_at DESC`
* **Old**: `ORDER BY post_number ASC`

These are SQL-level for root posts (paginated), and in-memory for preloaded children batches.

#### 2b. Site Settings and Category Settings

**Purpose**: Control default view mode per-category and site-wide.

**Settings in `config/settings.yml`**:

* `nested_view_enabled` (boolean) — master toggle
* `nested_view_default` (boolean) — site-wide default to nested view
* `nested_view_default_sort` (enum: top/new/old) — default sort

**Category custom field**:

* `nested_view_default_for_category` (boolean) — per-category override
* Registered via `register_category_custom_field_type` and `register_preloaded_category_custom_fields`
* Serialized via `add_to_serializer(:basic_category, :nested_view_default)`

**Behavior**: When a user visits a topic, check (in priority order):

1. User’s explicit choice (stored in cookie/localStorage)
2. Category setting (`nested_view_default_for_category`)
3. Site-wide setting (`nested_view_default`)
4. Default to flat view

If nested is the default, the topic route connector auto-redirects or displays nested view. The toggle button always allows switching.

#### 3. Dedicated table: `nested_view_post_stats`

A plugin-owned table to cache nested view metadata. This keeps data isolated from core, makes uninstall clean (drop the table), and allows efficient single-query batch loads.

**Schema**:

```ruby
create_table :nested_view_post_stats do |t|
  t.integer :post_id, null: false
  t.integer :direct_reply_count, default: 0, null: false
  t.timestamps
end
add_index :nested_view_post_stats, :post_id, unique: true
```

**Model**: `NestedViewPostStat` — `belongs_to :post`

**Maintenance callbacks**:

* `after_create` on Post: if post has `reply_to_post_number`, find or create the parent’s stat row and increment `direct_reply_count`
* `after_destroy` on Post: decrement parent’s `direct_reply_count`
* `after_update` on Post (if `reply_to_post_number` changes): decrement old parent, increment new parent

**Rebuild rake task**: `rake nested_view:rebuild_stats` — truncates table, recomputes all counts from `Post.group(:topic_id, :reply_to_post_number).count`

**Usage in controller**: Batch-load stats for all visible posts in one query:

```ruby
stats = NestedViewPostStat.where(post_id: post_ids).index_by(&:post_id)
```

**Serialization** — uses two plugin API patterns together:

First, we register `direct_reply_counts` as a `PostSerializer::INSTANCE_VARS` entry via `add_to_class`. This lets callers pass a preloaded hash as a serializer option, and the constructor auto-sets it as `@direct_reply_counts` on the serializer instance:

```ruby
# In plugin.rb
add_to_class(:post_serializer, :direct_reply_counts) { @direct_reply_counts }
add_to_class(:post_serializer, "direct_reply_counts=") { |val| @direct_reply_counts = val }
PostSerializer::INSTANCE_VARS << :direct_reply_counts
```

Then, we use `add_to_serializer` with `include_condition` to gate the attribute. The condition checks whether `@direct_reply_counts` was actually passed — this means the attribute is only computed and serialized when our nested view controller (or the `on_preload` hook) explicitly provides the data. Normal post serialization site-wide is unaffected:

```ruby
# In plugin.rb
add_to_serializer(
  :post,
  :direct_reply_count,
  include_condition: -> { @direct_reply_counts.present? },
) { @direct_reply_counts&.fetch(object.post_number, 0) || 0 }
```

The controller passes the preloaded counts hash as a serializer option:

```ruby
# In nested_topics_controller.rb
counts = direct_reply_counts(all_post_numbers)
PostSerializer.new(post, scope: guardian, root: false, direct_reply_counts: counts)
```

The `on_preload` hook (§1b) provides the same data for flat view serialization:

```ruby
# TopicView.on_preload stores counts on topic_view
# add_to_serializer reads from @topic_view.instance_variable_get(:@nested_view_reply_counts)
```

This pattern — INSTANCE_VARS for data passing + include_condition for gating — is the same approach Falco’s reference plugin uses and avoids any monkey-patching.

### Frontend (Custom)

#### 4. Route Registration (`discourse-nested-view-route-map.js`)

Register `/nested/:slug/:topic_id` as an Ember route.

#### 5. Route Handler (`routes/nested.js`)

Loads and caches nested view data. See “Caching & Performance Strategy” section below for full details.

#### 6. `<NestedView>` Component (`components/nested-view.gjs`)

**Purpose**: Top-level component for the nested view page.

**Contains**:

* Topic header (title, category, tags)
* OP post rendered prominently
* Sort selector dropdown (Top/New/Old)
* Root posts list → each rendered via `<NestedPost>`
* “Load more” button for root pagination
* Link to switch back to flat view

**Reuses**: Topic model, DButton, ConditionalLoadingSpinner

#### 7. `<NestedPost>` Component (`components/nested-post.gjs`)

**Purpose**: Render a single post in the nested tree. This is the heart of the plugin.

**Contains**:

* Depth indicator (colored vertical line, clickable to collapse)
* PostAvatar, PostMetaData (reused from core)
* PostCookedHtml (reused from core)
* PostMenu (reused from core — reply, like, share, bookmark, flag, etc.)
* OP indicator badge (when author is topic creator)
* Expand/collapse toggle for children
* “Continue this thread” link when at MAX_DEPTH
* Conditional rendering of `<NestedPostChildren>` when expanded

**Key design**: This component wraps core Discourse post sub-components rather than reimplementing them. The threaded-view reference plugin already validates this approach.

#### 8. `<NestedPostChildren>` Component (`components/nested-post-children.gjs`)

**Purpose**: Render children of a post, loading via AJAX when needed.

* Preloaded children (from initial page load, up to PRELOAD_DEPTH levels) are already rendered inline — no separate “check” step needed
* For deeper levels or paginated branches: AJAX `GET /nested/:slug/:topic_id/children/:post_number` on user expand
* Renders each child as `<NestedPost>` (recursive)
* “Load more” for pagination within children
* Increments depth counter for each level
* Caches loaded children so re-collapse/expand doesn’t re-fetch

#### 9. Stylesheet (`stylesheets/common/nested-view.scss`)

* Depth indicator colored lines (cycling through \~6 colors)
* Indentation per depth level
* Collapse/expand transitions
* Compact spacing compared to Discourse’s default post spacing

#### 10. Notification Deep-Linking & Context View

**Problem**: When a user gets a “replied to your post” notification, Discourse generates a URL like `/t/slug/topic_id/post_number`. If nested view is the default for that category, clicking the notification must seamlessly navigate to the nested view and show the target comment in context — even if it’s 8 levels deep.

**Notification URL flow** (Discourse core, no changes needed):

1. Backend creates notification with `topic_id` + `post_number`
2. `Notification#url` calls `Topic#relative_url(post_number)` → `/t/slug/42/15`
3. Frontend routes to `topic.fromParamsNear` → loads posts near #15 → scrolls + highlights

**Plugin interception — automatic redirect**:

* An Ember instance-initializer watches route transitions to `topic.fromParamsNear`
* Before the flat view renders, checks: is nested view the default for this category?
  * Priority: user localStorage preference > category custom field > site setting
* If yes: `replaceWith('nested', slug, topic_id, { queryParams: { post_number: N } })`
* If no: let flat view render normally. The flat view’s toggle button still offers “View in nested view”

**Query param preservation via `register_modifier`**: Discourse’s topic URL canonicalization (slug correction, topic moves) strips unknown query params. We use `register_modifier(:redirect_to_correct_topic_additional_query_parameters)` in `plugin.rb` to add `post_number` to the allowlist. Without this, navigating to `/nested/old-slug/123?post_number=15` where the slug has changed would redirect to `/nested/new-slug/123` and lose the `?post_number=15` deep-link target:

```ruby
# In plugin.rb
register_modifier(:redirect_to_correct_topic_additional_query_parameters) do |params|
  params + %w[post_number]
end
```

**Context endpoint** (4th controller endpoint):

* `GET /nested/:slug/:topic_id/context/:post_number`
* **Server-side logic**:
  1. Find target post by `post_number` in topic
  2. Walk up `reply_to_post_number` chain to build ancestor path: `[root_reply, ..., parent]`
  3. For each ancestor, fetch sibling posts at that level (limited to 5 per level) for context
  4. Fetch target’s children (preloaded depth of 4 levels)
  5. Return: `{ topic, op_post, ancestor_chain: [...], siblings: {...}, target_post, children: {...} }`
* **Client-side**:
  1. Render OP post at top
  2. Render ancestor chain — each level shows the ancestor expanded with a “N other replies” collapse indicator for siblings
  3. Render target post highlighted (CSS animation pulse)
  4. Render target’s children below
  5. Scroll to target post after render
  6. “View full thread” link at top to navigate to the full nested view

**Context view URL format**: `/nested/slug/topic_id?post_number=15`

**Deep-link sharing**: Each post in the nested view gets a “permalink” action (via PostMenu’s share button) that copies the context URL.

#### 11. Live Updates (MessageBus Integration)

**Channel**: Subscribe to `/topic/{topicId}` — same channel Discourse core uses. No custom channel needed.

**Subscription lifecycle**:

* Subscribe in route’s `setupController` (or component `didInsertElement`)
* Unsubscribe on route deactivate / component destroy
* Use `topic.message_bus_last_id` as starting point

**Message handling by type**:

| Message Type | Action |
|----|----|
| **created** | Fetch new post via AJAX. Determine parent from `reply_to_post_number`. If parent is expanded → animate-insert child. If parent collapsed → increment `direct_reply_count` badge. If new root post → show “N new replies” indicator at top. Update `nested_view_post_stats` locally. |
| **deleted / destroyed** | Remove post from tree. Decrement parent’s `direct_reply_count`. Animate removal. |
| **recovered** | Re-insert post into tree at correct position. |
| **revised / rebaked** | Fetch updated post data. Identity map handles in-place update of cooked content. |
| **liked / unliked** | Update `like_count` on the post. If current sort is “Top”, optionally show a “sort order may have changed” indicator (don’t auto-re-sort — disorienting). |
| **read** | Update read tracking state. |

**New post insertion strategy**:

1. Receive `{ id, post_number, user_id, type: "created" }` from MessageBus
2. Fetch full post: `GET /posts/{id}.json` (Discourse core endpoint, returns PostSerializer data)
3. `store.createRecord("post", data)` — enters identity map
4. Find parent in tree via `reply_to_post_number`
5. If parent visible + expanded: insert child at correct sort position, animate in with slide-down
6. If parent visible + collapsed: just update the `direct_reply_count` badge number
7. If parent not loaded: no action (user will see it when they expand/load that branch)
8. If root post (no parent): show indicator banner “1 new reply” at top, click to load

**v2 optimization**: Buffer incoming `created` messages over 500ms and batch-fetch posts to avoid N+1 AJAX calls during rapid posting. For v1, handle each message individually (simpler, adequate for normal posting rates).

#### 12. Caching & Performance Strategy

**Server-side**:

* `nested_view_post_stats` table: pre-computed `direct_reply_count` per post — avoids N count queries
* `PostSerializer`: reused from core — benefits from all existing caching (fragment caching, etc.)
* Tree building uses indexed query `Post.where(topic_id:, reply_to_post_number:)` — fast index scan
* Pagination: 20 root posts per page, children capped at 50 per page, 3 preloaded children per parent, 3 preloaded depth levels on initial load

**Client-side data loading**:

| Scenario | Strategy |
|----|----|
| **Initial page load** | Server embeds data in HTML. Route handler consumes via `PreloadStore.getAndRemove("nested_topic_#{id}")`. One-time, then cleared. |
| **Subsequent navigation** (e.g. back button) | AJAX to `GET /nested/:slug/:topic_id`. Ember Store identity map reuses existing post records — only fetches deltas. |
| **Expand children** | Check `preloadedChildren` Map first (populated from initial load for first 3 levels, 3 children per parent). Cache miss → AJAX to `/nested/:slug/:topic_id/children/:post_number`. Cache result in `preloadedChildren` Map so re-collapse/expand doesn't re-fetch. |
| **Sort change** | Root posts: server-side re-fetch (different SQL ORDER BY, paginated). Already-expanded children: also server-side re-fetch for consistency — different sort may surface different “top 200” children. Clear `preloadedChildren` cache on sort change. |
| **Flat ↔ nested transition** | Posts in Ember Store identity map are shared. Switching to nested view from flat: posts already in store are reused (no re-fetch for those), but tree structure + additional children need fetching. |
| **Context view (deep link)** | Single AJAX to context endpoint. Returns ancestor chain + target + children. All posts enter identity map. |

**Post identity mapping**:

* All posts go through `store.createRecord("post", data)` → enters Ember Store’s WeakValueMap identity map
* Same post object referenced whether viewed in flat mode, nested mode, or context view
* WeakValueMap allows GC when post has no active references (e.g. navigated away from topic)

**Tree structure storage**:

* `preloadedChildren`: `Map<post_number, Array<Post>>` — ephemeral, built from server response
* `expandedNodes`: `Set<post_number>` — tracks which nodes are expanded
* Both are component-level state, garbage collected when leaving the nested view route
* `expandedNodes` optionally persisted to sessionStorage per topic for back/forward navigation

**Memory management for mega-topics (500+ posts)**:

* Only root posts (paginated, 20 at a time) + expanded children are in memory
* Collapsed branches hold zero child post references (only `direct_reply_count` number)
* On collapse: child post references released from tree Map (remain in WeakValueMap store for GC)
* Total in-memory posts typically bounded by: 20 roots × 3 preloaded levels × 3 children per parent ≈ ~200 posts max initial, growing only with explicit user expansion

---

## Part 4: Core Discourse Changes

**No core changes are required for v1.** The plugin API provides sufficient extension points (see Part 2 “Plugin API Hooks to Leverage”). However, the plugin must replicate some internal TopicView logic (the `.includes()` chain, custom field batch loading) because it’s not exposed as a public API. This section documents potential future core extractions that would make this — and similar plugins — cleaner.

### What works well today (no changes needed)

1. **Post sub-components are already well-extracted** — PostAvatar, PostMetaData, PostCookedHtml, PostMenu are all standalone components importable by plugins. No extraction needed.
2. **PostStream identity map pattern** — The `post-stream.js` model’s `_identityMap` and `storePost` pattern is useful but tightly coupled to PostStream’s stream-based loading. For our plugin, the Ember store service (`store.createRecord("post", data)`) provides equivalent identity mapping. No extraction needed.
3. **Plugin hooks** — `TopicView.on_preload`, `add_to_serializer` with `include_condition`, `PostSerializer::INSTANCE_VARS`, `register_modifier` for redirect params, category custom field registration — these provide everything needed without touching core.

### Potential future core extractions (for reference)

These are not blockers. They would reduce fragility if the plugin needs to stay in sync with core changes long-term.

#### A. Extract post preloading into a reusable module

**The** #1 **improvement.** Currently, `TopicView#filter_posts_by_ids` (`lib/topic_view.rb:928-944`) is the only path to properly preloaded posts. The `.includes()` chain is hardcoded inside TopicView, and the custom fields batch loading (`lib/topic_view.rb:139-145`) is buried in the constructor. Any plugin that loads posts outside TopicView must replicate this chain and keep it in sync when core adds new preloading (e.g. when `content_localization_enabled` was added).

A `PostLoader` module would let plugins call `PostLoader.load_posts(post_ids, topic:, guardian:)` and get back properly preloaded posts with all associations. TopicView itself would call this internally. This benefits any plugin that serializes posts outside the flat topic stream — Q&A views, AI summary views, activity feeds, etc.

#### B. Lightweight PostSerializer context without TopicView

PostSerializer has a `@topic_view` attr_accessor that gives it access to preloaded caches (link_counts, bookmarks, badges, post_actions, custom_fields). Without it, the serializer falls back to N+1 queries or simply omits data entirely (`include_read?` returns false, `include_link_counts?` returns false).

A `PostSerializerContext` object that carries the same preloaded data without requiring a full TopicView instance would let plugins serialize posts with full fidelity. The context would be a lightweight struct: `{ link_counts:, post_custom_fields:, user_custom_fields:, all_post_actions:, bookmarks:, post_user_badges: }`. TopicView would create one internally; plugins could create one independently from any post collection.

#### C. A `view_mode` concept on the topic route

TopicView already accepts arbitrary options via `instance_variable_set` (line 115 — any option becomes an instance variable). Adding a first-class `view_mode` parameter would allow the existing `/t/slug/123` endpoint to serve different structural representations. This wouldn’t replace the separate `/nested/` route, but would let the flat topic endpoint be aware of alternate views — useful for PreloadStore keying (`"topic_#{id}_nested"`), redirect logic, and plugin hooks that need to know which view is being requested.

### Note on reference plugin gap

Falco’s `discourse-threaded-view` queries posts via `@topic.posts.where(...)` without replicating TopicView’s preloading (`.includes()` for user associations, batch custom field loading, serializer context). This means posts in the threaded view are missing user flair, custom fields, link counts, and other data that PostSerializer expects from TopicView. Our plugin improves on this by replicating TopicView’s preloading pattern (see §1b) while still using direct tree queries. The potential core extractions above (A, B) would eliminate the need for this replication.

---

## Part 5: Plugin File Structure

```
plugins/discourse-nested-view/
├── plugin.rb                          # Plugin registration, engine mount, and all plugin API hooks:
│   #                                    - TopicView.on_preload (batch-load reply counts for flat view)
│   #                                    - topic_view_post_custom_fields_allowlister
│   #                                    - add_to_serializer(:post, :direct_reply_count) with include_condition
│   #                                    - PostSerializer::INSTANCE_VARS << :direct_reply_counts
│   #                                    - add_model_callback(:post, :after_create/destroy/update) for stats
│   #                                    - register_modifier(:redirect_to_correct_topic_additional_query_parameters)
│   #                                    - register_category_custom_field_type / register_preloaded_category_custom_fields
│   #                                    - add_to_serializer(:basic_category, :nested_view_default)
│   #                                    - post.precomputed_reactions accessor + PostSerializerReactionsPatch prepend
├── package.json                       # Node dependencies (if needed)
│
├── config/
│   ├── locales/
│   │   ├── client.en.yml              # Frontend translations (sort labels, UI text)
│   │   └── server.en.yml              # Backend translations
│   ├── routes.rb                      # Engine route definitions
│   └── settings.yml                   # Site settings (enabled, default view, default sort, max_depth)
│
├── lib/
│   ├── discourse_nested_view/
│   │   ├── engine.rb                  # Rails Engine setup
│   │   ├── preloadable_posts_array.rb # Array subclass for TopicView.on_preload hook compatibility
│   │   └── sort.rb                    # Sort algorithm scopes (Top/New/Old)
│   └── tasks/
│       └── nested_view.rake           # rake nested_view:rebuild_stats
│
├── db/
│   └── migrate/
│       └── 20260211000000_create_nested_view_post_stats.rb  # Stats cache table
│
├── app/
│   ├── models/
│   │   └── nested_view_post_stat.rb         # Stats model (belongs_to :post)
│   └── controllers/
│       └── discourse_nested_view/
│           └── nested_topics_controller.rb  # 4 endpoints: respond (app shell), roots, children, context
│
├── assets/
│   ├── javascripts/
│   │   └── discourse/
│   │       ├── discourse-nested-view-route-map.js  # Route map registration
│   │       ├── connectors/
│   │       │   └── topic-navigation/               # "View as nested" link on flat topic view
│   │       │       └── nested-view-link.gjs
│   │       ├── api-initializers/
│   │       │   └── nested-view-redirect.js         # Auto-redirect from flat→nested for default categories; blocks post-save navigation to flat view
│   │       ├── routes/
│   │       │   └── nested.js                       # Route handler (PreloadStore + AJAX + tree building)
│   │       ├── controllers/
│   │       │   └── nested.js                       # Route controller (MessageBus subscription)
│   │       └── components/
│   │           ├── nested-view.gjs                 # Top-level nested view
│   │           ├── nested-post.gjs                 # Single nested post (recursive)
│   │           ├── nested-post-children.gjs        # Lazy-loaded children container
│   │           ├── nested-context-view.gjs         # Ancestor chain + target for deep links
│   │           └── nested-sort-selector.gjs        # Sort dropdown
│   └── stylesheets/
│       └── common/
│           └── nested-view.scss                    # All styles
│
├── spec/
│   └── system/
│       ├── nested_view_spec.rb                    # System specs (17 examples)
│       └── page_objects/
│           └── pages/
│               └── nested_view.rb                 # Page object for system specs
│
└── test/                                          # JS tests deferred
```

**Total**: \~30-35 files — comparable to the reference plugin, with additions for live updates and context view.

---

## Part 6: Implementation Phases

### Phase 1: Backend Foundation

- [x] 1. **Plugin skeleton** (`plugin.rb`, engine, settings). Register all plugin API hooks in `plugin.rb`:
    * `TopicView.on_preload` block to batch-load reply counts for the flat view (§1b-B)
    * ~~`topic_view_post_custom_fields_allowlister` for any nested view custom fields~~ (deferred — no custom fields needed for v1)
    * `PostSerializer::INSTANCE_VARS << :direct_reply_counts` to enable options-based data passing
    * `add_to_serializer(:post, :direct_reply_count, include_condition: ...)` gated by `@direct_reply_counts.present?` (§3)
    * `add_to_serializer(:basic_category, :nested_view_default)` for category serialization
    * `register_modifier(:redirect_to_correct_topic_additional_query_parameters)` to preserve `?post_number` through redirects (§10)
    * `register_category_custom_field_type` + `register_preloaded_category_custom_fields` for `nested_view_default_for_category`
- [x] 2. **Stats maintenance**: `add_model_callback(:post, :after_create)`, `add_model_callback(:post, :after_destroy)` — increment/decrement `nested_view_post_stats.direct_reply_count` when posts are created or deleted. (Note: `after_update` for re-parenting deferred to v2 — rare edge case.)
- [x] 3. Create `nested_view_post_stats` migration and model
- [x] 4. Rebuild rake task (`nested_view:rebuild_stats`)
- [x] 5. **Preloading infrastructure** in controller: `load_posts_for_tree` helper replicating TopicView's `.includes()` chain (§1b-A). Instantiate TopicView for access control (`find_topic`, `check_and_raise_exceptions`, `message_bus_last_id`). `prepare_for_serialization` integrates with TopicView's lazy-loaded batch methods via `PreloadablePostsArray`. Batch-preloads plugin associations (post_actions, reactions). Pass both `topic_view` and `direct_reply_counts` hash to PostSerializer.
- [x] 6. Implement `NestedTopicsController` with 4 endpoints: respond (app shell for hard refreshes), roots (initial load + pagination), children, context
- [x] 7. Tree-building logic using breadth-first `batch_preload_tree` (one query per depth level) + `PreloadablePostsArray` for on_preload hook compatibility + `batch_precompute_reactions` for N+1-free reactions serialization
- [x] 8. Sort module: Top (`like_count`), New (`created_at`), Old (`post_number`)
- [x] 9. Context endpoint: ancestor chain walker + siblings + target children
- [x] 10. Engine routes configuration
- [x] 11. Site settings: `nested_replies_enabled`, `nested_replies_default`, `nested_replies_default_sort`, `nested_replies_max_depth`, `nested_replies_cap_nesting_depth`
- [x] 12. Category custom fields: `nested_replies_default_for_category`

### Phase 2: Frontend Core — Tree Rendering + Navigation

- [x] 1. Route registration (`discourse-nested-replies-route-map.js`)
- [x] 2. Route handler (`routes/nested.js`) — AJAX fetch + tree node processing (PreloadStore deferred to polish)
- [x] 3. Route controller (`controllers/nested.js`) — topic model, sort state, post actions (reply, edit, delete, flag, recover)
- [x] 4. `<NestedView>` component: OP + root posts + sort selector + "Load more" + flat view link
- [x] 5. `<NestedPost>` component: depth indicator, PostAvatar, PostMetaData, PostCookedHtml, PostMenu, OP badge, expand/collapse, copy link, share
- [x] 6. `<NestedPostChildren>` component: lazy-load children via AJAX, recursive rendering, "Load more" per branch
- [x] 7. `<NestedSortSelector>` component: sort buttons (Top/New/Old) with active state
- [x] 8. Thread collapsing (click depth line to collapse entire subtree)
- [x] 9. "Continue this thread" link at MAX_DEPTH (10)
- [x] 10. "View as nested" link on flat topic view via `topic-navigation` connector; "View as flat" link in nested view header
- [x] 11. Stylesheet: depth-colored vertical lines (6 cycling colors), indentation, compact spacing, transitions, mobile responsive, highlight animation

### Phase 3: Notifications, Deep-Linking, Live Updates

- [x] 1. API initializer (`api-initializers/nested-view-redirect.js`): intercepts `routeDidChange` on the router service, redirects `topic.fromParams`/`topic.fromParamsNear` to `/nested/` when nested is category/site default. Tracks `previousRouteName` to avoid re-redirecting when user explicitly chose flat view from nested. Also blocks post-save navigation to flat view by intercepting `DiscourseURL.routeTo` after `composer:saved` fires on the nested route (core's composer loses `skipJumpOnSave` when `topicModel` is null).
- [x] 2. `<NestedContextView>` component: builds ancestor chain as a nested tree (ancestor[0] wraps ancestor[1] wraps ... target), rendering via NestedPost recursion. Each ancestor has 1 preloaded child (the next in chain); users can expand to see siblings via "load more". Scroll-to-target via `schedule("afterRender")` + `requestAnimationFrame`.
- [x] 3. Context endpoint integration in route handler: `post_number` query param now has `refreshModel: true`. When present, route fetches from `/context/:post_number` instead of `/roots`. `_processContextResponse` builds the ancestor chain and returns `contextMode: true` model.
- [x] 4. Scroll-to + CSS highlight animation: NestedContextView's constructor schedules `_scrollToTarget()` after render, which finds `[data-post-number]` element, adds `nested-post--highlighted` class, and calls `scrollIntoView({ behavior: "smooth", block: "center" })`.
- [x] 5. Permalink sharing: NestedPost's `copyLink` and `share` actions now use the nested context URL (`/nested/slug/id?post_number=N`) via `getAbsoluteURL(this.nestedShareUrl)` instead of `post.shareUrl` (flat view URL).
- [x] 6. MessageBus subscription: controller subscribes to `/topic/{id}` with `messageBusLastId` as starting point. Route's `setupController` calls `subscribe()`, route's `deactivate` calls `unsubscribe()`. Uses wildcard unsubscribe (`/topic/*`) pattern from core.
- [x] 7. Live post creation: `_handleCreated` fetches post via `/posts/{id}.json`, auto-inserts user's own root posts at top of tree. Other users' root posts added to `newRootPostIds` for "N new replies" indicator. Child posts not yet inserted (visible on next expand/load).
- [x] 8. Live deletion/recovery handling: `_handlePostChanged` fetches updated post data and updates via identity map (`store.createRecord`). Post property changes (deleted_at, cooked, etc.) trigger Glimmer re-renders automatically.
- [x] 9. Live edit handling: same `_handlePostChanged` handler — `revised`/`rebaked` events fetch fresh post data, identity map updates in place.
- [x] 10. "N new replies" indicator: NestedView shows a primary button above roots when `newRootPostIds.length > 0`. Clicking `loadNewRoots` fetches each new post and prepends to `rootNodes`.

### Phase 4: Polish & Depth Control

- [x] 1. **Configurable max depth**: `nested_replies_max_depth` site setting (integer, default 10, min 1, max 10, client: true). Replaces hardcoded `MAX_DEPTH = 10`. Used in both controller (`configured_max_depth`) and frontend (`siteSettings.nested_replies_max_depth`).
- [x] 2. **"Continue this thread" fix**: When clicking "Continue this thread" at max depth, the target post renders at depth 0 with children below (fresh depth window). Uses `context` query param — `?post_number=N&context=0` gives target at depth 0, `?post_number=N` (default) gives full ancestor chain. "View parent context" DButton navigates back to ancestor view.
- [x] 3. **Cap nesting depth setting**: `nested_replies_cap_nesting_depth` (boolean, default false). When ON: `before_create` callback re-parents replies beyond max depth as siblings; visual flattening via recursive CTE (`flat_descendants_scope`) at last level; "Continue this thread" never appears. When OFF: infinite nesting allowed, "Continue this thread" shown at max depth.
- [x] 4. **System specs**: 19 passing examples in `spec/system/nested_view_spec.rb` with `spec/system/page_objects/pages/nested_view.rb` page object. Covers: basic nested view, continue-thread (cap ON/OFF), context view (full ancestors, context=0, parent context nav, full thread return), max depth setting, replying to posts (stays on nested view after replying to nested post or OP), cap nesting depth (re-parenting, no continue-thread, leaf nodes).
- [x] 5. OP indicator badge on comments by topic author
- [x] 6. Mobile-responsive layout adjustments
- [x] 7. **Depth lines overhaul**: Replaced multi-color cycling lines with single subtle `--primary-low` gray (highlights to `--tertiary` on hover, matching Reddit). Fixed gap between siblings by switching nested posts from `margin-top` to `padding-top` so depth-line `position: absolute` fills the padding area continuously. Added horizontal `::before` connector from vertical bar to post content at avatar center height (`calc(0.5em + 24px)`). Last sibling's vertical line stops at connector height (no orphan tail). Depth-line button widened from 16px to 20px for better click target.
- [x] 8. **Infinite scroll for root posts**: Replaced "Load more replies" DButton with Discourse's `<LoadMore>` component (IntersectionObserver-based sentinel). Uses `@enabled={{@hasMoreRoots}}` and `@isLoading={{@loadingMore}}` to control triggering. Removed unused `load_more_roots` locale string.
- [x] 9. **Load more children with count**: Children "load more" button now shows "N more replies" instead of generic text. `remainingCount` getter computes `directReplyCount - childNodes.length` (or `totalDescendantCount` when cap+flatten active). Locale changed to pluralized format with `load_more_children_generic` fallback.
- [ ] 10. `expandedNodes` persistence to sessionStorage per topic
- [ ] 11. Performance testing with 500+ post topics

### Phase 5: Advanced Features (v2)

1. Wilson score “Best” sort implementation
2. Keyboard navigation (j/k between comments, arrow keys for tree)
3. Accessibility (ARIA tree roles, screen reader support)
4. Buffered batch-fetch for rapid MessageBus posting

---

## Part 7: Key Architectural Decisions

| Decision | Choice | Rationale |
|----|----|----|
| **Separate route vs modify existing topic** | Separate `/nested/` route with category/site-wide defaults | Clean isolation + configurable defaults. Toggle always available. Category/site settings control which view loads first. |
| **Tree data source** | `reply_to_post_number` column + index | Already exists, already indexed, simple parent→child lookup |
| **Serialization** | Reuse `PostSerializer` | Full compatibility with all post features, plugins, and decorations |
| **Scoring system** | Likes only | Use existing `like_count` for Top sort. No custom voting system. |
| **Tree loading** | Breadth-first batch loading: one SQL query per depth level, O(depth) total | Replaced recursive per-post loading (O(posts) queries). Groups children by parent in Ruby, limits to 3 children per parent during preload. On a 10k-post topic, went from ~2600 queries to ~5-10. |
| **Depth line rendering** | Single subtle gray (`--primary-low`) with horizontal connectors, padding-based continuity | Replaced per-depth color cycling (garish). Padding instead of margin eliminates gaps between siblings. `::before` horizontal connector branches from vertical bar to avatar center. Last sibling's line terminates at connector height. Highlights to `--tertiary` on hover. |
| **Root post pagination** | Infinite scroll via Discourse's `<LoadMore>` component (IntersectionObserver) | Matches Discourse convention — no "Load more" buttons. Automatically triggers `loadMoreRoots` when sentinel enters viewport. |
| **Children loading** | Lazy on expand (AJAX) with preloaded first 3 levels, 3 children per parent. "N more replies" count shown. | Balances initial load speed vs interactivity. Cached in `preloadedChildren` Map so re-expand doesn't re-fetch. `remainingCount` computed from `directReplyCount - childNodes.length`. |
| **Sort implementation** | SQL-level for both roots and children. Last nesting level always `created_at ASC`. | Server re-fetch on sort change for consistency. Last level chronological to preserve conversation flow where replies can't nest further. |
| **TopicView integration** | `prepare_for_serialization` + `PreloadablePostsArray` | Sets `@posts` on TopicView to our loaded posts (wrapped in PreloadablePostsArray), clears stale caches, runs all plugin on_preload hooks. Ensures PostSerializer has access to all batch-loaded data (post_actions, bookmarks, reviewable_counts, etc.) without N+1 queries. |
| **Plugin N+1 mitigation** | Batch precompute reactions + preload plugin associations | discourse-reactions' per-post COUNT query replaced with single batch SQL. Plugin associations (post_actions, reactions) preloaded via `ActiveRecord::Associations::Preloader`. Results stored on `post.precomputed_reactions` and short-circuited via prepend on `PostSerializer` (not `ReactionsSerializerHelpers` — load order dependent). |
| **View toggle** | “View as nested” link via topic connector on flat view; “View as flat” link in nested view header | Each view links to the other. Nested view has its own route/template. |
| **Default view control** | Site setting + category custom field + user preference (localStorage) | Priority: user choice > category setting > site setting > flat. |
| **Notification navigation** | API initializer intercepts `topic.fromParamsNear`, redirects to `/nested/` with `?post_number=N` | Seamless — no flash of flat view. Only triggers when nested is the default for the category. User can always override via localStorage preference. |
| **Live updates** | Subscribe to existing `/topic/{id}` MessageBus channel | No custom channel needed. Same data Discourse already publishes. Buffer + batch-fetch for rapid posting. |
| **Post identity** | All views share Ember Store’s WeakValueMap identity map | Same post object in flat view, nested view, and context view. GC-friendly. No duplicated data. |
| **Reply count caching** | Dedicated `nested_view_post_stats` table | Plugin-owned, clean uninstall, single-query batch loads, maintained via Post callbacks. |
| **Configurable max depth** | `nested_replies_max_depth` site setting (default 10, min 1, max 10, client: true) | Replaces hardcoded constant. Used in controller for tree building and frontend for "Continue this thread" / reply redirect logic. |
| **Cap nesting depth** | `nested_replies_cap_nesting_depth` boolean setting (default false) | When ON: `before_create` re-parents replies beyond max depth as siblings, recursive CTE flattens descendants at last level, "Continue this thread" never shown. When OFF: infinite nesting with "Continue this thread" at max depth. |
| **"Continue this thread" navigation** | `context` query param with `context=0` for fresh depth window | Target renders at depth 0 with children below. "View parent context" DButton uses `router.transitionTo` with `context: null` to show full ancestors. `{{#each (array @contextChain) key="post.id"}}` forces component recreation on chain changes (Glimmer component reuse fix). |
| **Post preloading** | Hybrid: TopicView for access control + replicated `.includes()` for tree queries + `TopicView.on_preload` for flat view | Nested endpoints: TopicView for access control, replicated preloading for tree queries, `topic_view` passed to PostSerializer for full context. Flat view: `TopicView.on_preload` hook batch-loads reply counts so the flat view is nested-aware. `PostSerializer::INSTANCE_VARS` pattern passes preloaded data without monkey-patching. |
| **Flat view integration** | `TopicView.on_preload` + `add_to_serializer` with `include_condition` | Flat view gets reply count data piggybacked onto TopicView initialization (single GROUP BY query). `include_condition` gates serialization so `direct_reply_count` only appears when data is provided — zero overhead on non-nested serialization paths. |
| **Deep-link param preservation** | `register_modifier(:redirect_to_correct_topic_additional_query_parameters)` | Preserves `?post_number` through Discourse’s URL canonicalization redirects. Plugin API modifier — no core change needed. |

---

## Part 8: Verification

### Manual Testing Checklist

 1. Create a topic with 50+ posts forming a reply tree (various depths)
 2. Navigate to `/nested/slug/topic_id` — verify tree renders correctly
 3. Test each sort mode (Top, New, Old)
 4. Expand/collapse threads at various depths
 5. Click “Continue this thread” at max depth
 6. Test “Load more” for roots and children
 7. Test deep-link to a deeply nested comment via notification URL
 8. Verify notification redirect: set category to nested default, click notification → lands in nested view with context
 9. Test live updates: post a reply in another browser → verify it appears/updates in nested view
10. Test with 500+ post topic for performance
11. Test on mobile viewport
12. Test flat↔nested toggle preserves topic context

---

## Critical Files to Reference During Implementation

| File | Purpose |
|----|----|
| `app/models/post.rb:1011` | `reply_ids` recursive CTE — pattern for tree traversal |
| `app/models/post.rb:36-37` | `has_many :post_replies` / `has_many :replies` |
| `app/models/post.rb:222-253` | `publish_change_to_clients!` — MessageBus publishing on post create/edit/delete |
| `app/models/post_reply.rb` | PostReply join table schema |
| `app/models/notification.rb` | `url` method — generates `/t/slug/topic_id/post_number` |
| `app/models/topic.rb` | `relative_url(post_number)` — notification URL generation |
| `app/serializers/post_serializer.rb` | Full post serialization |
| `app/serializers/post_stream_serializer_mixin.rb` | How posts are serialized for topic view |
| `lib/topic_view.rb:928-944` | `filter_posts_by_ids()` — the preloading `.includes()` chain to replicate |
| `lib/topic_view.rb:106-156` | TopicView constructor — access control flow (`find_topic`, `check_and_raise_exceptions`) |
| `lib/topic_view.rb:139-145` | Custom fields batch loading pattern (`User.custom_fields_for_ids`, `Post.custom_fields_for_ids`) |
| `lib/topic_view.rb:991-1110` | `setup_filtered_posts()` — existing reply/tree filters (`@replies_to_post_number`, `@filter_upwards_post_id`) |
| `lib/topic_view.rb:952-973` | `find_post_replies_ids()` — recursive CTE for ancestor chain walking (useful for context endpoint) |
| `app/controllers/topics_controller.rb:53-93` | `show` action pattern |
| `app/controllers/topics_controller.rb:1393-1428` | `perform_show_response` + PreloadStore |
| `frontend/discourse/app/components/post.gjs` | Post component (imports to reuse) |
| `frontend/discourse/app/components/post/menu.gjs` | PostMenu component |
| `frontend/discourse/app/models/post.js` | Frontend Post model |
| `frontend/discourse/app/models/post-stream.js` | Identity map pattern, `triggerNewPostsInStream` for MessageBus handling reference |
| `frontend/discourse/app/controllers/topic.js` | MessageBus subscription pattern: `subscribe()`, `onMessage()` handler |
| `frontend/discourse/app/routes/topic/from-params.js` | Route handler with `nearPost` parameter — interception point for redirect |
| `frontend/discourse/app/lib/preload-store.js` | PreloadStore API |
| `frontend/discourse/app/lib/url.js` | `jumpToPost` — scroll + highlight utility |
| `frontend/discourse/app/lib/utilities.js` | `highlightPost` — CSS highlight animation |
| `frontend/discourse/app/services/store.js` | Ember Store with WeakValueMap identity map |
| `lib/plugin/instance.rb:180-227` | `add_to_serializer` with `include_condition` — gated attribute addition |
| `lib/plugin/instance.rb:321-323` | `register_topic_view_posts_filter` — filter hook on all TopicView post queries |
| `lib/plugin/instance.rb:485-491` | `topic_view_post_custom_fields_allowlister` — batch custom field loading |
| `lib/plugin/instance.rb:461-482` | `add_model_callback` — lifecycle hooks on Post for stats maintenance |
| `lib/topic_view.rb:7-20` | `TopicView.on_preload` — register preload blocks that run after post loading |
| `app/serializers/post_serializer.rb:5-15, 105-111` | `INSTANCE_VARS` pattern — auto-set instance vars from options hash |

