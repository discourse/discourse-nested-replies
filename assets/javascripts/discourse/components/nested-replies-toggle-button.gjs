import Component from "@glimmer/component";
import DButton from "discourse/components/d-button";
import concatClass from "discourse/helpers/concat-class";
import { i18n } from "discourse-i18n";

export default class NestedRepliesToggleButton extends Component {
  static extraControls = true;

  static shouldRender(args, _context, owner) {
    const router = owner.lookup("service:router");
    if (!router.currentRouteName?.startsWith("nested")) {
      return false;
    }

    const post = args.post;
    if (post.post_number === 1) {
      return false;
    }

    return (
      (post.direct_reply_count || 0) > 0 ||
      (post.total_descendant_count || 0) > 0
    );
  }

  get replyCount() {
    const post = this.args.post;
    return post.total_descendant_count || post.direct_reply_count || 0;
  }

  get label() {
    if (this.args.state.repliesShown) {
      return i18n("discourse_nested_replies.collapse");
    }
    return i18n("discourse_nested_replies.collapsed_replies", {
      count: this.replyCount,
    });
  }

  <template>
    <DButton
      class={{concatClass
        "post-action-menu__nested-replies-toggle btn-icon-text"
        (if @state.repliesShown "is-collapse")
      }}
      ...attributes
      @action={{@buttonActions.toggleReplies}}
      @icon={{if @state.repliesShown "chevron-up" "chevron-down"}}
      @translatedLabel={{this.label}}
    />
  </template>
}
