import { apiInitializer } from "discourse/lib/api";
import NestedRepliesExpandButton from "../components/nested-replies-expand-button";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  api.registerValueTransformer("post-menu-buttons", ({ value: dag }) => {
    if (!siteSettings.nested_replies_enabled) {
      return;
    }

    const router = api.container.lookup("service:router");
    if (router.currentRouteName?.startsWith("nested")) {
      dag.delete("replies");
    }

    dag.add("nested-replies-expand", NestedRepliesExpandButton);
  });

  api.addPostAdminMenuButton((post) => {
    if (!siteSettings.nested_replies_enabled) {
      return;
    }

    const container = api.container;
    const router = container.lookup("service:router");
    if (!router.currentRouteName?.startsWith("nested")) {
      return;
    }

    // Only show on root-level posts (not OP, not nested children)
    if (post.post_number === 1) {
      return;
    }
    if (post.reply_to_post_number && post.reply_to_post_number !== 1) {
      return;
    }

    const nestedController = container.lookup("controller:nested");
    const isPinned = nestedController?.pinnedPostNumber === post.post_number;

    return {
      icon: "thumbtack",
      label: isPinned
        ? "discourse_nested_replies.unpin_reply"
        : "discourse_nested_replies.pin_reply",
      className: "pin-reply",
      action: () => {
        nestedController?.togglePinPost(post);
      },
    };
  });
});
