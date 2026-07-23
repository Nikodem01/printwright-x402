import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "saveStatus", "previewTitle", "previewDescription", "previewTags",
    "previewCategory", "previewCollections", "previewPrintability", "previewPrice", "previewImage",
    "previewPlaceholder", "previewStatus", "categoryHelp", "tagSuggestions",
    "tagsInput", "renderInput"
  ]
  static values = { feeBps: Number }

  connect() {
    this.dirty = false
    this.submitting = false
    this.objectUrl = null
    this.initialFormState = this.formState()
    this.initialPreviewStatus = this.previewStatusTarget.textContent.trim()
    this.beforeUnload = (event) => this.warnBeforeUnload(event)
    this.beforeVisit = (event) => this.warnBeforeVisit(event)
    this.formSubmitting = () => this.saving()
    window.addEventListener("beforeunload", this.beforeUnload)
    document.addEventListener("turbo:before-visit", this.beforeVisit)
    this.element.addEventListener("submit", this.formSubmitting, true)
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.beforeUnload)
    document.removeEventListener("turbo:before-visit", this.beforeVisit)
    this.element.removeEventListener("submit", this.formSubmitting, true)
    this.releaseObjectUrl()
  }

  changed(event) {
    if (this.submitting) return

    this.updatePreview(event.target)
    this.dirty = this.formState() !== this.initialFormState
    this.saveStatusTarget.textContent = this.dirty ? "Unsaved changes" : "All changes saved"
    this.saveStatusTarget.dataset.state = this.dirty ? "dirty" : "saved"
    this.previewStatusTarget.textContent = this.dirty ?
      "Local preview — save to update the storefront." : this.initialPreviewStatus
  }

  saving() {
    this.submitting = true
    this.dirty = false
    this.saveStatusTarget.textContent = "Saving…"
    this.saveStatusTarget.dataset.state = "saving"
  }

  priceChanged(event) {
    this.changed(event)
  }

  warnBeforeUnload(event) {
    if (!this.dirty || this.submitting) return

    event.preventDefault()
    event.returnValue = ""
  }

  warnBeforeVisit(event) {
    if (this.submitting || !this.dirty || window.confirm("Leave without saving your listing changes?")) return

    event.preventDefault()
  }

  updatePreview(field) {
    const name = field.name || ""
    if (name === "model3d[title]") {
      this.previewTitleTarget.textContent = field.value.trim() || "Untitled model"
    } else if (name === "model3d[description]") {
      this.previewDescriptionTarget.textContent = field.value.trim() ||
        "Add a description so buyers know what is included."
    } else if (name === "model3d[tags_text]") {
      const tags = field.value.split(",").map((tag) => tag.trim()).filter(Boolean)
      this.previewTagsTarget.textContent = tags.length ? `Tags: ${tags.join(", ")}` : "No discovery tags yet"
    } else if (name === "model3d[category]") {
      this.updateDiscoveryPreview()
      this.updateTagSuggestions(field)
    } else if (name === "model3d[collections][]") {
      this.updateDiscoveryPreview()
    } else if (name.startsWith("model3d[printability]")) {
      this.updatePrintPreview()
    } else if (name.endsWith("[price_usdc]") || name.endsWith("[_destroy]")) {
      this.updateOfferPreview()
    } else if (this.hasRenderInputTarget && field === this.renderInputTarget) {
      this.previewSelectedRender(field.files?.[0])
    }
  }

  updateDiscoveryPreview() {
    const category = this.element.querySelector("select[name='model3d[category]']")
    const selectedCategory = category?.selectedOptions[0]
    this.previewCategoryTarget.textContent = category?.value ?
      `Category: ${selectedCategory.textContent.trim()}` : "No buyer category yet"

    const collections = Array.from(
      this.element.querySelectorAll("input[type='checkbox'][name='model3d[collections][]']:checked")
    ).map((input) => input.dataset.collectionName)
    this.previewCollectionsTarget.textContent = collections.length ?
      `Browse shelves: ${collections.join(", ")}` : "No collection shelves selected"
  }

  updatePrintPreview() {
    const value = (fieldName) => this.element.querySelector(`[name='${fieldName}']`)?.value.trim()
    const facts = []
    const materials = value("model3d[printability][materials_text]")
    const supports = this.element.querySelector("[name='model3d[printability][supports]']")
    const minutes = value("model3d[printability][est_print_minutes]")
    const bed = value("model3d[printability][bed_min_mm]")

    if (materials) facts.push(materials.split(/[,\s]+/).filter(Boolean).join(" / "))
    facts.push(supports?.checked ? "supports needed" : "support-free")
    if (minutes) facts.push(`${minutes} min`)
    if (bed) facts.push(`${bed} mm bed`)
    this.previewPrintabilityTarget.textContent = `Print facts: ${facts.join(" · ")}`
  }

  updateTagSuggestions(category) {
    const selected = category.selectedOptions[0]
    this.categoryHelpTarget.textContent = selected?.dataset.description ||
      "Choose the single category that best matches what the buyer will print."

    let suggestions = []
    try {
      suggestions = JSON.parse(selected?.dataset.tagSuggestions || "[]")
    } catch (_error) {
      suggestions = []
    }

    const label = document.createElement("span")
    label.textContent = suggestions.length ?
      `Suggestions for ${selected.textContent.trim()}:` : "Choose a category to see optional tag suggestions."
    const buttons = suggestions.map((suggestion) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "editor-tag-suggestion"
      button.dataset.tagValue = suggestion
      button.dataset.action = "listing-editor#addSuggestedTag"
      button.textContent = suggestion
      return button
    })
    this.tagSuggestionsTarget.replaceChildren(label, ...buttons)
  }

  addSuggestedTag(event) {
    const suggestion = event.currentTarget.dataset.tagValue
    const tags = this.tagsInputTarget.value.split(",").map((tag) => tag.trim()).filter(Boolean)
    if (!tags.some((tag) => tag.toLowerCase() === suggestion.toLowerCase())) tags.push(suggestion)
    this.tagsInputTarget.value = tags.join(", ")
    this.tagsInputTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.tagsInputTarget.focus()
  }

  previewSelectedRender(file) {
    if (!file || !file.type.startsWith("image/")) return

    this.releaseObjectUrl()
    this.objectUrl = URL.createObjectURL(file)
    this.previewImageTarget.src = this.objectUrl
    this.previewImageTarget.hidden = false
    this.previewPlaceholderTarget.hidden = true
  }

  releaseObjectUrl() {
    if (!this.objectUrl) return

    URL.revokeObjectURL(this.objectUrl)
    this.objectUrl = null
  }

  updateOfferPreview() {
    const prices = []
    this.element.querySelectorAll("[data-license-product]").forEach((card) => {
      const removed = card.querySelector("input[type='checkbox'][name$='[_destroy]']")?.checked
      const price = Number.parseFloat(card.querySelector("[data-license-price]")?.value || "")
      const cents = Number.isFinite(price) && price > 0 ? Math.round(price * 100) : null
      const net = card.querySelector("[data-license-net]")

      if (net) {
        const fee = cents === null ? null : Math.floor(cents * this.feeBpsValue / 10000)
        net.textContent = cents === null ? "Set a price" : `${((cents - fee) / 100).toFixed(2)} USDC`
      }
      if (!removed && cents !== null) prices.push(cents)
    })

    this.previewPriceTarget.textContent = prices.length ?
      `${(Math.min(...prices) / 100).toFixed(2)} USDC` : "Price not set"
  }

  formState() {
    const form = this.element.querySelector(".listing-editor-form")
    if (!form) return ""

    return JSON.stringify(Array.from(new FormData(form).entries()).map(([name, value]) => {
      if (value instanceof File) return [name, value.name, value.size, value.lastModified]
      return [name, value]
    }))
  }
}
