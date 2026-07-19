import { Controller } from "@hotwired/stimulus"
import * as THREE from "three"
import { OrbitControls } from "three/addons/controls/OrbitControls.js"
import { STLLoader } from "three/addons/loaders/STLLoader.js"

export default class extends Controller {
  static targets = ["stage", "fallback", "status"]
  static values = { url: String }

  connect() {
    if (!this.hasUrlValue) return

    this.disconnected = false
    this.visible = true
    this.load()
  }

  disconnect() {
    this.disconnected = true
    this.intersectionObserver?.disconnect()
    this.resizeObserver?.disconnect()
    this.renderer?.setAnimationLoop(null)
    this.controls?.dispose()
    this.geometry?.dispose()
    this.material?.dispose()
    this.renderer?.dispose()
    this.renderer?.domElement.remove()
  }

  load() {
    const loader = new STLLoader()
    loader.load(this.urlValue, (geometry) => this.build(geometry), undefined, () => this.fallback())
  }

  build(geometry) {
    if (this.disconnected || !geometry.getAttribute("position")?.count) return

    try {
      this.geometry = geometry
      geometry.computeVertexNormals()
      geometry.center()
      geometry.computeBoundingBox()
      const size = geometry.boundingBox.getSize(new THREE.Vector3())
      const radius = Math.max(size.x, size.y, size.z) / 2
      if (!Number.isFinite(radius) || radius <= 0) return this.fallback()

      this.scene = new THREE.Scene()
      this.scene.background = new THREE.Color(0xf1f5f9)
      this.camera = new THREE.PerspectiveCamera(36, 1, Math.max(radius / 100, 0.01), radius * 100)
      this.camera.up.set(0, 0, 1)
      this.camera.position.set(radius * 2.2, -radius * 2.5, radius * 1.8)

      this.material = new THREE.MeshStandardMaterial({
        color: 0x0d9488, roughness: 0.72, metalness: 0.04, side: THREE.DoubleSide, flatShading: true
      })
      this.mesh = new THREE.Mesh(geometry, this.material)
      this.scene.add(this.mesh)
      this.scene.add(new THREE.HemisphereLight(0xffffff, 0x334155, 2.2))
      const key = new THREE.DirectionalLight(0xffffff, 2.4)
      key.position.set(radius * 2, -radius, radius * 3)
      this.scene.add(key)

      this.renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: "high-performance" })
      this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
      this.renderer.outputColorSpace = THREE.SRGBColorSpace
      this.renderer.domElement.setAttribute("aria-label", "Interactive decimated model preview")
      this.renderer.domElement.setAttribute("role", "img")
      this.stageTarget.prepend(this.renderer.domElement)

      this.controls = new OrbitControls(this.camera, this.renderer.domElement)
      this.controls.enableDamping = true
      this.controls.enablePan = false
      this.controls.minDistance = radius * 1.2
      this.controls.maxDistance = radius * 8
      this.controls.autoRotate = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
      this.controls.autoRotateSpeed = 1.2
      this.controls.update()

      this.resizeObserver = new ResizeObserver(() => this.resize())
      this.resizeObserver.observe(this.stageTarget)
      this.intersectionObserver = new IntersectionObserver(([entry]) => { this.visible = entry.isIntersecting })
      this.intersectionObserver.observe(this.stageTarget)
      this.resize()
      this.fallbackTarget.hidden = true
      this.statusTarget.textContent = "Interactive preview ready — drag to rotate, scroll to zoom."
      this.element.dataset.previewState = "ready"
      this.renderer.setAnimationLoop(() => this.render())
    } catch (_error) {
      this.fallback()
    }
  }

  resize() {
    if (!this.renderer) return

    const width = this.stageTarget.clientWidth
    const height = Math.max(Math.round(width * 0.72), 240)
    this.renderer.setSize(width, height, false)
    this.camera.aspect = width / height
    this.camera.updateProjectionMatrix()
  }

  render() {
    if (!this.visible || this.disconnected) return

    this.controls.update()
    this.renderer.render(this.scene, this.camera)
  }

  fallback() {
    this.statusTarget.textContent = "Interactive preview unavailable — showing the designer render."
    this.element.dataset.previewState = "fallback"
  }
}
