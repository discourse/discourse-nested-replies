# Design: Fix Max Depth Button & Make Cap Setting Non-Destructive

## Problem Statement

Two issues with how nesting depth is handled:

### Issue 1: Spurious "X replies" button at max depth (cap OFF)

When `nested_replies_max_depth` is reached and `cap_nesting_depth` is OFF, the "Continue this thread" link correctly appears. However, the PostMenu's reply count toggle button ("6 replies") also shows. Clicking it does nothing because the `atMaxDepth` guard prevents rendering children:

```gjs
// nested-post.gjs:349 — children never render at max depth
{{#if (and this.expanded (not this.collapsed) (not this.atMaxDepth))}}
  <NestedPostChildren ... />
{{/if}}
```

The toggle button calls `toggleExpanded` but since children can't render, it's a no-op. The button should be hidden when at max depth so "Continue this thread" is the only option.

### Issue 2: `nested_replies_cap_nesting_depth` destructively modifies data

When enabled, this setting adds a `before_create` callback (`plugin.rb:126-150`) that **permanently re-parents** posts on save by rewriting `reply_to_post_number`:

```ruby
# plugin.rb:149
self.reply_to_post_number = parent_reply_to if depth > max_depth && parent_reply_to.present?
```

Problems with this approach:
- **Data loss**: The original reply relationship is permanently destroyed
- **Irreversible**: If `max_depth` is later increased, re-parented posts stay at their incorrect depth forever
- **Setting coupling**: Changing `max_depth` after posts exist creates inconsistent trees (some posts re-parented at old depth, new posts at new depth)
- **Unnecessary**: The server/frontend already has display-time flattening logic — no need to modify data at write time

The intended behavior of `cap_nesting_depth` is correct: when ON, replies beyond max depth are flattened inline (no "Continue this thread"). The problem is purely that it achieves this by mutating data on save instead of only flattening at display time.

## Desired Behavior (two modes)

| | Cap OFF | Cap ON |
|---|---------|--------|
| At max depth | "Continue this thread" link (navigate to new context) | Replies flattened inline at max depth |
| Data on save | `reply_to_post_number` preserved | `reply_to_post_number` preserved |
| "X replies" button | Hidden (no-op) | Hidden (children rendered flat instead) |

## Proposed Solution

Two independent changes:

### Fix 1: Hide reply toggle button at max depth (Issue 1)

Don't pass `@toggleReplies` / `@repliesShown` to PostMenu when the post is at max depth. This prevents the dead "X replies" button from appearing. Applies regardless of cap setting — when cap is OFF, "Continue this thread" is the action; when cap is ON, children are rendered flat by the existing flattening logic.

In `nested-post.gjs` (lines 334-335), change:

```gjs
// BEFORE:
@toggleReplies={{this.toggleExpanded}}
@repliesShown={{this.expanded}}

// AFTER:
@toggleReplies={{unless this.atMaxDepth this.toggleExpanded}}
@repliesShown={{unless this.atMaxDepth this.expanded}}
```

**Files:** `assets/.../components/nested-post.gjs` only.

### Fix 2: Remove destructive data modification from cap setting (Issue 2)

Keep `nested_replies_cap_nesting_depth` as a setting. Keep the existing server-side flattening (`flat_descendants_scope`) and frontend flatten logic — they already work correctly for display-time flattening. Only remove the `before_create` callback that rewrites `reply_to_post_number`.

#### Server Changes

##### 1. Remove the `before_create` callback (`plugin.rb:126-150`)

Delete the entire depth-cap re-parenting block. Posts should always store their true `reply_to_post_number`. The display-time flattening in the `children` endpoint already handles the visual flattening correctly.

##### 2. Keep everything else

- `nested_replies_cap_nesting_depth` setting stays in `config/settings.yml`
- `flat_descendants_scope` in `TreeLoader` stays — it's used by the `children` endpoint when cap is ON
- The flatten check in `nested_topics_controller.rb:91` stays:
  ```ruby
  flatten = SiteSetting.nested_replies_cap_nesting_depth && depth >= loader.configured_max_depth
  ```

#### Frontend Changes

##### Remove reply re-parenting logic in `nested.js:134-142`

Since the server no longer re-parents on save, the frontend shouldn't redirect the reply target either. When cap is ON and a user replies to a post at max depth, the reply should target the actual post. The server stores the true `reply_to_post_number`, and display-time flattening handles the visual presentation.

```js
// REMOVE this block from nested.js:
if (
  this.siteSettings.nested_replies_cap_nesting_depth &&
  typeof depth === "number" &&
  depth >= this.siteSettings.nested_replies_max_depth
) {
  replyTarget = post.reply_to_post || post;
}
```

Everything else in the frontend stays — the flatten checks in `nested-post.gjs` (`showContinueThread`) and `nested-post-children.gjs` (constructor, `remainingCount`) are correct for gating behavior on the cap setting.

### Migration / Cleanup

- No data migration needed — previously re-parented posts will display at their (now incorrect) stored depth, which is acceptable since display-time flattening handles presentation
- No setting removal needed — `nested_replies_cap_nesting_depth` stays

## Summary of Files to Change

| File | Change |
|------|--------|
| `assets/.../components/nested-post.gjs` | Don't pass `@toggleReplies`/`@repliesShown` at max depth |
| `assets/.../controllers/nested.js` | Remove reply re-parenting block (lines 134-142) |
| `plugin.rb` | Remove `before_create` callback (lines 122-150) |
| Tests | Update specs that test the `before_create` re-parenting behavior |
