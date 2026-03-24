import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";
import nestedPostUrl from "../lib/nested-post-url";

const TOPIC_URL_RE = /^\/t\/([^/]+)\/(\d+)(?:\/(\d+))?(?:\?(.*))?$/;

function buildNestedPath(slug, topicId, postNumber) {
  let path = `/nested/${slug}/${topicId}`;
  if (postNumber) {
    path += `?post_number=${postNumber}`;
  }
  return path;
}

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const router = api.container.lookup("service:router");
  const appEvents = api.container.lookup("service:app-events");
  let composerSaveInfo = null;

  // Tracks which topic IDs have is_nested_view, populated as topics
  // flow through topic lists and topic view responses.
  const nestedTopicIds = new Set();

  api.registerValueTransformer(
    "topic-list-item-class",
    ({ value, context }) => {
      if (context.topic?.is_nested_view) {
        nestedTopicIds.add(context.topic.id);
      }
      return value;
    }
  );

  api.registerValueTransformer(
    "latest-topic-list-item-class",
    ({ value, context }) => {
      if (context.topic?.is_nested_view) {
        nestedTopicIds.add(context.topic.id);
      }
      return value;
    }
  );

  appEvents.on("composer:saved", () => {
    if (!siteSettings.nested_replies_enabled) {
      return;
    }

    const route = router.currentRouteName;
    if (route?.startsWith("nested")) {
      const nestedController = api.container.lookup("controller:nested");
      composerSaveInfo = {
        topicId: nestedController?.topic?.id,
        time: Date.now(),
      };
    }
  });

  api.registerValueTransformer("post-share-url", ({ value, context }) => {
    if (!siteSettings.nested_replies_enabled) {
      return value;
    }

    if (router.currentRouteName !== "nested") {
      return value;
    }

    const post = context.post;
    const topic = post.topic;
    if (!topic) {
      return value;
    }

    return nestedPostUrl(topic, post.post_number);
  });

  api.registerValueTransformer(
    "topic-url-for-post-number",
    ({ value, context }) => {
      if (!siteSettings.nested_replies_enabled) {
        return value;
      }

      const currentRoute = router.currentRouteName;
      if (
        currentRoute === "topic.fromParams" ||
        currentRoute === "topic.fromParamsNear"
      ) {
        return value;
      }

      const { topic } = context;
      if (topic.is_nested_view) {
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
    if (!siteSettings.nested_replies_enabled) {
      return path;
    }

    // After composer save on nested route, suppress the redirect to flat view.
    // Returning null tells routeTo to abort navigation. Scoped to the same
    // topic and expires after 5 seconds to prevent stale flags from
    // suppressing unrelated navigations.
    if (composerSaveInfo && /^\/t\//.test(path)) {
      const match = TOPIC_URL_RE.exec(path);
      const elapsed = Date.now() - composerSaveInfo.time;
      const savedTopicId = composerSaveInfo.topicId;
      composerSaveInfo = null;
      if (match && parseInt(match[2], 10) === savedTopicId && elapsed < 5000) {
        return null;
      }
    }

    // If already in flat view, don't redirect to nested (e.g. timeline navigation).
    const currentRoute = router.currentRouteName;
    if (
      currentRoute === "topic.fromParams" ||
      currentRoute === "topic.fromParamsNear"
    ) {
      return path;
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

    if (nestedTopicIds.has(id)) {
      return buildNestedPath(slug, topicId, postNumber);
    }

    return path;
  });

  // Fallback: if a topic URL wasn't intercepted by the route-to-url
  // transformer (e.g. direct URL entry where the topic isn't known to
  // be nested yet), intercept before the topic route's model hook runs
  // and fetch topic info to check the is_nested_view field.
  const checkedTopicIds = new Map();
  const CHECKED_TOPIC_TTL_MS = 60_000;

  router.on("routeWillChange", (transition) => {
    if (!siteSettings.nested_replies_enabled) {
      return;
    }

    const toName = transition.to?.name;
    if (toName !== "topic.fromParams" && toName !== "topic.fromParamsNear") {
      return;
    }

    const currentRoute = router.currentRouteName;
    if (
      currentRoute === "nested" ||
      currentRoute === "topic.fromParams" ||
      currentRoute === "topic.fromParamsNear"
    ) {
      return;
    }

    const topicParams = transition.to.parent?.params;
    if (!topicParams) {
      return;
    }

    const topicId = parseInt(topicParams.id, 10);
    const slug = topicParams.slug;

    // Respect explicit ?flat param
    const urlParams = new URLSearchParams(window.location.search);
    if (urlParams.has("flat")) {
      return;
    }

    // If we already know this topic is nested, redirect immediately
    if (nestedTopicIds.has(topicId)) {
      transition.abort();
      const nearPost = transition.to?.params?.nearPost;
      const queryParams = {};
      if (nearPost) {
        queryParams.post_number = nearPost;
      }
      router.transitionTo("nested", slug, topicId, { queryParams });
      return;
    }

    // Already checked this topic recently and it wasn't nested — let it through
    const checkedAt = checkedTopicIds.get(topicId);
    if (checkedAt && Date.now() - checkedAt < CHECKED_TOPIC_TTL_MS) {
      return;
    }
    checkedTopicIds.set(topicId, Date.now());

    // Evict stale entries to prevent unbounded growth
    if (checkedTopicIds.size > 100) {
      const now = Date.now();
      for (const [id, time] of checkedTopicIds) {
        if (now - time > CHECKED_TOPIC_TTL_MS) {
          checkedTopicIds.delete(id);
        }
      }
    }

    const fromRoute = router.currentRouteName;
    transition.abort();

    ajax(`/t/${topicId}.json`, { data: { track_visit: false } })
      .then((data) => {
        // Bail if user navigated away during the async lookup
        if (router.currentRouteName !== fromRoute) {
          return;
        }

        if (data.is_nested_view) {
          nestedTopicIds.add(topicId);
          const queryParams = {};
          const nearPost = transition.to?.params?.nearPost;
          if (nearPost) {
            queryParams.post_number = nearPost;
          }
          router.transitionTo("nested", slug, topicId, { queryParams });
        } else {
          transition.retry();
        }
      })
      .catch(() => {
        if (router.currentRouteName !== fromRoute) {
          return;
        }
        transition.retry();
      });
  });
});
