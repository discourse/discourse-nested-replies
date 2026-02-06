import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "extend-post-share-link-for-nested",

  initialize() {
    withPluginApi((api) => {
      api.modifyClass("model:post", {
        pluginId: "discourse-nested-replies",

        get shareUrl() {
          const topic = this.topic;

          if (!topic) {
            return this._super?.() || "";
          }

          const postStream = topic.postStream;
          const postNumber = this.post_number;

          if (postStream?.isNestedMode) {
            return `${topic.url}/thread/${postNumber}`;
          }

          return this._super?.() || `${topic.url}/${postNumber}`;
        },
      });
    });
  },
};
