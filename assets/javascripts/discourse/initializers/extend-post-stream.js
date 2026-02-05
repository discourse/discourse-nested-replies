import { computed } from "@ember/object";
import { equal } from "@ember/object/computed";
import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";
import Post from "discourse/models/post";

export default {
  name: "extend-post-stream-for-nested",

  initialize() {
    withPluginApi((api) => {
      api.modifyClass("model:post-stream", {
        pluginId: "discourse-nested-replies",

        // Initialize nested mode properties
        init() {
          this._super(...arguments);
          this.displayMode = null; // 'chronological' | 'nested'
          this.nestedData = null; // { nested_posts: [...], meta: {...} }
          this.nestedCurrentPage = 1; // Pagination for nested mode
          this.loadingNested = false; // Loading state
          this.hideTimeline = false; // Flag to hide timeline (checked by Core)
          this.nestedSort = "chronological"; // 'chronological' | 'new' | 'best'
        },

        // Computed: Is this a nested mode stream?
        isNestedMode: equal("displayMode", "nested"),

        // New Method: Load nested structure
        async loadNested(opts = {}) {
          if (this.loadingNested) {
            return;
          }

          this.setProperties({
            loadingNested: true,
            loadingMore: opts.loadMore || false,
          });

          try {
            const page = opts.page || this.nestedCurrentPage;
            const sort = opts.sort || this.nestedSort;
            const data = await ajax(`/t/-/${this.topic.id}/nested.json`, {
              data: { page, post_number: opts.post_number, sort },
            });

            // Convert JSON to Post models
            const convertedNodes = this._convertNestedData(data.nested_posts);

            if (opts.loadMore) {
              // Append to existing data by creating a new object
              this.set("nestedData", {
                nested_posts: [
                  ...this.nestedData.nested_posts,
                  ...convertedNodes,
                ],
                meta: data.meta,
              });
            } else {
              // Replace data
              this.set("nestedData", {
                nested_posts: convertedNodes,
                meta: data.meta,
              });
            }

            this.set("nestedCurrentPage", page);

            // Mark stream as loaded so topic header renders
            if (!opts.loadMore) {
              this.set("loaded", true);

              // Use the complete stream from backend (contains ALL post IDs in nested order)
              if (data.stream) {
                this.stream.splice(0, this.stream.length, ...data.stream);
              }

              // Add first post to posts array so firstPostPresent returns true
              if (convertedNodes.length > 0) {
                const firstNode = convertedNodes.find(
                  (node) => node.post.post_number === 1
                );
                if (firstNode) {
                  this.posts.splice(0, this.posts.length, firstNode.post);
                }
              }
            }

            return this.nestedData;
          } finally {
            this.setProperties({
              loadingNested: false,
              loadingMore: false,
            });
          }
        },

        // Helper: Convert nested JSON to Post models
        _convertNestedData(nestedPosts) {
          return nestedPosts.map((node) => ({
            ...node,
            post: this._getOrCreatePost(node.post),
            replies: node.replies.map((reply) => this._getOrCreatePost(reply)),
          }));
        },

        // Helper: Get existing post from identity map or create new one
        _getOrCreatePost(postData) {
          // Munge the data to enrich actions_summary before creating the post
          const mungedData = Post.munge({
            ...postData,
            topic: this.topic,
          });

          const existingPost = this._identityMap[postData.id];
          if (existingPost) {
            existingPost.setProperties(mungedData);
            return existingPost;
          }

          const post = this.store.createRecord("post", mungedData);
          this._identityMap[postData.id] = post;
          return post;
        },

        // New Method: Load more nested posts (infinite scroll)
        async loadMoreNested() {
          if (!this.nestedData?.meta?.has_next_page) {
            return;
          }

          const nextPage = this.nestedData.meta.page + 1;
          return this.loadNested({ page: nextPage, loadMore: true });
        },

        // New Method: Can load more in nested mode?
        canLoadMoreNested: computed(
          "nestedData.meta.has_next_page",
          "loadingNested",
          function () {
            return this.nestedData?.meta?.has_next_page && !this.loadingNested;
          }
        ),

        // Override: Refresh current mode
        async refresh(opts = {}) {
          if (this.isNestedMode) {
            // eslint-disable-next-line no-console
            console.log("[nested-replies] refresh called", {
              forceLoad: opts.forceLoad,
              nearPost: opts.nearPost,
              currentURL: window.location.href,
            });
            // Don't refresh nested view unless explicitly forced
            // This prevents automatic refreshes after post creation
            if (opts.forceLoad) {
              this.set("nestedCurrentPage", 1);
              return this.loadNested({ page: 1 });
            }
            // For non-forced refreshes, just return without doing anything
            // The post will be inserted via commitPost or triggerNewPostsInStream
            return Promise.resolve();
          }
          return this._super(...arguments);
        },

        // Override: Commit staged post (after successful save)
        commitPost(post) {
          const result = this._super(...arguments);

          // In nested mode, insert the post now that it has been saved
          // and has a real ID and post_number
          if (
            this.isNestedMode &&
            this.nestedData &&
            post.id &&
            post.id !== -1
          ) {
            // eslint-disable-next-line no-console
            console.log("[nested-replies] commitPost - inserting post", {
              id: post.id,
              post_number: post.post_number,
              reply_to_post_number: post.reply_to_post_number,
            });
            this._insertPostIntoNestedTree(post);
          }

          return result;
        },

        // Override: Handle new posts in nested mode
        async triggerNewPostsInStream(postIds, opts) {
          if (this.isNestedMode && this.nestedData) {
            // In nested mode, fetch new posts and insert them into the tree
            // without doing a full refresh
            if (!postIds || postIds.length === 0) {
              return;
            }

            try {
              const posts = await this.findPostsByIds(postIds, opts);
              posts.forEach((post) => {
                this._insertPostIntoNestedTree(post);
              });
            } catch (e) {
              // eslint-disable-next-line no-console
              console.error("Error loading new posts in nested mode:", e);
            }
          } else {
            // Use default behavior for chronological mode
            return this._super(...arguments);
          }
        },

        // Helper: Set nested data and preserve scroll position
        _setNestedDataWithScrollPreservation(newNestedData) {
          // Save scroll position
          const scrollY = window.scrollY;
          const scrollX = window.scrollX;

          // Update data
          this.set("nestedData", newNestedData);

          // Restore scroll position after DOM update
          requestAnimationFrame(() => {
            window.scrollTo(scrollX, scrollY);
          });
        },

        // Helper: Insert a new post into the nested tree without full refresh
        _insertPostIntoNestedTree(post) {
          if (!this.nestedData || !this.nestedData.nested_posts) {
            return;
          }

          // Ensure post is in identity map
          if (post.id && !this._identityMap[post.id]) {
            this._identityMap[post.id] = post;
          }

          const nestedPosts = this.nestedData.nested_posts;

          // Get post properties - handle both Post models and plain objects
          const postId = post.id || post.get?.("id");
          const postNumber = post.post_number || post.get?.("post_number");
          const replyToPostNumber =
            post.reply_to_post_number || post.get?.("reply_to_post_number");

          // eslint-disable-next-line no-console
          console.log("[nested-replies] _insertPostIntoNestedTree", {
            postId,
            postNumber,
            replyToPostNumber,
            isPostModel: !!post.toJSON,
          });

          // Safety check: post must have required properties
          if (!postNumber) {
            // eslint-disable-next-line no-console
            console.warn(
              "Cannot insert post into nested tree: missing post_number",
              post
            );
            return;
          }

          // Use the post model directly
          const postModel = post;

          // Check if post is a reply to an existing post
          if (replyToPostNumber && replyToPostNumber > 0) {
            // Find the parent - could be a top-level post or a reply
            let parentNode = nestedPosts.find(
              (n) =>
                (n.post.post_number || n.post.get?.("post_number")) ===
                replyToPostNumber
            );

            // If not found in top-level, search in replies arrays
            if (!parentNode) {
              for (const node of nestedPosts) {
                const parentReply = node.replies.find(
                  (r) =>
                    (r.post_number || r.get?.("post_number")) ===
                    replyToPostNumber
                );
                if (parentReply) {
                  // Check if post already exists in this replies array
                  const existingReply = node.replies.find(
                    (r) => (r.id || r.get?.("id")) === postId
                  );
                  if (existingReply) {
                    // eslint-disable-next-line no-console
                    console.log(
                      "[nested-replies] Post already exists in nested replies",
                      postId
                    );
                    return; // Already in tree
                  }

                  // Found parent in replies - add new post to same replies array
                  const updatedNode = {
                    ...node,
                    replies: [...node.replies, postModel],
                    total_reply_count: (node.total_reply_count || 0) + 1,
                    loaded_reply_count: (node.loaded_reply_count || 0) + 1,
                  };

                  const nodeIndex = nestedPosts.indexOf(node);
                  const updatedNestedPosts = [...nestedPosts];
                  updatedNestedPosts[nodeIndex] = updatedNode;

                  this._setNestedDataWithScrollPreservation({
                    ...this.nestedData,
                    nested_posts: updatedNestedPosts,
                  });

                  // eslint-disable-next-line no-console
                  console.log(
                    "[nested-replies] Inserted reply to nested parent",
                    postNumber,
                    "->",
                    replyToPostNumber
                  );

                  return;
                }
              }
            }

            if (parentNode) {
              // Check if reply already exists
              const existingReply = parentNode.replies.find(
                (r) => (r.id || r.get?.("id")) === postId
              );
              if (existingReply) {
                return; // Already in tree
              }

              // Add as a reply to the parent
              const updatedNode = {
                ...parentNode,
                replies: [...parentNode.replies, postModel],
                total_reply_count: (parentNode.total_reply_count || 0) + 1,
                loaded_reply_count: (parentNode.loaded_reply_count || 0) + 1,
              };

              // Update the tree
              const nodeIndex = nestedPosts.indexOf(parentNode);
              const updatedNestedPosts = [...nestedPosts];
              updatedNestedPosts[nodeIndex] = updatedNode;

              this._setNestedDataWithScrollPreservation({
                ...this.nestedData,
                nested_posts: updatedNestedPosts,
              });

              // eslint-disable-next-line no-console
              console.log(
                "[nested-replies] Inserted reply to parent post",
                postNumber,
                "->",
                replyToPostNumber
              );

              return;
            } else {
              // Parent post not found in current nested tree
              // This means the reply parent is on a different page or not loaded
              // We need to do a full refresh to show the post in the correct location
              // eslint-disable-next-line no-console
              console.log(
                "[nested-replies] Parent post not found, triggering full reload",
                { postNumber, replyToPostNumber }
              );

              // Navigate to the new post to show it in context
              this.set("nestedCurrentPage", 1);
              this.loadNested({ page: 1, post_number: postNumber });
              return;
            }
          }

          // If it's a top-level post (no reply_to or parent not found)
          // Check if it already exists as a top-level node
          const existingNode = nestedPosts.find(
            (n) => (n.post.id || n.post.get?.("id")) === postId
          );
          if (existingNode) {
            // eslint-disable-next-line no-console
            console.log("[nested-replies] Post already exists in tree", postId);
            return; // Already in tree
          }

          // Add as new top-level node
          const newNode = {
            post: postModel,
            replies: [],
            total_reply_count: 0,
            loaded_reply_count: 0,
            has_more_replies: false,
          };

          // Insert at the correct position based on current sort
          let insertIndex = nestedPosts.length; // Default: append at end
          const likeCount =
            postModel.like_count || postModel.get?.("like_count") || 0;

          if (this.nestedSort === "chronological") {
            // Insert in chronological order (by post_number)
            insertIndex = nestedPosts.findIndex(
              (n) =>
                (n.post.post_number || n.post.get?.("post_number")) > postNumber
            );
            if (insertIndex === -1) {
              insertIndex = nestedPosts.length;
            }
          } else if (this.nestedSort === "new") {
            // Insert at beginning for newest posts
            insertIndex = 0;
          } else if (this.nestedSort === "best") {
            // Insert based on like_count
            insertIndex = nestedPosts.findIndex(
              (n) =>
                (n.post.like_count || n.post.get?.("like_count") || 0) <
                likeCount
            );
            if (insertIndex === -1) {
              insertIndex = nestedPosts.length;
            }
          }

          const updatedNestedPosts = [...nestedPosts];
          updatedNestedPosts.splice(insertIndex, 0, newNode);

          this._setNestedDataWithScrollPreservation({
            ...this.nestedData,
            nested_posts: updatedNestedPosts,
          });

          // eslint-disable-next-line no-console
          console.log(
            "[nested-replies] Inserted top-level post",
            postNumber,
            "at index",
            insertIndex
          );
        },
      });
    });
  },
};
