import getURL from "discourse/lib/get-url";

export default function nestedPostUrl(topic, postNumber) {
  return getURL(`/nested/${topic.slug}/${topic.id}?post_number=${postNumber}`);
}
