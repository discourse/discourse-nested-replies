import Route from "@ember/routing/route";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import PostScreenTracker from "discourse/lib/post-screen-tracker";
import processNode from "../lib/process-node";

export default class NestedRoute extends Route {
  @service header;
  @service screenTrack;
  @service store;

  queryParams = {
    sort: { refreshModel: true },
    post_number: { refreshModel: true },
    context: { refreshModel: true },
  };

  async model(params) {
    const { topic_id, slug, sort, post_number } = params;

    if (post_number) {
      const queryParts = [];
      if (sort) {
        queryParts.push(`sort=${sort}`);
      }
      if (params.context !== undefined && params.context !== null) {
        queryParts.push(`context=${params.context}`);
      }
      const contextQuery = queryParts.length ? `?${queryParts.join("&")}` : "";
      const data = await ajax(
        `/nested/${slug}/${topic_id}/context/${post_number}.json${contextQuery}`
      );
      return this._processContextResponse(data, params);
    }

    const queryParts = [];
    if (sort) {
      queryParts.push(`sort=${sort}`);
    }
    const query = queryParts.length ? `?${queryParts.join("&")}` : "";

    const data = await ajax(`/nested/${slug}/${topic_id}/roots.json${query}`);
    return this._processResponse(data, params);
  }

  setupController(controller, model) {
    controller.setProperties(model);
    controller.subscribe();

    controller.postScreenTracker = new PostScreenTracker(this.screenTrack, {
      headerOffset: this.header.headerOffset,
    });
    this.screenTrack.start(model.topic.id, controller);
  }

  deactivate() {
    super.deactivate(...arguments);
    this.controller.unsubscribe();
    this.screenTrack.stop();
    this.controller.postScreenTracker?.destroy();
    this.controller.postScreenTracker = null;
  }

  _processResponse(data, params) {
    const topic = this.store.createRecord("topic", data.topic);

    const assignTopic = (postData) => {
      const post = this.store.createRecord("post", postData);
      post.topic = topic;
      return post;
    };

    const opPost = data.op_post ? assignTopic(data.op_post) : null;

    const rootNodes = (data.roots || []).map((root) =>
      processNode(this.store, topic, root)
    );

    return {
      topic,
      opPost,
      rootNodes,
      page: data.page || 0,
      hasMoreRoots: data.has_more_roots || false,
      sort: data.sort || "top",
      messageBusLastId: data.message_bus_last_id,
      postNumber: params.post_number ? Number(params.post_number) : null,
      contextMode: false,
      contextChain: null,
      targetPostNumber: null,
      contextNoAncestors: false,
    };
  }

  _processContextResponse(data, params) {
    const topic = this.store.createRecord("topic", data.topic);

    const assignTopic = (postData) => {
      const post = this.store.createRecord("post", postData);
      post.topic = topic;
      return post;
    };

    const opPost = data.op_post ? assignTopic(data.op_post) : null;

    const targetNode = processNode(this.store, topic, data.target_post);
    const ancestors = (data.ancestor_chain || []).map((a) => assignTopic(a));
    const noAncestors = ancestors.length === 0;

    // Build nested chain: ancestor[0] -> ancestor[1] -> ... -> target
    // When context=0 (no ancestors), target becomes the chain root at depth 0.
    let chainTip = targetNode;
    for (let i = ancestors.length - 1; i >= 0; i--) {
      chainTip = { post: ancestors[i], children: [chainTip] };
    }

    return {
      topic,
      opPost,
      sort: params.sort || "top",
      messageBusLastId: data.message_bus_last_id,
      postNumber: Number(params.post_number),
      contextMode: true,
      contextChain: chainTip,
      targetPostNumber: Number(params.post_number),
      contextNoAncestors: noAncestors,
      rootNodes: [],
      page: 0,
      hasMoreRoots: false,
    };
  }
}
