import { apiInitializer } from "discourse/lib/api";
import NestedRepliesToggleButton from "../components/nested-replies-toggle-button";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.nested_replies_enabled) {
    return;
  }

  api.registerValueTransformer("post-menu-buttons", ({ value: dag }) => {
    dag.add("nested-replies-toggle", NestedRepliesToggleButton);
  });
});
