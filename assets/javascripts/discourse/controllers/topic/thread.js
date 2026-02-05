import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

export default class TopicThreadController extends Controller {
  @service store;
  @service siteSettings;
  @service router;

  @tracked loadingMoreReplies = {};
  @tracked replyOffsets = {};

  get topic() {
    return this.model.topic;
  }

  get topicController() {
    return getOwner(this).lookup("controller:topic");
  }

  get nestedPosts() {
    return this.model.nestedPosts || [];
  }

  get meta() {
    return this.model.meta;
  }

  get isThreadView() {
    return this.meta?.thread_view === true;
  }

  get rootPostNumber() {
    return this.meta?.root_post_number;
  }

  get highlightPostNumber() {
    return this.meta?.highlight_post_number;
  }

  @action
  async loadMoreReplies(postId) {
    this.loadingMoreReplies = { ...this.loadingMoreReplies, [postId]: true };

    try {
      const nestedPosts = this.model.nestedPosts;
      const nodeIndex = nestedPosts.findIndex((n) => n.post.id === postId);
      if (nodeIndex === -1) {
        return;
      }

      const node = nestedPosts[nodeIndex];
      const offset = this.replyOffsets[postId] || node.loaded_reply_count;
      const limit = this.siteSettings.nested_replies_load_more_count;

      const result = await ajax(
        `/nested-replies/posts/${postId}/replies.json`,
        {
          data: { offset, limit },
        }
      );

      // Append new replies
      const newReplies = result.posts.map((reply) =>
        this.store.createRecord("post", {
          ...reply,
          topic: this.topic,
        })
      );

      const updatedNode = {
        ...node,
        replies: [...node.replies, ...newReplies],
        loaded_reply_count: result.loaded_count,
        has_more_replies: result.has_more_replies,
      };

      const updatedNestedPosts = [...nestedPosts];
      updatedNestedPosts[nodeIndex] = updatedNode;

      this.model.nestedPosts = updatedNestedPosts;

      this.replyOffsets = {
        ...this.replyOffsets,
        [postId]: result.loaded_count,
      };
    } finally {
      this.loadingMoreReplies = { ...this.loadingMoreReplies };
      delete this.loadingMoreReplies[postId];
    }
  }

  @action
  viewFullTopic() {
    // Navigate back to the nested view of the full topic
    this.router.transitionTo("topic.nested", this.topic.slug, this.topic.id);
  }
}
