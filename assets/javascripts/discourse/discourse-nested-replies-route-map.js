export default {
  resource: "topic",
  map() {
    this.route("nested");
    this.route("thread", { path: "/thread/:post_number" });
  },
};
