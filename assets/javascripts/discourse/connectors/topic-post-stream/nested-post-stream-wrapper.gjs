import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";
import NestedPostStream from "../../components/nested-post-stream";

export default class NestedPostStreamWrapper extends Component {
  @service store;
  @service siteSettings;
  @service router;

  @tracked loadingMoreReplies = {};
  @tracked replyOffsets = {};

  get isThreadMode() {
    const postStream = this.args.outletArgs?.postStream;
    return postStream?.displayMode === "thread";
  }

  get threadData() {
    const postStream = this.args.outletArgs?.postStream;
    return postStream?.threadData;
  }

  get shouldRenderNested() {
    const postStream = this.args.outletArgs?.postStream;
    const shouldRender =
      postStream?.isNestedMode && postStream?.nestedData?.nested_posts;

    // eslint-disable-next-line no-console
    console.log("[nested-post-stream-wrapper] shouldRenderNested", {
      hasOutletArgs: !!this.args.outletArgs,
      hasPostStream: !!postStream,
      isNestedMode: postStream?.isNestedMode,
      displayMode: postStream?.displayMode,
      isThreadMode: this.isThreadMode,
      hasNestedData: !!postStream?.nestedData,
      hasNestedPosts: !!postStream?.nestedData?.nested_posts,
      shouldRender,
      canCreatePost: this.args.outletArgs?.canCreatePost,
      replyToPost: this.args.outletArgs?.replyToPost,
      outletArgKeys: Object.keys(this.args.outletArgs || {}),
    });

    return shouldRender;
  }

  @action
  async loadMoreTopLevelPosts() {
    const postStream = this.args.outletArgs.postStream;
    if (postStream && postStream.loadMoreNested) {
      await postStream.loadMoreNested();
    }
  }

  @action
  viewFullTopic() {
    const topic = this.args.outletArgs.topic;
    if (topic) {
      this.router.transitionTo("topic.nested", topic.slug, topic.id);
    }
  }

  @action
  async loadMoreReplies(postId) {
    this.loadingMoreReplies = { ...this.loadingMoreReplies, [postId]: true };

    try {
      const postStream = this.args.outletArgs.postStream;

      // Determine which data structure to use based on mode
      const isThreadMode = this.isThreadMode;
      const nestedPosts = isThreadMode
        ? postStream.threadData.nestedPosts
        : postStream.nestedData.nested_posts;

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

      // Update the entire data structure to trigger reactivity
      const updatedNestedPosts = [...nestedPosts];
      updatedNestedPosts[nodeIndex] = updatedNode;

      if (isThreadMode) {
        postStream.set("threadData", {
          ...postStream.threadData,
          nestedPosts: updatedNestedPosts,
        });
      } else {
        postStream.set("nestedData", {
          ...postStream.nestedData,
          nested_posts: updatedNestedPosts,
        });
      }

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
    {{#if this.isThreadMode}}
      {{! Thread mode - render thread view directly here }}
      <div class="nested-thread-view">
        <div class="thread-view-header">
          <div class="thread-view-info">
            <span class="thread-view-label">
              {{i18n "nested_replies.thread_view.viewing_thread"}}
            </span>
            <span class="thread-view-post-info">
              {{i18n
                "nested_replies.thread_view.post_number"
                number=this.threadData.meta.highlight_post_number
              }}
            </span>
          </div>
          <DButton
            @action={{this.viewFullTopic}}
            @label="nested_replies.thread_view.view_full_topic"
            @icon="discourse-expand"
            class="btn-default"
          />
        </div>

        <NestedPostStream
          @nestedPosts={{this.threadData.nestedPosts}}
          @loadMore={{null}}
          @canLoadMore={{false}}
          @isLoadingMore={{false}}
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
      </div>
    {{else if this.shouldRenderNested}}
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
