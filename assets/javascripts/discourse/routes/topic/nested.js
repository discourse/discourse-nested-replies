import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";

export default class TopicNestedRoute extends DiscourseRoute {
  @service composer;

  async model() {
    return this.modelFor("topic");
  }

  async afterModel(model) {
    await super.afterModel(...arguments);

    const postStream = model.postStream;

    if (!model.title || !model.details) {
      if (!postStream.loaded) {
        await postStream.refresh();
      }
    }

    if (postStream.threadData) {
      postStream.set("threadData", null);
    }

    postStream.setProperties({
      displayMode: "nested",
      hideTimeline: true,
    });

    await postStream.loadNested({ page: 1 });
  }

  setupController(controller, model) {
    super.setupController(controller, model);

    const topicController = this.controllerFor("topic");
    topicController.setProperties({
      model,
      editingTopic: false,
      firstPostExpanded: false,
    });

    this.composer.set("topic", model);
  }

  resetController(controller, isExiting) {
    super.resetController(controller, isExiting);

    if (isExiting) {
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
