import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import nestedPostUrl from "../../../lib/nested-post-url";

module("Unit | Lib | nested-post-url", function (hooks) {
  setupTest(hooks);

  test("builds a nested URL with topic slug, id and post number", function (assert) {
    const topic = { slug: "test-topic", id: 42 };

    assert.strictEqual(
      nestedPostUrl(topic, 5),
      "/nested/test-topic/42?post_number=5"
    );
  });

  test("always produces a URL without context param", function (assert) {
    const topic = { slug: "my-topic", id: 99 };

    assert.strictEqual(
      nestedPostUrl(topic, 7),
      "/nested/my-topic/99?post_number=7"
    );
  });
});
