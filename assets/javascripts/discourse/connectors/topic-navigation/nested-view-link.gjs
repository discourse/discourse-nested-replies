import Component from "@glimmer/component";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";

export default class NestedViewLink extends Component {
  static shouldRender(args, context) {
    return context.siteSettings.nested_replies_enabled;
  }

  get nestedUrl() {
    const topic = this.args.outletArgs.topic;
    return getURL(`/nested/${topic.slug}/${topic.id}`);
  }

  <template>
    <a href={{this.nestedUrl}} class="nested-view-link">{{i18n
        "discourse_nested_replies.view_as_nested"
      }}</a>
  </template>
}
