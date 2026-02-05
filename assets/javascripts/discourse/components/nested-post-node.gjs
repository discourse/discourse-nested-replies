import Component from "@glimmer/component";
import { concat, fn } from "@ember/helper";
import DButton from "discourse/components/d-button";
import Post from "discourse/components/post";
import PostSmallAction from "discourse/components/post/small-action";
import { i18n } from "discourse-i18n";
import NestedPostReply from "./nested-post-reply";

export default class NestedPostNode extends Component {
  get hasMoreReplies() {
    return this.args.node.has_more_replies;
  }

  get remainingReplyCount() {
    return this.args.node.total_reply_count - this.args.node.loaded_reply_count;
  }

  get isLoadingReplies() {
    return this.args.loadingMoreReplies?.[this.args.node.post.id];
  }

  <template>
    <div
      class="nested-post-node {{if @node.highlighted 'highlighted'}}"
      data-post-id={{@node.post.id}}
      data-post-number={{@node.post.post_number}}
    >
      <div class="nested-post-parent">
        {{#if @node.post.isSmallAction}}
          <PostSmallAction
            @post={{@node.post}}
            @cloaked={{false}}
            @elementId={{concat "post_" @node.post.post_number}}
            @recoverPost={{fn @recoverPost @node.post}}
            @editPost={{fn @editPost @node.post}}
            @deletePost={{fn @deletePost @node.post}}
          />
        {{else}}
          <Post
            @post={{@node.post}}
            @canCreatePost={{@canCreatePost}}
            @replyToPost={{fn @replyToPost @node.post}}
            @editPost={{fn @editPost @node.post}}
            @deletePost={{fn @deletePost @node.post}}
            @recoverPost={{fn @recoverPost @node.post}}
            @showFlags={{fn @showFlags @node.post}}
            @showLogin={{fn @showLogin @node.post}}
            @permanentlyDeletePost={{fn @permanentlyDeletePost @node.post}}
            @rebakePost={{fn @rebakePost @node.post}}
            @changePostOwner={{fn @changePostOwner @node.post}}
            @grantBadge={{fn @grantBadge @node.post}}
            @changeNotice={{fn @changeNotice @node.post}}
            @lockPost={{fn @lockPost @node.post}}
            @unlockPost={{fn @unlockPost @node.post}}
            @unhidePost={{fn @unhidePost @node.post}}
            @toggleWiki={{fn @toggleWiki @node.post}}
            @togglePostType={{fn @togglePostType @node.post}}
            @showHistory={{fn @showHistory @node.post}}
            @showRawEmail={{fn @showRawEmail @node.post}}
            @showInvite={{fn @showInvite @node.post}}
            @showPagePublish={{fn @showPagePublish @node.post}}
            @showReadIndicator={{@showReadIndicator}}
            @expandHidden={{fn @expandHidden @node.post}}
          />
        {{/if}}
      </div>

      {{#if @node.replies}}
        <div class="nested-post-replies">
          {{#each @node.replies key="id" as |reply|}}
            <NestedPostReply
              @post={{reply}}
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

          {{#if this.hasMoreReplies}}
            <div class="nested-load-more-replies">
              <DButton
                @action={{fn @onLoadMoreReplies @node.post.id}}
                @translatedLabel={{i18n
                  "nested_replies.load_more_replies"
                  count=this.remainingReplyCount
                }}
                @icon="chevron-down"
                @disabled={{this.isLoadingReplies}}
                class="btn-default"
              />
            </div>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
