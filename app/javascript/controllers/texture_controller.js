import { Controller } from "@hotwired/stimulus"

// The contour ground: concentric offset contours for a single layer — what a
// slicer actually draws. It is the one piece of decoration in the system and
// it earns its place by being the position rendered literally.
//
// It is a substrate, not a pattern. Both the colour and the alpha are read
// from the tokens rather than hardcoded: light-on-dark reads considerably
// stronger than dark-on-light at identical opacity, so the two themes carry
// different alphas, and near-black lines hardcoded for light mode would
// vanish entirely on the dark ground.
export default class extends Controller {
  connect() {
    this.draw = this.draw.bind(this)
    this.onResize = this.onResize.bind(this)
    this.draw()
    window.addEventListener("resize", this.onResize)
    document.addEventListener("theme:change", this.draw)
    // Redraw when the OS theme flips — the line colour comes from --text.
    this.themeQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.themeQuery.addEventListener("change", this.draw)
  }

  disconnect() {
    window.removeEventListener("resize", this.onResize)
    document.removeEventListener("theme:change", this.draw)
    this.themeQuery?.removeEventListener("change", this.draw)
    clearTimeout(this.timer)
  }

  onResize() {
    clearTimeout(this.timer)
    this.timer = setTimeout(this.draw, 160)
  }

  draw() {
    const canvas = this.element
    const w = window.innerWidth
    const h = window.innerHeight
    // Without devicePixelRatio scaling the 1px lines render soft on retina.
    const dpr = window.devicePixelRatio || 1
    canvas.width = w * dpr
    canvas.height = h * dpr

    const ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.scale(dpr, dpr)
    ctx.clearRect(0, 0, w, h)

    const cs = getComputedStyle(document.documentElement)
    ctx.strokeStyle = cs.getPropertyValue("--text").trim()
    ctx.globalAlpha = parseFloat(cs.getPropertyValue("--texture-alpha")) || 0.05
    ctx.lineWidth = 1

    const cx = w * 0.5
    const cy = h * 0.46
    const max = Math.hypot(w, h) * 0.72

    for (let r = 14; r < max; r += 14) {
      ctx.beginPath()
      for (let a = 0; a <= Math.PI * 2 + 0.01; a += 0.05) {
        const rr = r * (1 + 0.11 * Math.sin(a * 3 + r * 0.012) + 0.05 * Math.cos(a * 5))
        ctx[a === 0 ? "moveTo" : "lineTo"](cx + Math.cos(a) * rr, cy + Math.sin(a) * rr * 0.72)
      }
      ctx.stroke()
    }
  }
}
