import { apiInitializer } from "discourse/lib/api";
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
  const appEvents = api.container.lookup("service:app-events");
  const topicTrackingState = api.container.lookup(
    "service:topic-tracking-state"
  );
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

  // Intercept topic URL routing via the route-to-url transformer.
  // This replaces a direct monkey-patch of DiscourseURL.routeTo with
  // the official value transformer API, which is composable and
  // conflict-free with other plugins.
  api.registerValueTransformer("route-to-url", ({ value: path }) => {
    // After composer save on nested route, suppress the redirect to flat view.
    // Returning null tells routeTo to abort navigation.
    if (composerSavedFromNested && /^\/t\//.test(path)) {
      composerSavedFromNested = false;
      return null;
    }

    const match = TOPIC_URL_RE.exec(path);
    if (!match) {
      return path;
    }

    const [, slug, topicId, postNumber, queryString] = match;

    // Respect explicit ?flat param to force flat view
    if (queryString) {
      const params = new URLSearchParams(queryString);
      if (params.has("flat")) {
        return path;
      }
    }

    const id = parseInt(topicId, 10);

    // Look up category from topic tracking state (most reliable source)
    // or fall back to session topic list for discovery-loaded topics.
    let categoryId;
    const trackedState = topicTrackingState.findState(id);
    if (trackedState) {
      categoryId = trackedState.category_id;
    }

    if (isNestedDefault(siteSettings, categoryId)) {
      return buildNestedPath(slug, topicId, postNumber);
    }

    return path;
  });

  // Fallback: if a topic URL wasn't intercepted by the route-to-url
  // transformer (e.g. direct URL entry where the topic isn't in tracking
  // state yet), intercept before the topic route's model hook runs.
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
    const tracked = topicTrackingState.findState(topicId);
    if (tracked) {
      categoryId = tracked.category_id;
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
