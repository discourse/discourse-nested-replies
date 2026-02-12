import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";
import Category from "discourse/models/category";

const TOPIC_URL_RE = /^\/t\/([^/]+)\/(\d+)(?:\/(\d+))?$/;

function buildNestedPath(slug, topicId, postNumber) {
  let path = `/nested/${slug}/${topicId}`;
  if (postNumber) {
    path += `?post_number=${postNumber}`;
  }
  return path;
}

function isNestedDefault(siteSettings, categoryId) {
  if (siteSettings.nested_replies_default) {
    return true;
  }

  if (categoryId) {
    const category = Category.findById(categoryId);
    if (category?.nested_replies_default) {
      return true;
    }
  }

  return false;
}

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.nested_replies_enabled) {
    return;
  }

  const router = api.container.lookup("service:router");
  const session = api.container.lookup("service:session");
  const appEvents = api.container.lookup("service:app-events");
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

    const match = TOPIC_URL_RE.exec(path);
    if (match) {
      const [, slug, topicId, postNumber] = match;
      const id = parseInt(topicId, 10);

      // For site-wide default we can redirect immediately.
      // For per-category default, look up the category from the
      // session's topic list (populated by the homepage/discovery).
      let categoryId;
      const topic = session.topicList?.topics?.find((t) => t.id === id);
      if (topic) {
        categoryId = topic.category_id;
      }

      if (isNestedDefault(siteSettings, categoryId)) {
        const nestedPath = buildNestedPath(slug, topicId, postNumber);
        return originalRouteTo.call(DiscourseURL, nestedPath, opts);
      }
    }

    return originalRouteTo.call(DiscourseURL, path, opts);
  };

  // Fallback: if a topic URL wasn't intercepted in routeTo (e.g. direct
  // navigation where we didn't have the category cached), redirect after
  // the topic route loads and we can inspect the model.
  let previousRouteName = null;

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

      if (!isNestedDefault(siteSettings, topic.category_id)) {
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
