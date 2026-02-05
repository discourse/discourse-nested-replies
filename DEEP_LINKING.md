# Deep Linking Implementation - Thread View

## Overview

This implementation adds deep linking functionality to the nested-replies plugin. When a user copies a link to any post while in nested mode, they get a dedicated "thread view" that shows only the specific conversation thread.

## User Experience

### Link Generation
- When in **nested mode**: Copy link button generates `/t/:slug/:id/thread/:post_number`
- When in **chronological mode**: Copy link works as normal (`/t/:slug/:id/:post_number`)

### Thread View
When clicking a thread link, users see:
- **Only the relevant conversation**: Top-level parent post + all its nested replies
- **Highlighted post**: The specific post that was linked is visually highlighted
- **Pagination**: Load more replies if the thread has many responses
- **Navigation**: "View Full Topic" button to return to the complete topic

### Example Flow
1. User browses topic with posts #1, #2 (reply to #1), #3 (reply to #2), #4 (top-level), #5 (reply to #4)
2. User is in nested mode and copies link to post #3
3. Link generated: `/t/my-topic/123/thread/3`
4. Clicking the link shows:
   - Post #1 (root parent)
   - Post #2 (reply to #1)
   - Post #3 (reply to #2, **highlighted**)
   - Any other replies to the #1 thread
5. Does NOT show posts #4 or #5 (different thread)

## Technical Implementation

### Backend Changes

#### New Route
**File**: `plugin.rb`
```ruby
get "/t/:slug/:id/thread/:post_number(.:format)" =>
  "discourse_nested_replies/topics#thread"
```

#### New Controller Action
**File**: `app/controllers/discourse_nested_replies/topics_controller.rb`

**Action**: `thread`
- Finds the post by post_number
- Walks up the reply chain to find root parent
- Builds tree for just that one thread
- Returns data in same format as nested view
- Marks the specific post as `highlighted: true`

**Helper Methods**:
- `find_root_parent(post, topic)`: Recursively finds top-level parent
- `build_single_thread(root_post, topic, highlight_post_number)`: Builds thread with pagination

**Pagination**:
- Uses `nested_replies_max_initial_replies` for initial load
- Uses `nested_replies_load_more_count` for "load more" increments
- Reuses existing `load_more_replies` endpoint

### Frontend Changes

#### Route Mapping
**File**: `assets/javascripts/discourse/discourse-nested-replies-route-map.js`
```javascript
this.route("thread", { path: "/thread/:post_number" });
```

#### Route Handler
**File**: `assets/javascripts/discourse/routes/topic-thread.js`
- Fetches thread data from backend
- Converts JSON to Post models
- Passes to controller/template

#### Controller
**File**: `assets/javascripts/discourse/controllers/topic-thread.js`
- Manages thread state
- Handles "load more replies" action
- Provides "view full topic" navigation

#### Template
**File**: `assets/javascripts/discourse/templates/topic-thread.gjs`
- Displays thread view header with context
- Reuses `NestedPostStream` component
- Shows "View Full Topic" button

#### Copy Link Extension
**File**: `assets/javascripts/discourse/initializers/extend-post-share-link.js`
- Extends Post model's `shareUrl` property
- Generates thread URLs when `postStream.isNestedMode === true`
- Falls back to default for chronological mode

### Styling

**File**: `assets/stylesheets/common/nested-replies.scss`

Added:
- `.nested-thread-view` styles
- `.thread-view-header` with border and background
- Highlight animation already existed and works for thread view

### Translations

**File**: `config/locales/client.en.yml`

Added:
```yaml
thread_view:
  viewing_thread: "Viewing Thread"
  post_number: "Post #%{number}"
  view_full_topic: "View Full Topic"
```

## Edge Cases Handled

### Backend
- ✅ **Post doesn't exist**: Returns 404 NotFound
- ✅ **Post is deleted/hidden**: Uses `secured(guardian)` scope
- ✅ **Permissions**: Checks `guardian.ensure_can_see!`
- ✅ **Post is top-level**: `find_root_parent` returns itself
- ✅ **Deep nesting**: `collect_all_replies` recursively flattens all descendants
- ✅ **Invalid post_number**: Raises NotFound

### Frontend
- ✅ **Pagination**: Loads more replies with proper offset tracking
- ✅ **Highlighting**: Backend marks posts, frontend applies CSS class
- ✅ **Navigation**: Clear path back to full topic
- ✅ **Component reuse**: Uses existing nested-post-stream component

## Files Modified

### Backend
- `plugin.rb` - Added thread route
- `app/controllers/discourse_nested_replies/topics_controller.rb` - Added thread action and helpers

### Frontend
- `assets/javascripts/discourse/discourse-nested-replies-route-map.js` - Added thread route
- `assets/javascripts/discourse/routes/topic-thread.js` - New file
- `assets/javascripts/discourse/controllers/topic-thread.js` - New file
- `assets/javascripts/discourse/templates/topic-thread.gjs` - New file
- `assets/javascripts/discourse/initializers/extend-post-share-link.js` - New file

### Styling & Translations
- `assets/stylesheets/common/nested-replies.scss` - Added thread view styles
- `config/locales/client.en.yml` - Added thread view translations

## Testing Checklist

- [ ] Copy link in nested mode generates thread URL
- [ ] Copy link in chronological mode generates normal URL
- [ ] Thread view shows only the specific conversation thread
- [ ] Highlighted post is visually marked
- [ ] "Load more replies" works in thread view
- [ ] "View Full Topic" button navigates correctly
- [ ] Direct thread URL navigation works
- [ ] Thread view for top-level post shows just that post + replies
- [ ] Thread view for nested reply shows root parent + all siblings
- [ ] Permissions are respected (hidden/deleted posts don't show)
- [ ] 404 for non-existent post numbers
- [ ] Mobile layout looks good

## Future Enhancements

Potential improvements:
- Add breadcrumb showing post position in full topic
- "View in context" button to scroll to post in full nested view
- Thread view URL sharing on social media (OpenGraph meta tags)
- Thread view for chronological mode (not just nested mode)
- Collapse/expand thread branches
- Mini-map showing thread structure
