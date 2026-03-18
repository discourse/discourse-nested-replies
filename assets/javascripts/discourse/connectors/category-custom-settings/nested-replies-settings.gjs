import Component from "@glimmer/component";
import { Input } from "@ember/component";
import { i18n } from "discourse-i18n";

export default class NestedRepliesSettings extends Component {
  static shouldRender(args, context) {
    return !context.siteSettings.enable_simplified_category_creation;
  }

  <template>
    <section class="field">
      <h3>{{i18n "discourse_nested_replies.nested_view"}}</h3>
      <div class="enable-nested-replies-default">
        <label class="checkbox-label">
          <Input
            @type="checkbox"
            @checked={{@outletArgs.category.custom_fields.nested_replies_default_for_category}}
          />
          {{i18n
            "discourse_nested_replies.category_settings.default_nested_view"
          }}
        </label>
      </div>
    </section>
  </template>
}
