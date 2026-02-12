import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.nested_replies_enabled) {
    return;
  }

  const router = api.container.lookup("service:router");
  const appEvents = api.container.lookup("service:app-events");
  let previousRouteName = null;
  let composerSavedFromNested = false;

  appEvents.on("composer:saved", () => {
    const route = router.currentRouteName;
    if (route?.startsWith("nested")) {
      composerSavedFromNested = true;
    }
  });

  const originalRouteTo = DiscourseURL.routeTo;
  DiscourseURL.routeTo = function (path, opts) {
    if (composerSavedFromNested && /^\/t\//.test(path)) {
      composerSavedFromNested = false;
      return;
    }
    return originalRouteTo.call(DiscourseURL, path, opts);
  };

  router.on("routeDidChange", () => {
    const routeName = router.currentRouteName;

    if (
      routeName === "topic.fromParams" ||
      routeName === "topic.fromParamsNear"
    ) {
      if (previousRouteName?.startsWith("nested")) {
        previousRouteName = routeName;
        return;
      }

      const topicController = api.container.lookup("controller:topic");
      const topic = topicController?.model;
      if (!topic) {
        previousRouteName = routeName;
        return;
      }

      const isDefault =
        topic.category?.nested_replies_default ||
        siteSettings.nested_replies_default;

      if (!isDefault) {
        previousRouteName = routeName;
        return;
      }

      const nearPost =
        routeName === "topic.fromParamsNear"
          ? router.currentRoute?.params?.nearPost
          : null;
      const queryParams = nearPost ? { post_number: nearPost } : {};

      previousRouteName = routeName;
      router.replaceWith("nested", topic.slug, topic.id, { queryParams });
      return;
    }

    previousRouteName = routeName;
  });
});
