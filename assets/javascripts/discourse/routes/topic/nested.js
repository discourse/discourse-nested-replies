import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";

export default class TopicNestedRoute extends DiscourseRoute {
  @service composer;

  async model() {
    // eslint-disable-next-line no-console
    console.log("[nested route] model hook called");

    // Get the parent topic model
    const topic = this.modelFor("topic");

    // eslint-disable-next-line no-console
    console.log("[nested route] got topic model", {
      topicId: topic?.id,
      topicTitle: topic?.title,
      hasPostStream: !!topic?.postStream,
    });

    return topic;
  }

  async afterModel(model) {
    // eslint-disable-next-line no-console
    console.log("[nested route] afterModel called", {
      modelId: model?.id,
      hasDetails: !!model?.details,
      canCreatePost: model?.details?.can_create_post,
      hasTitle: !!model?.title,
    });

    await super.afterModel(...arguments);

    // Wait for the topic to be fully loaded (including details)
    // This happens when the postStream loads initially
    const postStream = model.postStream;

    // If the topic isn't fully loaded yet, wait for the postStream to load
    if (!model.title || !model.details) {
      // eslint-disable-next-line no-console
      console.log("[nested route] topic not fully loaded, waiting for postStream to load");

      // The postStream.refresh() will load the topic details
      if (!postStream.loaded) {
        await postStream.refresh();
        // eslint-disable-next-line no-console
        console.log("[nested route] postStream loaded, topic now has", {
          title: model.title,
          hasDetails: !!model.details,
          canCreatePost: model.details?.can_create_post,
        });
      }
    }

    // Clear thread data if coming from thread mode
    if (postStream.threadData) {
      postStream.set("threadData", null);
    }

    // Set display mode to nested
    postStream.setProperties({
      displayMode: "nested",
      hideTimeline: true,
    });

    // eslint-disable-next-line no-console
    console.log("[nested route] set nested mode, loading nested data");

    // Load nested data (always reload to ensure fresh data)
    await postStream.loadNested({ page: 1 });
    // eslint-disable-next-line no-console
    console.log("[nested route] nested data loaded", {
      hasNestedPosts: !!postStream.nestedData?.nested_posts,
      postCount: postStream.nestedData?.nested_posts?.length,
    });
  }

  setupController(controller, model) {
    // eslint-disable-next-line no-console
    console.log("[nested route] setupController called", {
      controller: controller,
      controllerName: controller?.constructor?.name,
      model: model,
      modelId: model?.id,
    });

    // Call parent setupController to properly initialize the topic controller
    super.setupController(controller, model);

    // Get the topic controller (since we're rendering with it)
    const topicController = this.controllerFor("topic");

    // eslint-disable-next-line no-console
    console.log("[nested route] got topic controller", {
      topicController: topicController,
      isSameAsController: topicController === controller,
      topicControllerModel: topicController.model?.id,
    });

    // Set up the topic controller exactly like the parent route does
    topicController.setProperties({
      model,
      editingTopic: false,
      firstPostExpanded: false,
    });

    // eslint-disable-next-line no-console
    console.log("[nested route] after setting properties", {
      topicControllerModel: topicController.model?.id,
      topicControllerModelTitle: topicController.model?.title,
    });

    // Set composer topic
    this.composer.set("topic", model);

    // eslint-disable-next-line no-console
    console.log("[nested route] composer topic set", {
      composerTopic: this.composer.topic?.id,
    });
  }

  renderTemplate() {
    // eslint-disable-next-line no-console
    console.log("[nested route] renderTemplate called");

    // Render the parent topic template with the parent topic controller
    // This ensures all actions (reply, edit, etc.) are available
    this.render("topic", {
      controller: "topic",
    });

    // eslint-disable-next-line no-console
    console.log("[nested route] rendered topic template with topic controller");
  }

  resetController(controller, isExiting) {
    super.resetController(controller, isExiting);

    if (isExiting) {
      // Get the actual topic controller
      const topicController = this.controllerFor("topic");
      const topic = topicController.model;

      if (topic?.postStream) {
        topic.postStream.setProperties({
          displayMode: null,
          nestedData: null,
          nestedCurrentPage: 1,
          hideTimeline: false,
        });
      }
    }
  }
}
