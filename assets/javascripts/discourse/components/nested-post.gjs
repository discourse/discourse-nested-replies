import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import ShareTopicModal from "discourse/components/modal/share-topic";
import PostAvatar from "discourse/components/post/avatar";
import PostCookedHtml from "discourse/components/post/cooked-html";
import PostMenu from "discourse/components/post/menu";
import PostMetaData from "discourse/components/post/meta-data";
import concatClass from "discourse/helpers/concat-class";
import { isTesting } from "discourse/lib/environment";
import getURL, { getAbsoluteURL } from "discourse/lib/get-url";
import postActionFeedback from "discourse/lib/post-action-feedback";
import { nativeShare } from "discourse/lib/pwa-utils";
import { clipboardCopy } from "discourse/lib/utilities";
import { and, not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import NestedPostChildren from "./nested-post-children";

export default class NestedPost extends Component {
  @service appEvents;
  @service capabilities;
  @service modal;
  @service site;
  @service siteSettings;

  @tracked expanded = (this.args.children?.length ?? 0) > 0;
  @tracked lineHighlighted = false;

  trackPost = modifier((element) => {
    this.args.postScreenTracker?.observe(element, this.args.post);
    return () => this.args.postScreenTracker?.unobserve(element);
  });

  constructor() {
    super(...arguments);
    this.appEvents.on(
      "nested-replies:child-created",
      this,
      this._onChildCreated
    );
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.appEvents.off(
      "nested-replies:child-created",
      this,
      this._onChildCreated
    );
  }

  _onChildCreated({ parentPostNumber, isOwnPost }) {
    if (parentPostNumber !== this.args.post.post_number) {
      return;
    }

    const post = this.args.post;
    post.set("direct_reply_count", (post.direct_reply_count || 0) + 1);
    post.set("total_descendant_count", (post.total_descendant_count || 0) + 1);

    if (isOwnPost && !this.expanded) {
      this.expanded = true;
    }
  }

  get depthClass() {
    return `--depth-${this.args.depth}`;
  }

  get hasReplies() {
    return (
      (this.args.post.direct_reply_count || 0) > 0 ||
      (this.args.children?.length ?? 0) > 0
    );
  }

  get replyCount() {
    return (
      this.args.post.total_descendant_count ||
      this.args.post.direct_reply_count ||
      this.args.children?.length ||
      0
    );
  }

  get atMaxDepth() {
    return this.args.depth >= this.siteSettings.nested_replies_max_depth;
  }

  get showContinueThread() {
    return (
      this.atMaxDepth &&
      this.hasReplies &&
      !this.siteSettings.nested_replies_cap_nesting_depth
    );
  }

  get isOP() {
    return this.args.post.user_id === this.args.topic?.user_id;
  }

  get contextUrl() {
    return getURL(
      `/nested/${this.args.topic.slug}/${this.args.topic.id}?post_number=${this.args.post.post_number}&context=0`
    );
  }

  get expandLabel() {
    return i18n("discourse_nested_replies.collapsed_replies", {
      count: this.replyCount,
    });
  }

  @action
  toggleExpanded() {
    this.expanded = !this.expanded;
  }

  @action
  highlightLine() {
    this.lineHighlighted = true;
  }

  @action
  unhighlightLine() {
    this.lineHighlighted = false;
  }

  get nestedShareUrl() {
    return `/nested/${this.args.topic.slug}/${this.args.topic.id}?post_number=${this.args.post.post_number}`;
  }

  @action
  copyLink() {
    if (this.site.mobileView) {
      return this.share();
    }

    const post = this.args.post;
    const postId = post.id;

    let actionCallback = () =>
      clipboardCopy(getAbsoluteURL(this.nestedShareUrl));

    if (isTesting()) {
      actionCallback = () => {};
    }

    postActionFeedback({
      postId,
      actionClass: "post-action-menu__copy-link",
      messageKey: "post.controls.link_copied",
      actionCallback,
      errorCallback: () => this.share(),
    });
  }

  @action
  async share() {
    const post = this.args.post;

    try {
      await nativeShare(this.capabilities, {
        url: getAbsoluteURL(this.nestedShareUrl),
      });
    } catch {
      const topic = post.topic;
      this.modal.show(ShareTopicModal, {
        model: { category: topic.category, topic, post },
      });
    }
  }

  @action
  async toggleLike() {
    const post = this.args.post;
    const likeAction = post.likeAction;

    if (likeAction?.canToggle) {
      await likeAction.togglePromise(post);
    }
  }

  @action
  noop() {}

  <template>
    <div
      class={{concatClass
        "nested-post"
        this.depthClass
        (if @parentLineHighlighted "--parent-line-highlighted")
      }}
    >
      {{#if @collapseParent}}
        <button
          type="button"
          class="nested-post__parent-line-btn"
          {{on "click" @collapseParent}}
          {{on "mouseenter" @highlightParentLine}}
          {{on "mouseleave" @unhighlightParentLine}}
          aria-label={{i18n "discourse_nested_replies.collapse_parent"}}
        ></button>
      {{/if}}
      <div class="nested-post__gutter">
        <PostAvatar @post={{@post}} @size="small" />
        {{#if this.hasReplies}}
          <button
            type="button"
            class={{concatClass
              "nested-post__depth-line"
              (if this.lineHighlighted "nested-post__depth-line--highlighted")
              (unless this.expanded "nested-post__depth-line--collapsed")
            }}
            {{on "click" this.toggleExpanded}}
            {{on "mouseenter" this.highlightLine}}
            {{on "mouseleave" this.unhighlightLine}}
            aria-label={{if
              this.expanded
              (i18n "discourse_nested_replies.collapse")
              this.expandLabel
            }}
          ></button>
        {{/if}}
      </div>
      <div class="nested-post__main">
        <article
          class="nested-post__article"
          data-post-number={{@post.post_number}}
          {{this.trackPost}}
        >
          <div class="nested-post__header">
            <PostMetaData @post={{@post}} @editPost={{@editPost}} />
            {{#if this.isOP}}
              <span class="nested-post__op-badge">{{i18n
                  "discourse_nested_replies.op_badge"
                }}</span>
            {{/if}}
          </div>
          <div class="nested-post__content">
            <PostCookedHtml @post={{@post}} />
          </div>
          <section class="nested-post__menu post-menu-area clearfix">
            <PostMenu
              @post={{@post}}
              @canCreatePost={{true}}
              @copyLink={{this.copyLink}}
              @deletePost={{fn @deletePost @post}}
              @editPost={{fn @editPost @post}}
              @recoverPost={{fn @recoverPost @post}}
              @replyToPost={{fn @replyToPost @post @depth}}
              @share={{this.share}}
              @showFlags={{fn @showFlags @post}}
              @toggleLike={{this.toggleLike}}
              @toggleReplies={{this.toggleExpanded}}
              @repliesShown={{this.expanded}}
              @showLogin={{this.noop}}
            />
          </section>
          {{#if this.showContinueThread}}
            <div class="nested-post__controls">
              <a href={{this.contextUrl}} class="nested-post__continue-link">
                {{i18n "discourse_nested_replies.continue_thread"}}
              </a>
            </div>
          {{/if}}
        </article>

        {{#if (and this.expanded (not this.atMaxDepth))}}
          <NestedPostChildren
            @topic={{@topic}}
            @parentPostNumber={{@post.post_number}}
            @preloadedChildren={{@children}}
            @directReplyCount={{@post.direct_reply_count}}
            @totalDescendantCount={{@post.total_descendant_count}}
            @depth={{@depth}}
            @sort={{@sort}}
            @replyToPost={{@replyToPost}}
            @editPost={{@editPost}}
            @deletePost={{@deletePost}}
            @recoverPost={{@recoverPost}}
            @showFlags={{@showFlags}}
            @collapseParent={{this.toggleExpanded}}
            @highlightParentLine={{this.highlightLine}}
            @unhighlightParentLine={{this.unhighlightLine}}
            @parentLineHighlighted={{this.lineHighlighted}}
            @postScreenTracker={{@postScreenTracker}}
          />
        {{/if}}
      </div>
    </div>
  </template>
}
