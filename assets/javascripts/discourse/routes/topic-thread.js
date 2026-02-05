import DiscourseRoute from "discourse/routes/discourse";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

export default class TopicThreadRoute extends DiscourseRoute {
  @service store;

  async model(params) {
    const topic = this.modelFor("topic");
    const postNumber = parseInt(params.post_number, 10);

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
    };
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
}
