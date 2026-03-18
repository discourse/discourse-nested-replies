import Component from "@glimmer/component";
import { action } from "@ember/object";
import { i18n } from "discourse-i18n";

const FIELD_NAME = "nested_replies_default_for_category";

export default class NestedRepliesSettingsUpsert extends Component {
  static shouldRender(args, context) {
    return context.siteSettings.enable_simplified_category_creation;
  }

  get enabled() {
    const value =
      this.args.outletArgs.transientData?.custom_fields?.[FIELD_NAME];
    return value?.toString() === "true";
  }

  @action
  async onToggle(_, { set, name }) {
    await set(name, this.enabled ? "false" : "true");
  }

  <template>
    {{#let @outletArgs.form as |form|}}
      <form.Section @title={{i18n "discourse_nested_replies.nested_view"}}>
        <form.Object @name="custom_fields" as |customFields|>
          <customFields.Field
            @name={{FIELD_NAME}}
            @title={{i18n
              "discourse_nested_replies.category_settings.default_nested_view"
            }}
            @onSet={{this.onToggle}}
            as |field|
          >
            <field.Checkbox checked={{this.enabled}} />
          </customFields.Field>
        </form.Object>
      </form.Section>
    {{/let}}
  </template>
}
