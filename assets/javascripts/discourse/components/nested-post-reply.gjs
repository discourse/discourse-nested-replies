import { concat, fn } from "@ember/helper";
import Post from "discourse/components/post";
import PostSmallAction from "discourse/components/post/small-action";

<template>
  <div
    class="nested-post-reply"
    data-post-id={{@post.id}}
    data-post-number={{@post.post_number}}
  >
    <div class="nested-reply-connector"></div>
    <div class="nested-reply-content">
      {{#if @post.isSmallAction}}
        <PostSmallAction
          @post={{@post}}
          @cloaked={{false}}
          @elementId={{concat "post_" @post.post_number}}
          @recoverPost={{fn @recoverPost @post}}
          @editPost={{fn @editPost @post}}
          @deletePost={{fn @deletePost @post}}
        />
      {{else}}
        <Post
          @post={{@post}}
          @canCreatePost={{@canCreatePost}}
          @replyToPost={{fn @replyToPost @post}}
          @editPost={{fn @editPost @post}}
          @deletePost={{fn @deletePost @post}}
          @recoverPost={{fn @recoverPost @post}}
          @showFlags={{fn @showFlags @post}}
          @showLogin={{fn @showLogin @post}}
          @permanentlyDeletePost={{fn @permanentlyDeletePost @post}}
          @rebakePost={{fn @rebakePost @post}}
          @changePostOwner={{fn @changePostOwner @post}}
          @grantBadge={{fn @grantBadge @post}}
          @changeNotice={{fn @changeNotice @post}}
          @lockPost={{fn @lockPost @post}}
          @unlockPost={{fn @unlockPost @post}}
          @unhidePost={{fn @unhidePost @post}}
          @toggleWiki={{fn @toggleWiki @post}}
          @togglePostType={{fn @togglePostType @post}}
          @showHistory={{fn @showHistory @post}}
          @showRawEmail={{fn @showRawEmail @post}}
          @showInvite={{fn @showInvite @post}}
          @showPagePublish={{fn @showPagePublish @post}}
          @showReadIndicator={{@showReadIndicator}}
          @expandHidden={{fn @expandHidden @post}}
        />
      {{/if}}
    </div>
  </div>
</template>
