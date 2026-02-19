import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { htmlSafe } from "@ember/template";
import { modifier } from "ember-modifier";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import DButton from "discourse/components/d-button";
import LoadMore from "discourse/components/load-more";
import PostAvatar from "discourse/components/post/avatar";
import PostCookedHtml from "discourse/components/post/cooked-html";
import PostMenu from "discourse/components/post/menu";
import PostMetaData from "discourse/components/post/meta-data";
import TopicCategory from "discourse/components/topic-category";
import TopicCategoryTagEditor from "discourse/components/topic-category-tag-editor";
import TopicMap from "discourse/components/topic-map";
import TopicTitleEditor from "discourse/components/topic-title-editor";
import icon from "discourse/helpers/d-icon";
import getURL from "discourse/lib/get-url";
import { eq, gt } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import NestedPost from "./nested-post";
import NestedSortSelector from "./nested-sort-selector";

export default class NestedView extends Component {
  trackOpPost = modifier((element) => {
    this.args.postScreenTracker?.observe(element, this.args.opPost);
    return () => this.args.postScreenTracker?.unobserve(element);
  });

  // Core's TopicMap requires a @postStream arg for flat-view features
  // (filtering by participant, "Top Replies" toggle). The nested view has
  // no PostStream, so we supply a stub that satisfies the interface with
  // safe no-ops. The "Top Replies" button is hidden via CSS.
  get postStreamStub() {
    return {
      summary: false,
      loadingFilter: false,
      userFilters: [],
      showTopReplies() {},
      cancelFilter() {},
      refresh() {},
    };
  }

  get flatViewUrl() {
    return getURL(`/t/${this.args.topic.slug}/${this.args.topic.id}?flat=1`);
  }

  <template>
    <div class="nested-view">
      <div class="nested-view__header">
        {{#if @editingTopic}}
          <div class="edit-topic-title">
            <TopicTitleEditor
              @bufferedTitle={{@buffered.title}}
              @model={{@topic}}
              @buffered={{@buffered}}
            />

            <TopicCategoryTagEditor
              @buffered={{@buffered}}
              @model={{@topic}}
              @showCategoryChooser={{@showCategoryChooser}}
              @canEditTags={{@canEditTags}}
              @minimumRequiredTags={{@minimumRequiredTags}}
              @onSave={{@finishedEditingTopic}}
              @onCancel={{@cancelEditingTopic}}
              @topicCategoryChanged={{@topicCategoryChanged}}
              @topicTagsChanged={{@topicTagsChanged}}
            />
          </div>
        {{else}}
          <h1 class="nested-view__title">
            <a
              href={{@topic.url}}
              {{on "click" @startEditingTopic}}
              class="fancy-title"
            >
              {{htmlSafe @topic.fancyTitle~}}
              {{~#if @topic.details.can_edit~}}
                <span class="edit-topic__wrapper">
                  {{icon "pencil" class="edit-topic"}}
                </span>
              {{~/if}}
            </a>
          </h1>
          <TopicCategory @topic={{@topic}} class="topic-category" />
        {{/if}}
      </div>

      {{#if @opPost}}
        <div class="nested-view__op">
          <article class="nested-view__op-article" {{this.trackOpPost}}>
            <div class="nested-view__op-row">
              <PostAvatar @post={{@opPost}} />
              <div class="nested-view__op-body">
                <PostMetaData
                  @post={{@opPost}}
                  @editPost={{@editPost}}
                  @showHistory={{fn @showHistory @opPost}}
                />
                <div class="nested-view__op-content">
                  <PostCookedHtml @post={{@opPost}} />
                </div>
                <section class="nested-view__op-menu post-menu-area clearfix">
                  <PostMenu
                    @post={{@opPost}}
                    @canCreatePost={{true}}
                    @replyToPost={{@replyToPost}}
                    @editPost={{@editPost}}
                    @toggleLike={{this.toggleOpLike}}
                    @showLogin={{this.noop}}
                  />
                </section>
              </div>
            </div>
          </article>
        </div>
      {{/if}}

      <div class="nested-view__topic-map topic-map">
        <TopicMap
          @model={{@topic}}
          @topicDetails={{@topic.details}}
          @postStream={{this.postStreamStub}}
          @showPMMap={{@topic.isPrivateMessage}}
        />
      </div>

      <div class="nested-view__controls">
        <NestedSortSelector @current={{@sort}} @onChange={{@changeSort}} />
        <a href={{this.flatViewUrl}} class="nested-view__flat-link">{{i18n
            "discourse_nested_replies.view_as_flat"
          }}</a>
      </div>

      {{#if (gt @newRootPostCount 0)}}
        <div class="nested-view__new-replies">
          <DButton
            class="btn-primary nested-view__new-replies-btn"
            @action={{@loadNewRoots}}
            @translatedLabel={{i18n
              "discourse_nested_replies.new_replies"
              count=@newRootPostCount
            }}
          />
        </div>
      {{/if}}

      <div class="nested-view__roots">
        {{#each @rootNodes as |node|}}
          <NestedPost
            @post={{node.post}}
            @children={{node.children}}
            @topic={{@topic}}
            @depth={{0}}
            @sort={{@sort}}
            @isPinned={{eq node.post.post_number @pinnedPostNumber}}
            @replyToPost={{@replyToPost}}
            @editPost={{@editPost}}
            @deletePost={{@deletePost}}
            @recoverPost={{@recoverPost}}
            @showFlags={{@showFlags}}
            @showHistory={{@showHistory}}
            @postScreenTracker={{@postScreenTracker}}
          />
        {{else}}
          <div class="nested-view__empty">
            {{i18n "discourse_nested_replies.no_replies"}}
          </div>
        {{/each}}
      </div>

      <ConditionalLoadingSpinner @condition={{@loadingMore}} />

      <LoadMore
        @action={{@loadMoreRoots}}
        @enabled={{@hasMoreRoots}}
        @isLoading={{@loadingMore}}
      />
    </div>
  </template>

  @action
  async toggleOpLike() {
    const post = this.args.opPost;
    const likeAction = post.likeAction;
    if (likeAction?.canToggle) {
      await likeAction.togglePromise(post);
    }
  }

  noop() {}
}
