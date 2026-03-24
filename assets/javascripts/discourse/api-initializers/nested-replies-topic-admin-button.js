import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  api.addTopicAdminMenuButton((topic) => {
    if (!siteSettings.nested_replies_enabled) {
      return;
    }

    if (!api.getCurrentUser()?.staff) {
      return;
    }

    const isNested = topic.get("is_nested_view");

    return {
      icon: "nested-thread",
      className: "topic-admin-nested-replies",
      label: isNested
        ? "discourse_nested_replies.topic_admin_menu.disable_nested_replies"
        : "discourse_nested_replies.topic_admin_menu.enable_nested_replies",
      action: () => {
        const newValue = !isNested;
        const topicId = topic.get("id");
        const slug = topic.get("slug");

        ajax(`/nested/${slug}/${topicId}/toggle`, {
          type: "PUT",
          data: { enabled: newValue },
        })
          .then(() => {
            topic.set("is_nested_view", newValue || null);

            if (newValue) {
              DiscourseURL.routeTo(`/nested/${slug}/${topicId}`);
            } else {
              DiscourseURL.routeTo(`/t/${slug}/${topicId}`);
            }
          })
          .catch(popupAjaxError);
      },
    };
  });
});
