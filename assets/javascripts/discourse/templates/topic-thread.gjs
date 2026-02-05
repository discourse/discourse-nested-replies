import DButton from "discourse/components/d-button";
import { i18n } from "discourse-i18n";
import NestedPostStream from "../components/nested-post-stream";

<template>
  <div class="nested-thread-view">
    <div class="thread-view-header">
      <div class="thread-view-info">
        <span class="thread-view-label">
          {{i18n "nested_replies.thread_view.viewing_thread"}}
        </span>
        <span class="thread-view-post-info">
          {{i18n
            "nested_replies.thread_view.post_number"
            number=@model.meta.highlight_post_number
          }}
        </span>
      </div>
      <DButton
        @action={{@controller.viewFullTopic}}
        @label="nested_replies.thread_view.view_full_topic"
        @icon="discourse-expand"
        class="btn-default"
      />
    </div>

    <NestedPostStream
      @nestedPosts={{@controller.nestedPosts}}
      @loadMore={{null}}
      @canLoadMore={{false}}
      @isLoadingMore={{false}}
      @onLoadMoreReplies={{@controller.loadMoreReplies}}
      @loadingMoreReplies={{@controller.loadingMoreReplies}}
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
      @unlockPost={{@unlockPost}}
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
</template>
