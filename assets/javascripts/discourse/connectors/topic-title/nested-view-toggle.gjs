import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { i18n } from "discourse-i18n";
import NestedSortDropdown from "../../components/nested-sort-dropdown";

export default class NestedViewToggle extends Component {
  @service siteSettings;
  @service router;
  @tracked _currentSort = "chronological";

  get shouldShow() {
    if (!this.siteSettings.nested_replies_enabled) {
      return false;
    }

    const postStream = this.args.outletArgs.model?.postStream;
    return postStream?.displayMode !== "thread";
  }

  get isNestedView() {
    return this.args.outletArgs.model?.postStream?.isNestedMode;
  }

  get currentSort() {
    return this._currentSort;
  }

  get topic() {
    return this.args.outletArgs.model;
  }

  @action
  async onSortChange(sortId) {
    const postStream = this.args.outletArgs.model?.postStream;
    if (postStream?.isNestedMode) {
      this._currentSort = sortId;
      postStream.set("nestedSort", sortId);
      postStream.set("nestedCurrentPage", 1);
      await postStream.loadNested({ page: 1, sort: sortId });
    }
  }

  @action
  switchToChronological() {
    const topic = this.topic;
    if (topic) {
      this.router.transitionTo("topic", topic.slug, topic.id);
    }
  }

  @action
  switchToNested() {
    const topic = this.topic;
    if (topic) {
      this.router.transitionTo("topic.nested", topic.slug, topic.id);
    }
  }

  <template>
    {{#if this.shouldShow}}
      <div class="nested-view-toggle">
        <DButton
          @action={{this.switchToChronological}}
          @translatedLabel={{i18n "nested_replies.view_toggle.chronological"}}
          class="btn-flat {{unless this.isNestedView 'active'}}"
        />

        <DButton
          @action={{this.switchToNested}}
          @translatedLabel={{i18n "nested_replies.view_toggle.nested"}}
          class="btn-flat {{if this.isNestedView 'active'}}"
        />

        {{#if this.isNestedView}}
          <NestedSortDropdown
            @currentSort={{this.currentSort}}
            @onSortChange={{this.onSortChange}}
          />
        {{/if}}
      </div>
    {{/if}}
  </template>
}
