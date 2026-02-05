import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import LoadMore from "discourse/components/load-more";
import NestedPostNode from "./nested-post-node";

<template>
  <div class="nested-post-stream">
    <div class="nested-posts-container">
      {{#each @nestedPosts key="post.id" as |node|}}
        <NestedPostNode
          @node={{node}}
          @onLoadMoreReplies={{@onLoadMoreReplies}}
          @loadingMoreReplies={{@loadingMoreReplies}}
          @canCreatePost={{@canCreatePost}}
          @replyToPost={{@replyToPost}}
          @editPost={{@editPost}}
          @deletePost={{@deletePost}}
          @recoverPost={{@recoverPost}}
          @showFlags={{@showFlags}}
          @showLogin={{@showLogin}}
          @permanentlyDeletePost={{@permanentlyDeletePost}}
          @rebakePost={{@rebakePost}}
          @changePostOwner={{@changePostOwner}}
          @grantBadge={{@grantBadge}}
          @changeNotice={{@changeNotice}}
          @lockPost={{@lockPost}}
          @unlockPost={{@unlockPost}}
          @unhidePost={{@unhidePost}}
          @toggleWiki={{@toggleWiki}}
          @togglePostType={{@togglePostType}}
          @showHistory={{@showHistory}}
          @showRawEmail={{@showRawEmail}}
          @showInvite={{@showInvite}}
          @showPagePublish={{@showPagePublish}}
          @showReadIndicator={{@showReadIndicator}}
          @expandHidden={{@expandHidden}}
        />
      {{/each}}
    </div>

    <LoadMore
      @action={{@loadMore}}
      @enabled={{@canLoadMore}}
      @isLoading={{@isLoadingMore}}
    />

    <ConditionalLoadingSpinner @condition={{@isLoadingMore}} />
  </div>
</template>
