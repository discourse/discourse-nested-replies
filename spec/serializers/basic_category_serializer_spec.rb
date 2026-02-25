# frozen_string_literal: true

RSpec.describe BasicCategorySerializer do
  fab!(:category)

  before { SiteSetting.nested_replies_enabled = true }

  it "serializes nested_replies_default as true when category custom field is set" do
    category.custom_fields[DiscourseNestedReplies::CATEGORY_DEFAULT_FIELD] = true
    category.save_custom_fields

    json = BasicCategorySerializer.new(category, root: false).as_json

    expect(json[:nested_replies_default]).to eq(true)
  end

  it "serializes nested_replies_default as nil when category custom field is not set" do
    json = BasicCategorySerializer.new(category, root: false).as_json

    expect(json[:nested_replies_default]).to be_nil
  end
end
