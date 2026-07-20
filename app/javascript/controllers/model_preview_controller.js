import { Controller } from "@hotwired/stimulus"

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

  async load() {
    try {
      const [THREE, { OrbitControls }, { STLLoader }] = await Promise.all([
        import("three"),
        import("three/addons/controls/OrbitControls.js"),
        import("three/addons/loaders/STLLoader.js")
      ])
      if (this.disconnected) return

      this.THREE = THREE
      this.OrbitControls = OrbitControls
      const loader = new STLLoader()
      loader.load(this.urlValue, (geometry) => this.build(geometry), undefined, () => this.fallback())
    } catch (_error) {
      this.fallback()
    }
  }

  build(geometry) {
    if (this.disconnected || !geometry.getAttribute("position")?.count) return

    try {
      const THREE = this.THREE
      geometry = this.weldGeometry(geometry)
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
        color: 0x0d9488, roughness: 0.72, metalness: 0.04, side: THREE.DoubleSide
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

      this.controls = new this.OrbitControls(this.camera, this.renderer.domElement)
      this.controls.enableDamping = true
      this.controls.enablePan = false
      this.controls.minDistance = radius * 1.2
      this.controls.maxDistance = radius * 8
      this.controls.autoRotate = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
      this.controls.autoRotateSpeed = 1.2
      this.controls.addEventListener("start", () => {
        this.controls.autoRotate = false
        this.element.dataset.previewInteraction = "user"
      })
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

  weldGeometry(source) {
    const THREE = this.THREE
    const positions = source.getAttribute("position")
    const vertices = []
    const indices = []
    const seen = new Map()

    for (let index = 0; index < positions.count; index += 1) {
      const point = [positions.getX(index), positions.getY(index), positions.getZ(index)]
      const key = point.map((value) => Math.round(value * 100000)).join(":")
      let vertexIndex = seen.get(key)
      if (vertexIndex === undefined) {
        vertexIndex = vertices.length / 3
        seen.set(key, vertexIndex)
        vertices.push(...point)
      }
      indices.push(vertexIndex)
    }

    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.Float32BufferAttribute(vertices, 3))
    geometry.setIndex(indices)
    source.dispose()
    return geometry
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
