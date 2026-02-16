import { cached, tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { dependentKeyCompat } from "@ember/object/compat";
import { service } from "@ember/service";
import BufferedProxy from "ember-buffered-proxy/proxy";
import FlagModal from "discourse/components/modal/flag";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { bind } from "discourse/lib/decorators";
import PostFlag from "discourse/lib/flag-targets/post-flag";
import Category from "discourse/models/category";
import Composer from "discourse/models/composer";
import Topic from "discourse/models/topic";
import { i18n } from "discourse-i18n";
import processNode from "../lib/process-node";

export default class NestedController extends Controller {
  @service appEvents;
  @service composer;
  @service store;
  @service dialog;
  @service currentUser;
  @service messageBus;
  @service modal;
  @service router;
  @service siteSettings;

  @tracked topic;
  @tracked opPost;
  @tracked rootNodes = [];
  @tracked page = 0;
  @tracked hasMoreRoots = false;
  @tracked loadingMore = false;
  @tracked sort = "top";
  @tracked messageBusLastId;
  @tracked postNumber;
  @tracked contextMode = false;
  @tracked contextChain = null;
  @tracked targetPostNumber = null;
  @tracked contextNoAncestors = false;
  @tracked newRootPostIds = [];
  @tracked editingTopic = false;
  @tracked postScreenTracker = null;
  queryParams = ["sort", "post_number", "context"];

  @cached
  @dependentKeyCompat
  get buffered() {
    return BufferedProxy.create({ content: this.topic });
  }

  get showCategoryChooser() {
    return !this.topic?.isPrivateMessage;
  }

  get canEditTags() {
    return (
      this.site.get("can_tag_topics") &&
      (!this.topic?.isPrivateMessage || this.site.get("can_tag_pms"))
    );
  }

  get minimumRequiredTags() {
    return (
      Category.findById(this.buffered.get("category_id"))
        ?.minimumRequiredTags || 0
    );
  }

  @action
  async loadMoreRoots() {
    if (this.loadingMore || !this.hasMoreRoots) {
      return;
    }

    this.loadingMore = true;
    try {
      const nextPage = this.page + 1;
      const data = await ajax(
        `/nested/${this.topic.slug}/${this.topic.id}/roots.json?page=${nextPage}&sort=${this.sort}`
      );

      const newNodes = (data.roots || []).map((root) =>
        this._processNode(root)
      );

      this.rootNodes = [...this.rootNodes, ...newNodes];
      this.page = data.page;
      this.hasMoreRoots = data.has_more_roots || false;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loadingMore = false;
    }
  }

  @action
  changeSort(newSort) {
    this.router.transitionTo({ queryParams: { sort: newSort } });
  }

  @action
  viewFullThread() {
    this.router.transitionTo("nested", this.topic.slug, this.topic.id, {
      queryParams: { sort: this.sort, post_number: null, context: null },
    });
  }

  @action
  viewParentContext() {
    this.router.transitionTo("nested", this.topic.slug, this.topic.id, {
      queryParams: {
        sort: this.sort,
        post_number: this.targetPostNumber,
        context: null,
      },
    });
  }

  @action
  replyToPost(post, depth) {
    const topic = this.topic;
    if (!topic.details?.can_create_post) {
      return;
    }

    let replyTarget = post;

    // When nesting is capped and post is at max depth, reply to its parent
    // so the user sees "Replying to [parent]" matching the backend re-parenting
    if (
      this.siteSettings.nested_replies_cap_nesting_depth &&
      typeof depth === "number" &&
      depth >= this.siteSettings.nested_replies_max_depth
    ) {
      replyTarget = post.reply_to_post || post;
    }

    const opts = {
      action: Composer.REPLY,
      draftKey: topic.draft_key,
      draftSequence: topic.draft_sequence || 0,
      skipJumpOnSave: true,
    };

    if (replyTarget && replyTarget.post_number !== 1) {
      opts.post = replyTarget;
    } else {
      opts.topic = topic;
    }

    this.composer.open(opts);
  }

  @action
  editPost(post) {
    if (!this.currentUser) {
      return this.dialog.alert(i18n("post.controls.edit_anonymous"));
    }
    if (!post.can_edit) {
      return;
    }

    this.composer.open({
      post,
      action: Composer.EDIT,
      draftKey: this.topic.draft_key,
      draftSequence: this.topic.draft_sequence || 0,
    });
  }

  @action
  deletePost(post) {
    if (!post.can_delete) {
      return;
    }

    this.dialog.yesNoConfirm({
      message: i18n("post.confirm_delete"),
      didConfirm: () => {
        post.destroy(this.currentUser).catch(popupAjaxError);
      },
    });
  }

  @action
  recoverPost(post) {
    post.recover();
  }

  @action
  showFlags(post) {
    this.modal.show(FlagModal, {
      model: {
        flagTarget: new PostFlag(),
        flagModel: post,
        setHidden: () => post.set("hidden", true),
      },
    });
  }

  @action
  startEditingTopic(event) {
    event?.preventDefault();
    if (!this.topic?.details?.can_edit) {
      return;
    }
    this.editingTopic = true;
  }

  @action
  cancelEditingTopic() {
    this.editingTopic = false;
    this.buffered.discardChanges();
  }

  @action
  async finishedEditingTopic() {
    if (!this.editingTopic) {
      return;
    }
    const props = this.buffered.get("buffer");
    try {
      await Topic.update(this.topic, props, { fastEdit: true });
      this.buffered.discardChanges();
      this.editingTopic = false;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  topicCategoryChanged(categoryId) {
    this.buffered.set("category_id", categoryId);
  }

  @action
  topicTagsChanged(value) {
    this.buffered.set("tags", value);
  }

  subscribe() {
    this.unsubscribe();
    if (this.topic?.id && this.messageBusLastId != null) {
      this.messageBus.subscribe(
        `/topic/${this.topic.id}`,
        this._onMessage,
        this.messageBusLastId
      );
    }
  }

  unsubscribe() {
    this.messageBus.unsubscribe("/topic/*", this._onMessage);
  }

  @bind
  _onMessage(data) {
    switch (data.type) {
      case "created":
        this._handleCreated(data);
        break;
      case "revised":
      case "rebaked":
      case "deleted":
      case "recovered":
      case "acted":
        this._handlePostChanged(data);
        break;
    }
  }

  async _handleCreated(data) {
    try {
      const postData = await ajax(`/posts/${data.id}.json`);
      const post = this.store.createRecord("post", postData);
      post.topic = this.topic;

      const replyTo = postData.reply_to_post_number;
      const isRoot = !replyTo || replyTo === 1;

      if (isRoot) {
        if (data.user_id === this.currentUser?.id) {
          this.rootNodes = [{ post, children: [] }, ...this.rootNodes];
        } else {
          this.newRootPostIds = [...this.newRootPostIds, data.id];
        }
      } else {
        this.appEvents.trigger("nested-replies:child-created", {
          post,
          parentPostNumber: replyTo,
          isOwnPost: data.user_id === this.currentUser?.id,
        });
      }
    } catch {
      // Post may not be visible to this user
    }
  }

  async _handlePostChanged(data) {
    try {
      const postData = await ajax(`/posts/${data.id}.json`);
      this.store.createRecord("post", postData);
    } catch {
      // Post may not be visible
    }
  }

  @action
  async loadNewRoots() {
    const ids = [...this.newRootPostIds];
    this.newRootPostIds = [];

    const results = await Promise.allSettled(
      ids.map((id) => ajax(`/posts/${id}.json`))
    );

    const newNodes = [];
    for (const result of results) {
      if (result.status === "fulfilled") {
        const postData = result.value;
        const post = this.store.createRecord("post", postData);
        post.topic = this.topic;
        newNodes.push({ post, children: [] });
      }
    }

    if (newNodes.length > 0) {
      this.rootNodes = [...newNodes, ...this.rootNodes];
    }
  }

  readPosts(topicId, postNumbers) {
    if (this.topic?.id !== topicId) {
      return;
    }

    const postNumberSet = new Set(postNumbers);

    const markRead = (post) => {
      if (!post.read && postNumberSet.has(post.post_number)) {
        post.set("read", true);
      }
    };

    if (this.opPost) {
      markRead(this.opPost);
    }

    const walkNodes = (nodes) => {
      nodes?.forEach((node) => {
        markRead(node.post);
        walkNodes(node.children);
      });
    };

    walkNodes(this.rootNodes);

    if (this.contextChain) {
      const walkChain = (node) => {
        markRead(node.post);
        node.children?.forEach(walkChain);
      };
      walkChain(this.contextChain);
    }
  }

  _processNode(nodeData) {
    return processNode(this.store, this.topic, nodeData);
  }
}
