# Maintenance & Core Coupling

Status of all identified coupling points between `discourse-nested-replies` and
Core internals.

---

## Resolved

### TopicView post-set replacement

Previously the plugin manually cleared 6 named TopicView instance variables to
re-seat the post collection. Now uses `TopicView#reset_posts!` — a Core API
added in this branch that owns the full list of memoized ivars to clear.

### DiscourseURL.routeTo monkey-patch

Previously replaced `DiscourseURL.routeTo` with a wrapper function (load-order
fragile, conflict-prone). Now uses the `route-to-url` value transformer added
to Core in this branch. The transformer also supports returning `null` to
suppress navigation (used after composer save to stay on the nested route).

The `session.topicList` dependency was also removed — category lookup now uses
`topicTrackingState` exclusively, which is more reliable.

### session.topicList dependency

Eliminated as part of the `route-to-url` migration above.

### `PostSerializer::INSTANCE_VARS` mutation

Previously mutated `PostSerializer::INSTANCE_VARS` and used `add_to_class`
getter/setter calls to pass `direct_reply_counts` as a serializer constructor
option. Now the `add_to_serializer` block reads directly from `@topic_view`,
which the `TopicView.on_preload` hook already populates with counts. No Core
constant mutation, no `add_to_class` calls needed.

### `PostSerializer.prepend` lost on reload

The `PostSerializer.prepend(PostSerializerReactionsPatch)` call was not wrapped
in `reloadable_patch`. In dev mode, when Zeitwerk reloads `PostSerializer`
(autoloaded from `app/serializers/`), the prepend was lost, causing the
per-post N+1 COUNT queries to return. Now wrapped in `reloadable_patch` so the
batch precompute short-circuit survives reloads.

---

## Remaining

### 2. `discourse-reactions` cross-plugin coupling — Medium risk

~90 lines of conditional code that replicate discourse-reactions' internal SQL
for batch reaction precomputation. The `PostSerializer.prepend` that
short-circuits the per-post `reactions` method is now correctly wrapped in
`reloadable_patch` (see Resolved above), but the replicated SQL remains a
maintenance concern.

**Fix options**:
- **Benchmark the N+1 cost** (~80 posts per page). If <50ms overhead, drop the
  batch optimization entirely — removes ~90 LOC and the prepend.
- **Request a batch preload API** from discourse-reactions so this plugin
  doesn't need to replicate its SQL.
- **Test whether `TopicView.on_preload` + `reset_posts!`** lets the
  discourse-reactions preload hook handle things naturally via the
  `PreloadablePostsArray` shim.

### 3. Hardcoded Ember route names — Low risk

The `routeWillChange` fallback checks `topic.fromParams` and
`topic.fromParamsNear` by name. Breaks if Core renames these routes.

Mitigated by CI. Could be eliminated if the `route-to-url` transformer alone
proves sufficient for all navigation paths (the fallback covers direct URL
entry where `routeTo` isn't called).

### 4. Core Ember component surface area — Acceptable

Uses 12+ Core components (`PostMenu`, `PostCookedHtml`, `PostAvatar`, etc.).
This is the correct approach — reimplementing them would be worse. Risk is
mitigated by system specs (see Test Coverage below), `core_features_spec.rb`
smoke test, and CI against Core HEAD.

---

## Test Coverage

System tests are organized by feature area in `spec/system/`:

| File | Covers |
|---|---|
| `nested_view_spec.rb` | Core rendering, OP display, empty state, sorting, expand/collapse via depth line, flat view toggle, direct URL routing, anonymous access, plugin-disabled 404 |
| `nested_context_view_spec.rb` | Ancestor chain display, target post highlighting, context=0 (no ancestors), navigation flows (context→parent→root), replying in context view |
| `nested_depth_spec.rb` | Max depth enforcement, "Continue this thread" (cap on/off), cap nesting re-parenting (model + UI depth verification) |
| `nested_replying_spec.rb` | Reply to post, reply to OP, reply to collapsed post (auto-expand), reply to leaf post (children appear) |
| `core_features_spec.rb` | Shared Discourse smoke test (login, likes, profile, topics, search, reply) |

Shared helper `create_reply_chain` lives in `spec/support/nested_replies_helpers.rb`.
Page object in `spec/system/page_objects/pages/nested_view.rb`.

### Not yet covered

- Backend unit tests (controller, Sort module, PreloadablePostsArray, stat callbacks)
- JavaScript unit tests (route, controller, redirect initializer)
- Message bus real-time updates (created/revised/deleted posts)
- Pagination (load more roots, load more children)
- Post deletion/editing within nested view
- Mobile/responsive behavior

---

## Summary

| Coupling point | Status | Risk |
|---|---|---|
| TopicView ivar manipulation | **Resolved** — uses `reset_posts!` | - |
| `DiscourseURL.routeTo` monkey-patch | **Resolved** — uses `route-to-url` transformer | - |
| `session.topicList` dependency | **Resolved** — uses `topicTrackingState` | - |
| `PostSerializer::INSTANCE_VARS` mutation | **Resolved** — uses `add_to_serializer` reading from `@topic_view` | - |
| `PostSerializer.prepend` lost on reload | **Resolved** — uses `reloadable_patch` | - |
| discourse-reactions SQL replication | Open | Medium |
| Hardcoded Ember route names | Open | Low |
| Core component imports | Acceptable | Low |
