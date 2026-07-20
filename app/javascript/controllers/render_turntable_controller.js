import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["image", "status"]
  static values = { frames: Array }

  connect() {
    this.frame = 0
    this.scale = 1
    this.preload()
    this.showFrame()
  }

  start(event) {
    if (this.framesValue.length < 2) return

    this.dragStartX = event.clientX
    this.dragStartFrame = this.frame
    this.pointerTarget = event.currentTarget
    this.pointerTarget.setPointerCapture(event.pointerId)
    this.element.dataset.dragging = "true"
  }

  move(event) {
    if (this.dragStartX === undefined) return

    const steps = Math.round((event.clientX - this.dragStartX) / 24)
    this.frame = this.wrap(this.dragStartFrame - steps)
    this.showFrame()
  }

  stop(event) {
    if (this.pointerTarget?.hasPointerCapture(event.pointerId)) this.pointerTarget.releasePointerCapture(event.pointerId)
    this.dragStartX = undefined
    this.pointerTarget = undefined
    delete this.element.dataset.dragging
  }

  zoom(event) {
    event.preventDefault()
    this.scale = Math.min(2.5, Math.max(1, this.scale + (event.deltaY < 0 ? 0.15 : -0.15)))
    this.imageTarget.style.transform = `scale(${this.scale})`
    this.updateStatus()
  }

  keydown(event) {
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault()
      this.frame = this.wrap(this.frame + (event.key === "ArrowRight" ? 1 : -1))
      this.showFrame()
    }
    if (event.key === "+" || event.key === "=") this.zoomByKeyboard(event, 0.15)
    if (event.key === "-") this.zoomByKeyboard(event, -0.15)
  }

  zoomByKeyboard(event, change) {
    event.preventDefault()
    this.scale = Math.min(2.5, Math.max(1, this.scale + change))
    this.imageTarget.style.transform = `scale(${this.scale})`
    this.updateStatus()
  }

  showFrame() {
    if (!this.framesValue.length) return

    this.imageTarget.src = this.framesValue[this.frame]
    this.element.dataset.turntableFrame = String(this.frame)
    this.updateStatus()
  }

  updateStatus() {
    if (this.framesValue.length < 2) {
      this.statusTarget.textContent = "Designer render."
      return
    }

    const zoom = this.scale > 1 ? ` · ${Math.round(this.scale * 100)}% zoom` : ""
    this.statusTarget.textContent = `Rendered view ${this.frame + 1} of ${this.framesValue.length} — drag to change view, scroll to zoom${zoom}.`
  }

  preload() {
    this.framesValue.slice(1).forEach((url) => {
      const image = new Image()
      image.src = url
    })
  }

  wrap(index) {
    const count = this.framesValue.length
    return ((index % count) + count) % count
  }
}
