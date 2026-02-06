import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class TopicThreadRoute extends DiscourseRoute {
  @service store;
  @service composer;

  async model(params) {
    // eslint-disable-next-line no-console
    console.log("[thread route] model hook called", { params });

    const topic = this.modelFor("topic");
    const postNumber = parseInt(params.post_number, 10);

    // eslint-disable-next-line no-console
    console.log("[thread route] got topic model", {
      topicId: topic?.id,
      topicTitle: topic?.title,
      hasPostStream: !!topic?.postStream,
      hasDetails: !!topic?.details,
      canCreatePost: topic?.details?.can_create_post,
    });

    try {
      // Fetch thread data from backend
      const data = await ajax(
        `/t/${topic.slug}/${topic.id}/thread/${postNumber}.json`
      );

      // eslint-disable-next-line no-console
      console.log("[thread route] fetched thread data", {
        nestedPostsCount: data.nested_posts?.length,
        meta: data.meta,
      });

      // Convert to Post models
      const nestedPosts = this._convertNestedData(data.nested_posts, topic);

      return {
        topic,
        nestedPosts,
        meta: data.meta,
        postNumber,
        loaded: true,
      };
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error("Failed to load thread:", error);
      throw error;
    }
  }

  async afterModel(model) {
    // eslint-disable-next-line no-console
    console.log("[thread route] afterModel called", {
      modelTopicId: model?.topic?.id,
      hasDetails: !!model?.topic?.details,
      canCreatePost: model?.topic?.details?.can_create_post,
      hasTitle: !!model?.topic?.title,
    });

    await super.afterModel(...arguments);

    // Wait for the topic to be fully loaded (including details)
    // This happens when the postStream loads initially
    const postStream = model.topic.postStream;

    // If the topic isn't fully loaded yet, wait for the postStream to load
    if (!model.topic.title || !model.topic.details) {
      // eslint-disable-next-line no-console
      console.log("[thread route] topic not fully loaded, waiting for postStream to load");

      // The postStream.refresh() will load the topic details
      if (!postStream.loaded) {
        await postStream.refresh();
        // eslint-disable-next-line no-console
        console.log("[thread route] postStream loaded, topic now has", {
          title: model.topic.title,
          hasDetails: !!model.topic.details,
          canCreatePost: model.topic.details?.can_create_post,
        });
      }
    } else {
      // eslint-disable-next-line no-console
      console.log("[thread route] topic already fully loaded");
    }
  }

  // Don't override renderTemplate - let it render normally
  // The template will render into the {{outlet}} in the topic template

  setupController(controller, model) {
    // eslint-disable-next-line no-console
    console.log("[thread route] setupController called", {
      controller: controller,
      controllerName: controller?.constructor?.name,
      model: model,
      modelTopicId: model?.topic?.id,
      modelTopicTitle: model?.topic?.title,
    });

    super.setupController(controller, model);

    // Get the parent topic controller and set it up properly
    const topicController = this.controllerFor("topic");

    // eslint-disable-next-line no-console
    console.log("[thread route] got topic controller", {
      topicController: topicController,
      isSameAsController: topicController === controller,
      topicControllerModel: topicController.model?.id,
    });

    topicController.setProperties({
      model: model.topic,
      editingTopic: false,
      firstPostExpanded: false,
    });

    // eslint-disable-next-line no-console
    console.log("[thread route] after setting properties", {
      topicControllerModel: topicController.model?.id,
      topicControllerModelTitle: topicController.model?.title,
    });

    // Set composer topic
    this.composer.set("topic", model.topic);

    // eslint-disable-next-line no-console
    console.log("[thread route] composer topic set", {
      composerTopic: this.composer.topic?.id,
    });

    // Mark the postStream as loaded and set display mode
    // Store thread data on postStream for connector access
    if (model.topic?.postStream) {
      model.topic.postStream.setProperties({
        loaded: true,
        displayMode: "thread",
        hideTimeline: true,
        threadData: {
          nestedPosts: model.nestedPosts,
          meta: model.meta,
        },
      });

      // eslint-disable-next-line no-console
      console.log("[thread route] postStream configured with thread data");
    }
  }

  _convertNestedData(nestedPosts, topic) {
    return nestedPosts.map((node) => ({
      ...node,
      post: this._createPost(node.post, topic),
      replies: node.replies.map((reply) => this._createPost(reply, topic)),
    }));
  }

  _createPost(postData, topic) {
    return this.store.createRecord("post", {
      ...postData,
      topic,
    });
  }

  resetController(controller, isExiting) {
    super.resetController(controller, isExiting);

    if (isExiting) {
      const topic = controller.topic;
      if (topic?.postStream) {
        topic.postStream.setProperties({
          displayMode: null,
          hideTimeline: false,
          threadData: null,
        });
      }
    }
  }
}
