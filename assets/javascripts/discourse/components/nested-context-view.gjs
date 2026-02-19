import Component from "@glimmer/component";
import { array, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { schedule } from "@ember/runloop";
import { htmlSafe } from "@ember/template";
import { modifier } from "ember-modifier";
import DButton from "discourse/components/d-button";
import PostAvatar from "discourse/components/post/avatar";
import PostCookedHtml from "discourse/components/post/cooked-html";
import PostMetaData from "discourse/components/post/meta-data";
import TopicCategory from "discourse/components/topic-category";
import TopicCategoryTagEditor from "discourse/components/topic-category-tag-editor";
import TopicTitleEditor from "discourse/components/topic-title-editor";
import icon from "discourse/helpers/d-icon";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import NestedPost from "./nested-post";
import NestedSortSelector from "./nested-sort-selector";

export default class NestedContextView extends Component {
  trackOpPost = modifier((element) => {
    this.args.postScreenTracker?.observe(element, this.args.opPost);
    return () => this.args.postScreenTracker?.unobserve(element);
  });

  constructor() {
    super(...arguments);
    schedule("afterRender", this, this._scrollToTarget);
  }

  get flatViewUrl() {
    return getURL(`/t/${this.args.topic.slug}/${this.args.topic.id}?flat=1`);
  }

  _scrollToTarget() {
    const postNumber = this.args.targetPostNumber;
    if (!postNumber) {
      return;
    }

    requestAnimationFrame(() => {
      const target = document.querySelector(
        `.nested-context-view [data-post-number="${postNumber}"]`
      );
      if (target) {
        const postEl = target.closest(".nested-post");
        if (postEl) {
          postEl.classList.add("nested-post--highlighted");
        }
        target.scrollIntoView({ behavior: "smooth", block: "center" });
      }
    });
  }

  <template>
    <div class="nested-view nested-context-view">
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

      <div class="nested-context-view__nav">
        <DButton
          class="btn-flat nested-context-view__full-thread"
          @action={{@viewFullThread}}
          @translatedLabel={{i18n
            "discourse_nested_replies.context.view_full_thread"
          }}
        />
        {{#if @contextNoAncestors}}
          <DButton
            class="btn-flat nested-context-view__parent-context"
            @action={{@viewParentContext}}
            @translatedLabel={{i18n
              "discourse_nested_replies.context.view_parent_context"
            }}
          />
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
              </div>
            </div>
          </article>
        </div>
      {{/if}}

      <div class="nested-view__controls">
        <NestedSortSelector @current={{@sort}} @onChange={{@changeSort}} />
        <a href={{this.flatViewUrl}} class="nested-view__flat-link">{{i18n
            "discourse_nested_replies.view_as_flat"
          }}</a>
      </div>

      {{#if @contextChain}}
        <div class="nested-context-view__chain">
          {{! Use each+key to force full component recreation when the chain root changes,
              e.g. navigating from context=0 to full ancestor view }}
          {{#each (array @contextChain) key="post.id" as |chainRoot|}}
            <NestedPost
              @post={{chainRoot.post}}
              @children={{chainRoot.children}}
              @topic={{@topic}}
              @depth={{0}}
              @sort={{@sort}}
              @replyToPost={{@replyToPost}}
              @editPost={{@editPost}}
              @deletePost={{@deletePost}}
              @recoverPost={{@recoverPost}}
              @showFlags={{@showFlags}}
              @showHistory={{@showHistory}}
              @postScreenTracker={{@postScreenTracker}}
            />
          {{/each}}
        </div>
      {{/if}}
    </div>
  </template>
}
