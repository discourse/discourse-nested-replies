import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import NestedPostStream from "../../components/nested-post-stream";

export default class NestedPostStreamWrapper extends Component {
  @service store;
  @service siteSettings;

  @tracked loadingMoreReplies = {};
  @tracked replyOffsets = {};

  get shouldRenderNested() {
    return this.args.outletArgs.postStream.isNestedMode;
  }

  @action
  async loadMoreTopLevelPosts() {
    const postStream = this.args.outletArgs.postStream;
    if (postStream && postStream.loadMoreNested) {
      await postStream.loadMoreNested();
    }
  }

  @action
  async loadMoreReplies(postId) {
    this.loadingMoreReplies = { ...this.loadingMoreReplies, [postId]: true };

    try {
      const postStream = this.args.outletArgs.postStream;
      const nestedPosts = postStream.nestedData.nested_posts;
      const nodeIndex = nestedPosts.findIndex((n) => n.post.id === postId);
      if (nodeIndex === -1) {
        return;
      }

      const node = nestedPosts[nodeIndex];

      // Get current offset or start from loaded count
      const offset = this.replyOffsets[postId] || node.loaded_reply_count;
      const limit = this.siteSettings.nested_replies_load_more_count;

      const result = await ajax(
        `/nested-replies/posts/${postId}/replies.json`,
        {
          data: { offset, limit },
        }
      );

      // Append new replies to existing ones
      const newReplies = result.posts.map((reply) =>
        this.store.createRecord("post", {
          ...reply,
          topic: this.args.outletArgs.topic,
        })
      );

      // Create updated node with new replies
      const updatedNode = {
        ...node,
        replies: [...node.replies, ...newReplies],
        loaded_reply_count: result.loaded_count,
        has_more_replies: result.has_more_replies,
      };

      // Update the entire nestedData to trigger reactivity
      const updatedNestedPosts = [...nestedPosts];
      updatedNestedPosts[nodeIndex] = updatedNode;

      postStream.set("nestedData", {
        ...postStream.nestedData,
        nested_posts: updatedNestedPosts,
      });

      // Update offset for next load
      this.replyOffsets = {
        ...this.replyOffsets,
        [postId]: result.loaded_count,
      };
    } finally {
      this.loadingMoreReplies = { ...this.loadingMoreReplies };
      delete this.loadingMoreReplies[postId];
    }
  }

  <template>
    {{#if this.shouldRenderNested}}
      <NestedPostStream
        @nestedPosts={{@outletArgs.postStream.nestedData.nested_posts}}
        @loadMore={{this.loadMoreTopLevelPosts}}
        @canLoadMore={{@outletArgs.postStream.canLoadMoreNested}}
        @isLoadingMore={{@outletArgs.postStream.loadingMore}}
        @onLoadMoreReplies={{this.loadMoreReplies}}
        @loadingMoreReplies={{this.loadingMoreReplies}}
        @canCreatePost={{@outletArgs.canCreatePost}}
        @replyToPost={{@outletArgs.replyToPost}}
        @editPost={{@outletArgs.editPost}}
        @deletePost={{@outletArgs.deletePost}}
        @recoverPost={{@outletArgs.recoverPost}}
        @showFlags={{@outletArgs.showFlags}}
        @showLogin={{@outletArgs.showLogin}}
        @permanentlyDeletePost={{@outletArgs.permanentlyDeletePost}}
        @rebakePost={{@outletArgs.rebakePost}}
        @changePostOwner={{@outletArgs.changePostOwner}}
        @grantBadge={{@outletArgs.grantBadge}}
        @changeNotice={{@outletArgs.changeNotice}}
        @lockPost={{@outletArgs.lockPost}}
        @unlockPost={{@outletArgs.unlockPost}}
        @unhidePost={{@outletArgs.unhidePost}}
        @toggleWiki={{@outletArgs.toggleWiki}}
        @togglePostType={{@outletArgs.togglePostType}}
        @showHistory={{@outletArgs.showHistory}}
        @showRawEmail={{@outletArgs.showRawEmail}}
        @showInvite={{@outletArgs.showInvite}}
        @showPagePublish={{@outletArgs.showPagePublish}}
        @showReadIndicator={{@outletArgs.showReadIndicator}}
        @expandHidden={{@outletArgs.expandHidden}}
      />
    {{else}}
      {{yield}}
    {{/if}}
  </template>
}
