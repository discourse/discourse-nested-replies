import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { i18n } from "discourse-i18n";
import NestedSortDropdown from "../../components/nested-sort-dropdown";

export default class NestedViewToggle extends Component {
  @service siteSettings;
  @service appEvents;

  @tracked currentSort = "chronological";

  get shouldShow() {
    return this.siteSettings.nested_replies_enabled;
  }

  get isNestedView() {
    return this.args.outletArgs.model?.postStream?.isNestedMode;
  }

  @action
  async onSortChange(sortId) {
    const postStream = this.args.outletArgs.model?.postStream;
    if (postStream && postStream.isNestedMode) {
      this.currentSort = sortId;
      postStream.set("nestedSort", sortId);
      postStream.set("nestedCurrentPage", 1);
      await postStream.loadNested({ page: 1, sort: sortId });
    }
  }

  @action
  async switchToChronological() {
    const postStream = this.args.outletArgs.model?.postStream;
    if (postStream) {
      this.currentSort = "chronological";
      postStream.setProperties({
        displayMode: null,
        nestedData: null,
        nestedCurrentPage: 1,
        hideTimeline: false,
      });
      // Reload chronological view if needed
      if (!postStream.loaded || postStream.posts.length === 0) {
        await postStream.refresh();
      }
      // Notify that view mode changed so timeline can re-check
      this.appEvents.trigger("topic:view-mode-changed");
    }
  }

  @action
  async switchToNested() {
    const postStream = this.args.outletArgs.model?.postStream;
    if (postStream) {
      this.currentSort = "chronological";
      postStream.setProperties({
        displayMode: "nested",
        hideTimeline: true,
      });
      // Load nested data if not already loaded
      if (!postStream.nestedData) {
        await postStream.loadNested({ page: 1 });
      }
      // Notify that view mode changed so timeline can re-check
      this.appEvents.trigger("topic:view-mode-changed");
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
