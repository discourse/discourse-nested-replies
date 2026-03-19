import { getOwner } from "@ember/owner";
import Route from "@ember/routing/route";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import PostScreenTracker from "../lib/post-screen-tracker";
import processNode from "../lib/process-node";

export default class NestedRoute extends Route {
  @service header;
  @service screenTrack;
  @service siteSettings;
  @service store;

  queryParams = {
    sort: { refreshModel: true },
    post_number: { refreshModel: true },
    context: { refreshModel: true },
  };

  buildRouteInfoMetadata() {
    return { scrollOnTransition: false };
  }

  async model(params) {
    const { topic_id, slug, post_number } = params;
    const sort =
      params.sort || this.siteSettings.nested_replies_default_sort || "top";

    if (post_number) {
      const queryParts = [`sort=${sort}`];
      if (params.context !== undefined && params.context !== null) {
        queryParts.push(`context=${params.context}`);
      }
      const contextQuery = `?${queryParts.join("&")}`;
      const data = await ajax(
        `/nested/${slug}/${topic_id}/context/${post_number}.json${contextQuery}`
      );
      return this._processContextResponse(data, params, sort);
    }

    const data = await ajax(
      `/nested/${slug}/${topic_id}/roots.json?sort=${sort}`
    );
    return this._processResponse(data, params);
  }

  setupController(controller, model) {
    controller.setProperties(model);
    controller.subscribe();

    // Hydrate the topic controller so core components that do
    // lookup("controller:topic") (e.g. share modal) find valid state.
    this.controllerFor("topic").set("model", model.topic);

    // Set the topic route's currentModel so route actions that call
    // this.modelFor("topic") (e.g. showFeatureTopic, showTopicTimerModal)
    // find the topic instead of undefined.
    getOwner(this).lookup("route:topic").currentModel = model.topic;

    // The Topic details setter replaces _details without preserving the
    // back-reference to the parent topic. Restore it so that
    // topic.details.updateNotifications() can construct the correct URL.
    model.topic.details.set("topic", model.topic);

    // Store the OP in the postStream so core components that call
    // postStream.findLoadedPost() (e.g. share modal's "reply as new topic")
    // find a valid post instead of undefined.
    if (model.opPost && model.topic.postStream) {
      model.topic.postStream.storePost(model.opPost);
    }

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
      sort: data.sort || this.siteSettings.nested_replies_default_sort || "top",
      messageBusLastId: data.message_bus_last_id,
      pinnedPostNumber: data.pinned_post_number || null,
      postNumber: params.post_number ? Number(params.post_number) : null,
      contextMode: false,
      contextChain: null,
      targetPostNumber: null,
      contextNoAncestors: false,
      ancestorsTruncated: false,
      topAncestorPostNumber: null,
    };
  }

  _processContextResponse(data, params, sort) {
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
      sort,
      messageBusLastId: data.message_bus_last_id,
      postNumber: Number(params.post_number),
      contextMode: true,
      contextChain: chainTip,
      targetPostNumber: Number(params.post_number),
      contextNoAncestors: noAncestors,
      ancestorsTruncated: data.ancestors_truncated || false,
      topAncestorPostNumber:
        ancestors.length > 0 ? ancestors[0].post_number : null,
      rootNodes: [],
      page: 0,
      hasMoreRoots: false,
    };
  }
}
