import { Controller } from "@hotwired/stimulus"

// After a failed submit re-renders the form, move focus to the first field
// with a validation error so the correction point is announced and reachable.
export default class extends Controller {
  connect() {
    const invalid = this.element.querySelector('[aria-invalid="true"]')
    if (invalid) invalid.focus()
  }
}
