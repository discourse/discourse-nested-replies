import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class TopicThreadRoute extends DiscourseRoute {
  @service store;
  @service composer;

  async model(params) {
    const topic = this.modelFor("topic");
    const postNumber = parseInt(params.post_number, 10);

    // Ensure the topic is fully loaded before fetching thread data
    if (!topic.title || !topic.details) {
      const postStream = topic.postStream;
      if (!postStream.loaded) {
        await postStream.refresh();
      }
    }

    try {
      // Fetch thread data from backend
      const data = await ajax(
        `/t/${topic.slug}/${topic.id}/thread/${postNumber}.json`
      );

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

  // Don't override renderTemplate - let it render normally
  // The template will render into the {{outlet}} in the topic template

  setupController(controller, model) {
    super.setupController(controller, model);

    // Get the parent topic controller and set it up properly
    const topicController = this.controllerFor("topic");

    topicController.setProperties({
      model: model.topic,
      editingTopic: false,
      firstPostExpanded: false,
    });

    // Set composer topic
    this.composer.set("topic", model.topic);

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
