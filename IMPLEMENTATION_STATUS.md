# Nested Replies Implementation Status

## What's Working ✅

### Backend
- **Tree builder service**: Successfully builds nested post structure with pagination
- **Complete stream generation**: Backend now returns all post IDs in nested order for the `stream` array
- **Metadata**: Returns `total_posts`, `total_top_level_posts`, `has_next_page`, etc.
- **Endpoint**: `/t/:id/nested.json` returns paginated nested post data

### Frontend
- **Display mode toggle**: "Chronological" / "Nested Replies" buttons appear and switch modes
- **Nested view rendering**: Posts display in nested structure with replies indented
- **Post enrichment**: Fixed `Post.munge()` call to properly enrich `actions_summary` data
- **Stream population**: Now correctly populates the complete `stream` array (all post IDs) instead of just first page
- **Infinite scroll**: WORKS! Scrolling to bottom loads next page of top-level posts
  - LoadMore component properly wired up
  - `loadMoreNested()` method properly bound to component context
  - Progress indicator updates correctly (e.g., "2 / 25" → "2 / 26" after loading more)

### Tests
- **System tests created**: `spec/system/nested_view_spec.rb` with page object
- **Core tests passing**: View toggle, nested rendering, infinite scroll all pass

## Critical Bugs 🐛

### 1. Reply Buttons Missing on All Posts
**Status**: BROKEN - Real bug, not test issue

**Symptom**:
- No reply buttons visible on any posts in nested view
- Looking for `.post-action-menu__reply` selector returns 0 matches

**Investigation Needed**:
- Check if `actions_summary` data is being properly passed to Post component
- Verify Post component is receiving correct props in nested context
- Check if CSS/styling is hiding the buttons
- Compare chronological view (working) vs nested view (broken)

**Files to Check**:
- `plugins/discourse-nested-replies/assets/javascripts/discourse/components/nested-post-node.gjs` (lines 27-29) - How Post component is invoked
- `frontend/discourse/app/components/post.gjs` - Post component rendering logic
- `frontend/discourse/app/models/post.js:800-815` - `actionsSummary` getter

**Previous Fix Context**:
- We fixed `Post.munge()` being called in `initializers/extend-post-stream.js:110-114`
- This enriches `actions_summary` with `actionType` objects
- But reply buttons still don't render - likely a different issue

### 2. Small Action Posts Rendered as Regular Posts
**Status**: BROKEN - Display inconsistency

**Symptom**:
- Posts with `post_type: 3` (small_action) render as full posts with avatar, content, etc.
- Should render as compact timeline entries (e.g., "Topic renamed from X to Y")

**Example**:
```
Expected: [icon] Topic was closed by @user
Actual:   [avatar] user1
          Topic was closed
```

**Investigation Needed**:
- Check if `post_type` is being passed to Post component
- Verify Post component checks `post_type` before rendering
- May need special handling in nested-post-node.gjs

**Files to Check**:
- `plugins/discourse-nested-replies/assets/javascripts/discourse/components/nested-post-node.gjs`
- `frontend/discourse/app/components/post.gjs` - Small action rendering logic
- `app/services/discourse_nested_replies/tree_builder.rb` - Check if small_action posts should be filtered out

### 3. Topic Timeline Incompatibility
**Status**: NEEDS DESIGN DECISION

**Issue**:
- Traditional timeline shows linear post progression: "Post 5 of 114"
- Nested view breaks this: posts aren't in linear order
- Current timeline still shows linear progress, which is confusing

**Options**:

**A. Hide Timeline in Nested Mode**
- Simplest solution
- Pros: No confusion, clean slate
- Cons: Lose navigation feature

**B. Adapt Timeline to Nested Structure**
- Show "Top-level post X of Y"
- Pros: Preserves navigation
- Cons: More complex, less clear what "position" means

**C. Flatten for Timeline Calculation**
- Use the complete `stream` array (already built) for progress
- Timeline shows "Post X of 114" based on depth-first traversal order
- Pros: Closest to existing behavior
- Cons: "Post 50" might be a deeply nested reply, not intuitive

**Recommendation**: Option A for MVP - hide timeline in nested mode
- Add CSS rule: `.nested-post-stream-active .timeline-container { display: none; }`
- Revisit after user feedback

## Recent Fixes Applied

### Fixed: Stream Array Population
**Problem**: Timeline showed "1 / 22" instead of "1 / 114"
- Only populating `stream` with first page posts (~22)
- Progress tracking and infinite scroll depend on complete stream

**Solution**:
1. Backend: Added `build_complete_stream()` method in `tree_builder.rb`
   - Loads ALL posts in topic
   - Orders them in nested structure (depth-first traversal)
   - Returns complete array of post IDs
2. Frontend: Updated `loadNested()` in `extend-post-stream.js:70-76`
   - Uses `data.stream` from backend instead of building from `convertedNodes`
3. Result: Timeline now shows correct total (e.g., "1 / 114")

### Fixed: Infinite Scroll
**Problem**: LoadMore component not triggering

**Solutions**:
1. Fixed method binding: Created `loadMoreTopLevelPosts()` action in wrapper component
2. Stream population: Complete stream enables proper `canLoadMoreNested` calculation
3. Result: Scrolling to bottom now loads next 20 top-level posts

## Code Structure

### Key Files

**Backend**:
- `app/controllers/discourse_nested_replies/topics_controller.rb` - Endpoint handler
- `app/services/discourse_nested_replies/tree_builder.rb` - Core tree building logic
- `app/serializers/discourse_nested_replies/nested_topic_view_serializer.rb` - JSON response

**Frontend - Initializer**:
- `assets/javascripts/discourse/initializers/extend-post-stream.js` - Post-stream model extensions
  - `loadNested()` - Fetch nested data from backend
  - `loadMoreNested()` - Infinite scroll handler
  - `canLoadMoreNested` - Computed property for pagination
  - `_convertNestedData()` - Convert JSON to Post models with `Post.munge()`

**Frontend - Components**:
- `connectors/topic-title/nested-view-toggle.gjs` - Toggle buttons
- `connectors/topic-post-stream/nested-post-stream-wrapper.gjs` - Outlet connector, switches rendering
- `components/nested-post-stream.gjs` - Container with LoadMore
- `components/nested-post-node.gjs` - Individual post + replies
- `components/nested-post-reply.gjs` - Reply rendering

**Tests**:
- `spec/system/nested_view_spec.rb` - System tests
- `spec/system/page_objects/pages/nested_topic.rb` - Page object

## Next Steps

### Priority 1: Fix Reply Buttons
1. Debug why reply buttons don't render
2. Compare Post component props between chronological and nested views
3. Check if actions are being hidden by CSS or not rendered at all

### Priority 2: Fix Small Action Rendering
1. Identify small_action posts in test data
2. Add conditional rendering in nested-post-node.gjs
3. Or filter them out in tree_builder.rb

### Priority 3: Timeline Decision
1. Decide on approach (recommend: hide for MVP)
2. Implement solution
3. Document for users

### Priority 4: Testing
1. Fix remaining system test (reply buttons)
2. Add test for small_action posts
3. Add test for timeline behavior

## Testing Commands

```bash
# Run all nested view system tests
bin/rspec plugins/discourse-nested-replies/spec/system/nested_view_spec.rb

# Run specific test
bin/rspec plugins/discourse-nested-replies/spec/system/nested_view_spec.rb:55

# Run with specific seed
bin/rspec plugins/discourse-nested-replies/spec/system/nested_view_spec.rb --seed 12345
```

## Known Limitations

1. **MAX_INITIAL_REPLIES = 10**: Each top-level post only loads first 10 replies initially
2. **DEFAULT_CHUNK_SIZE = 20**: Pagination loads 20 top-level posts per page
3. **No deep nesting**: Only 1 level of nesting (top-level post + direct replies flattened)
4. **No reply threading**: Replies to replies are shown at same level as direct replies
