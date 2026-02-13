import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";
import Category from "discourse/models/category";

const TOPIC_URL_RE = /^\/t\/([^/]+)\/(\d+)(?:\/(\d+))?(?:\?(.*))?$/;

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

  api.registerValueTransformer(
    "topic-url-for-post-number",
    ({ value, context }) => {
      const { topic } = context;
      if (isNestedDefault(siteSettings, topic.category_id)) {
        const slug = topic.slug || "topic";
        return `/nested/${slug}/${topic.id}`;
      }
      return value;
    }
  );

  const originalRouteTo = DiscourseURL.routeTo;
  DiscourseURL.routeTo = function (path, opts) {
    if (composerSavedFromNested && /^\/t\//.test(path)) {
      composerSavedFromNested = false;
      return;
    }

    const match = TOPIC_URL_RE.exec(path);
    if (match) {
      const [, slug, topicId, postNumber, queryString] = match;

      if (queryString) {
        const params = new URLSearchParams(queryString);
        if (params.has("flat")) {
          return originalRouteTo.call(DiscourseURL, path, opts);
        }
      }

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
        // Convert post_number from path segment to query param for deep-linking.
        const nestedPath = buildNestedPath(slug, topicId, postNumber);
        return originalRouteTo.call(DiscourseURL, nestedPath, opts);
      }
    }

    return originalRouteTo.call(DiscourseURL, path, opts);
  };

  // Fallback: if a topic URL wasn't intercepted in routeTo (e.g. direct
  // navigation where we didn't have the category cached), intercept before
  // the topic route's model hook runs to avoid loading the full post stream.
  const topicTrackingState = api.container.lookup(
    "service:topic-tracking-state"
  );

  router.on("routeWillChange", (transition) => {
    const toName = transition.to?.name;
    if (toName !== "topic.fromParams" && toName !== "topic.fromParamsNear") {
      return;
    }

    if (router.currentRouteName?.startsWith("nested")) {
      return;
    }

    const topicParams = transition.to.parent?.params;
    if (!topicParams) {
      return;
    }

    const topicId = parseInt(topicParams.id, 10);
    const slug = topicParams.slug;

    let categoryId;
    const trackedState = topicTrackingState.findState(topicId);
    if (trackedState) {
      categoryId = trackedState.category_id;
    } else {
      const topic = session.topicList?.topics?.find((t) => t.id === topicId);
      if (topic) {
        categoryId = topic.category_id;
      }
    }

    if (!isNestedDefault(siteSettings, categoryId)) {
      return;
    }

    transition.abort();

    const nearPost = transition.to?.params?.nearPost;
    const queryParams = {};
    if (nearPost) {
      queryParams.post_number = nearPost;
    }

    router.transitionTo("nested", slug, topicId, { queryParams });
  });
});
