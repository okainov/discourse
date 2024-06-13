import Component from "@glimmer/component";
import { hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { NO_VALUE_OPTION } from "form-kit/lib/constants";
import FKControlSelectOption from "./select/option";

export default class FKControlSelect extends Component {
  @action
  handleInput(event) {
    // if an option has no value, event.target.value will be the content of the option
    // this is why we use this magic value to represent no value
    this.args.setValue(
      event.target.value === NO_VALUE_OPTION ? undefined : event.target.value
    );
  }

  <template>
    <select
      name={{@name}}
      value={{@value}}
      id={{@fieldId}}
      disabled={{@disabled}}
      ...attributes
      class="form-kit__control-select"
      {{on "input" this.handleInput}}
    >
      {{yield (hash Option=(component FKControlSelectOption selected=@value))}}
    </select>
  </template>
}
