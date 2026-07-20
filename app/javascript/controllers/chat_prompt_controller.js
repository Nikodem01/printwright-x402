import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "input"]

  choose({ params: { message } }) {
    this.inputTarget.value = message
    this.formTarget.requestSubmit()
  }
}
