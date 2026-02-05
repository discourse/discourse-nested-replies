import Component from "@glimmer/component";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import ComboBox from "discourse/select-kit/components/combo-box";

export default class NestedSortDropdown extends Component {
  get sortOptions() {
    return [
      {
        id: "chronological",
        name: "Chronological",
      },
      {
        id: "new",
        name: "New",
      },
      {
        id: "best",
        name: "Best",
      },
    ];
  }

  get selectedSort() {
    return this.args.currentSort || "chronological";
  }

  @action
  onSelectSort(sortId) {
    this.args.onSortChange?.(sortId);
  }

  <template>
    <div class="nested-sort-dropdown">
      <ComboBox
        @value={{this.selectedSort}}
        @content={{this.sortOptions}}
        @onChange={{this.onSelectSort}}
        @options={{hash filterable=false}}
      />
    </div>
  </template>
}
