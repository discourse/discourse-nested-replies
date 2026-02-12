# Infinite Nesting & "Continue This Thread" Plan

## Status: COMPLETE

All parts implemented, tested, and passing (17/17 system specs).

---

## What was built

### A. Fix "Continue This Thread" — target becomes depth 0 ✅

When clicking "Continue this thread", the target post renders at **depth 0** with its children below, giving a fresh depth window. No ancestor chain wrapping.

**Query param**: `context` controls ancestor depth.

| URL | Behavior | Use Case |
|-----|----------|----------|
| `?post_number=N` | Full ancestor chain (default) | Notifications, share links, deep-links |
| `?post_number=N&context=0` | Target at depth 0, no ancestors | "Continue this thread" |

**Files changed:**
- `nested_topics_controller.rb` — `context` param in context endpoint; skips ancestor chain & siblings when `context=0`
- `routes/nested.js` — `context` query param with `refreshModel: true`; passes to API URL
- `controllers/nested.js` — `viewFullThread` and `viewParentContext` actions using `router.transitionTo` to properly reset sticky query params
- `components/nested-post.gjs` — `contextUrl` includes `&context=0`
- `components/nested-context-view.gjs` — "View parent context" DButton when `@contextNoAncestors`; uses `{{#each (array ...) key="post.id"}}` to force component recreation on chain changes
- `templates/nested.gjs` — passes `@viewFullThread`, `@viewParentContext`, `@contextNoAncestors` to context view
- `config/locales/client.en.yml` — `view_parent_context` string

### B. Configurable max depth via `nested_replies_max_depth` ✅

Replaced hardcoded `MAX_DEPTH = 10` with a site setting (integer, default 10, min 1, max 10, client: true).

**Files changed:**
- `config/settings.yml` — `nested_replies_max_depth` setting
- `config/locales/server.en.yml` — setting description
- `nested_topics_controller.rb` — `configured_max_depth` method reads site setting
- `components/nested-post.gjs` — uses `siteSettings.nested_replies_max_depth`
- `controllers/nested.js` — uses `siteSettings.nested_replies_max_depth`

### C. Site setting: `nested_replies_cap_nesting_depth` ✅

Controls whether reply chains can grow beyond max depth in the data.

| Setting | Behavior |
|---------|----------|
| `false` (default) | Infinite nesting allowed. "Continue this thread" appears at max depth. |
| `true` | Replies at max depth are re-parented as siblings. "Continue this thread" never appears. Visual flattening of legacy deep threads at last level. |

**Re-parenting**: `before_create` callback walks up the reply chain counting hops. When `hops > max_depth`, sets `reply_to_post_number` to the parent's parent.

**Visual flattening**: When cap is ON and at max depth, the children endpoint uses a recursive CTE (`flat_descendants_scope`) to collect ALL descendants and return them as flat leaf nodes.

**Files changed:**
- `config/settings.yml` — `nested_replies_cap_nesting_depth` setting
- `config/locales/server.en.yml` — setting description
- `plugin.rb` — `before_create` re-parenting callback; `after_create`/`after_destroy` stats maintenance
- `nested_topics_controller.rb` — `flat_descendants_scope` with recursive CTE; flattened children endpoint
- `components/nested-post.gjs` — `showContinueThread` getter (false when cap ON); passes `@totalDescendantCount`
- `components/nested-post-children.gjs` — uses `totalDescendantCount` for hasMore when flattening
- `controllers/nested.js` — depth-aware `replyToPost` (redirects to parent at max depth)

### D. System specs ✅

17 examples, 0 failures.

**Files created:**
- `spec/system/page_objects/pages/nested_view.rb` — page object with visit, assertion, and action methods
- `spec/system/nested_view_spec.rb` — covers:
  - Basic nested view rendering
  - "Continue this thread" (cap ON/OFF)
  - Context view (full ancestors, context=0, parent context navigation, full thread return)
  - Max depth setting behavior
  - Cap nesting depth (re-parenting, no continue-thread, leaf nodes)

---

## Bugs found and fixed during testing

1. **Off-by-one in re-parenting**: Callback counts hops (= visual_depth + 1). Changed `depth >= max_depth` → `depth > max_depth` with loop guard `max_depth + 2`.

2. **Ember sticky query params**: "View parent context" `<a>` tag didn't clear the `context=0` param. Fixed by using `DButton` with controller actions that call `router.transitionTo` with explicit `context: null`.

3. **Glimmer component reuse**: When navigating from `context=0` to full ancestor view, `NestedPostChildren` constructor only ran once, showing stale children. Fixed with `{{#each (array @contextChain) key="post.id"}}` to force component recreation.

---

## Interaction matrix

| Setting | Post at max depth | Reply button | "Continue this thread" |
|---------|-------------------|--------------|----------------------|
| Cap OFF | Shows normally | Replies to this post (child) | Shown — links to `?post_number=N&context=0` |
| Cap ON | Shows normally | Replies to PARENT (sibling) | Never shown — chains can't exceed max depth |
