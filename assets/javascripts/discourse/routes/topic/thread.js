import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class TopicThreadRoute extends DiscourseRoute {
  @service composer;

  async model(params) {
    const topic = this.modelFor("topic");
    const postNumber = parseInt(params.post_number, 10);

    const data = await ajax(
      `/t/${topic.slug}/${topic.id}/thread/${postNumber}.json`
    );

    const postStream = topic.postStream;
    const nestedPosts = data.nested_posts.map((node) => ({
      ...node,
      post: postStream._getOrCreatePost(node.post),
      replies: node.replies.map((reply) => postStream._getOrCreatePost(reply)),
    }));

    return {
      topic,
      nestedPosts,
      meta: data.meta,
      postNumber,
    };
  }

  async afterModel(model) {
    await super.afterModel(...arguments);

    const postStream = model.topic.postStream;

    if (!model.topic.title || !model.topic.details) {
      if (!postStream.loaded) {
        await postStream.refresh();
      }
    }
  }

  setupController(controller, model) {
    super.setupController(controller, model);

    const topicController = this.controllerFor("topic");
    topicController.setProperties({
      model: model.topic,
      editingTopic: false,
      firstPostExpanded: false,
    });

    this.composer.set("topic", model.topic);

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

  resetController(controller, isExiting, transition) {
    super.resetController(controller, isExiting, transition);

    if (isExiting) {
      const isTransitioningToNested =
        transition?.targetName === "topic.nested";

      const topic = this.modelFor("topic");
      if (topic?.postStream) {
        topic.postStream.set("threadData", null);

        if (!isTransitioningToNested) {
          topic.postStream.setProperties({
            displayMode: null,
            hideTimeline: false,
          });
        }
      }
    }
  }
}
