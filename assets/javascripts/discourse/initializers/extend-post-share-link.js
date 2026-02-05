import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "extend-post-share-link-for-nested",

  initialize() {
    withPluginApi((api) => {
      // Extend the Post model to customize the share link in nested mode
      api.modifyClass("model:post", {
        pluginId: "discourse-nested-replies",

        // Override the shareUrl computed property to generate thread URLs in nested mode
        get shareUrl() {
          const topic = this.topic;

          // Guard: if no topic, fall back to parent implementation
          if (!topic) {
            return this._super?.() || "";
          }

          const postStream = topic.postStream;
          const postNumber = this.post_number;

          // If we're in nested mode, generate a thread view URL for all posts
          if (postStream?.isNestedMode) {
            return `${topic.url}/thread/${postNumber}`;
          }

          // Otherwise, use the default behavior (chronological link)
          return this._super?.() || `${topic.url}/${postNumber}`;
        },
      });
    });
  },
};
