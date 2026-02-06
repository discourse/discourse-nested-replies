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

        init() {
          this._super(...arguments);
          this.displayMode = null;
          this.nestedData = null;
          this.nestedCurrentPage = 1;
          this.loadingNested = false;
          this.hideTimeline = false;
          this.nestedSort = "chronological";
          this.threadData = null;
        },

        isNestedMode: equal("displayMode", "nested"),

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

            const convertedNodes = this._convertNestedData(data.nested_posts);

            if (opts.loadMore) {
              this.set("nestedData", {
                nested_posts: [
                  ...this.nestedData.nested_posts,
                  ...convertedNodes,
                ],
                meta: data.meta,
              });
            } else {
              this.set("nestedData", {
                nested_posts: convertedNodes,
                meta: data.meta,
              });
            }

            this.set("nestedCurrentPage", page);

            if (!opts.loadMore) {
              this.set("loaded", true);

              if (data.stream) {
                this.stream.splice(0, this.stream.length, ...data.stream);
              }

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

        _convertNestedData(nestedPosts) {
          return nestedPosts.map((node) => ({
            ...node,
            post: this._getOrCreatePost(node.post),
            replies: node.replies.map((reply) => this._getOrCreatePost(reply)),
          }));
        },

        _getOrCreatePost(postData) {
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

        async loadMoreNested() {
          if (!this.nestedData?.meta?.has_next_page) {
            return;
          }

          const nextPage = this.nestedData.meta.page + 1;
          return this.loadNested({ page: nextPage, loadMore: true });
        },

        canLoadMoreNested: computed(
          "nestedData.meta.has_next_page",
          "loadingNested",
          function () {
            return this.nestedData?.meta?.has_next_page && !this.loadingNested;
          }
        ),

        async refresh(opts = {}) {
          if (this.isNestedMode) {
            if (opts.forceLoad) {
              this.set("nestedCurrentPage", 1);
              return this.loadNested({ page: 1 });
            }
            return Promise.resolve();
          }
          return this._super(...arguments);
        },

        commitPost(post) {
          const result = this._super(...arguments);

          if (
            this.isNestedMode &&
            this.nestedData &&
            post.id &&
            post.id !== -1
          ) {
            this._insertPostIntoNestedTree(post);
          }

          return result;
        },

        async triggerNewPostsInStream(postIds, opts) {
          if (this.isNestedMode && this.nestedData) {
            if (!postIds || postIds.length === 0) {
              return;
            }

            const posts = await this.findPostsByIds(postIds, opts);
            posts.forEach((post) => {
              this._insertPostIntoNestedTree(post);
            });
          } else {
            return this._super(...arguments);
          }
        },

        _setNestedDataWithScrollPreservation(newNestedData) {
          const scrollY = window.scrollY;
          const scrollX = window.scrollX;

          this.set("nestedData", newNestedData);

          requestAnimationFrame(() => {
            window.scrollTo(scrollX, scrollY);
          });
        },

        _insertPostIntoNestedTree(post) {
          if (!this.nestedData?.nested_posts) {
            return;
          }

          if (post.id && !this._identityMap[post.id]) {
            this._identityMap[post.id] = post;
          }

          const nestedPosts = this.nestedData.nested_posts;
          const postId = post.id || post.get?.("id");
          const postNumber = post.post_number || post.get?.("post_number");
          const replyToPostNumber =
            post.reply_to_post_number || post.get?.("reply_to_post_number");

          if (!postNumber) {
            return;
          }

          if (replyToPostNumber && replyToPostNumber > 0) {
            let parentNode = nestedPosts.find(
              (n) =>
                (n.post.post_number || n.post.get?.("post_number")) ===
                replyToPostNumber
            );

            if (!parentNode) {
              for (const node of nestedPosts) {
                const parentReply = node.replies.find(
                  (r) =>
                    (r.post_number || r.get?.("post_number")) ===
                    replyToPostNumber
                );
                if (parentReply) {
                  const existingReply = node.replies.find(
                    (r) => (r.id || r.get?.("id")) === postId
                  );
                  if (existingReply) {
                    return;
                  }

                  const updatedNode = {
                    ...node,
                    replies: [...node.replies, post],
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

                  return;
                }
              }
            }

            if (parentNode) {
              const existingReply = parentNode.replies.find(
                (r) => (r.id || r.get?.("id")) === postId
              );
              if (existingReply) {
                return;
              }

              const updatedNode = {
                ...parentNode,
                replies: [...parentNode.replies, post],
                total_reply_count: (parentNode.total_reply_count || 0) + 1,
                loaded_reply_count: (parentNode.loaded_reply_count || 0) + 1,
              };

              const nodeIndex = nestedPosts.indexOf(parentNode);
              const updatedNestedPosts = [...nestedPosts];
              updatedNestedPosts[nodeIndex] = updatedNode;

              this._setNestedDataWithScrollPreservation({
                ...this.nestedData,
                nested_posts: updatedNestedPosts,
              });

              return;
            } else {
              this.set("nestedCurrentPage", 1);
              this.loadNested({ page: 1, post_number: postNumber });
              return;
            }
          }

          const existingNode = nestedPosts.find(
            (n) => (n.post.id || n.post.get?.("id")) === postId
          );
          if (existingNode) {
            return;
          }

          const newNode = {
            post,
            replies: [],
            total_reply_count: 0,
            loaded_reply_count: 0,
            has_more_replies: false,
          };

          let insertIndex = nestedPosts.length;
          const likeCount = post.like_count || post.get?.("like_count") || 0;

          if (this.nestedSort === "chronological") {
            insertIndex = nestedPosts.findIndex(
              (n) =>
                (n.post.post_number || n.post.get?.("post_number")) > postNumber
            );
            if (insertIndex === -1) {
              insertIndex = nestedPosts.length;
            }
          } else if (this.nestedSort === "new") {
            insertIndex = 0;
          } else if (this.nestedSort === "best") {
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
        },
      });
    });
  },
};
