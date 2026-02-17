import { apiInitializer } from "discourse/lib/api";
import NestedRepliesExpandButton from "../components/nested-replies-expand-button";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.nested_replies_enabled) {
    return;
  }

  api.registerValueTransformer("post-menu-buttons", ({ value: dag }) => {
    dag.add("nested-replies-expand", NestedRepliesExpandButton);
  });
});
