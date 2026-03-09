export default function nestedPostUrl(topic, postNumber) {
  return `/nested/${topic.slug}/${topic.id}?post_number=${postNumber}`;
}
