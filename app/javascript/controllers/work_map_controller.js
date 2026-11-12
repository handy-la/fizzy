import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import {
  NODE_WIDTH, NODE_HEIGHT, buildGraph, chain, needsHuman, blocksOthers, waitsOnOthers,
  visibleIds, hiddenRelations, released, search, layout
} from "helpers/work_map_graph"

// Handy #2348: draws the read-only work map and handles its navigation. It
// only reads the JSON the page carries; it never writes to Fizzy or Dédalo.
const SVG = "http://www.w3.org/2000/svg"
const MIN_SCALE = 0.1
const MAX_SCALE = 2.5
const DRAG_THRESHOLD = 6
const PRODUCT_COLORS = [ 3, 4, 5, 6, 7, 8, 1, 2 ].map(index => `var(--color-card-${index})`)

const CONDITIONS = {
  integration: "integración a main", qa: "QA", publication: "publicación", installed: "instalación",
  landing: "aterrizaje", other: "otro hito"
}
const RELATION_STATUSES = {
  pending: "vigente", satisfied: "satisfecha", reconciled: "reconciliada", ended: "terminó sin cumplirse"
}
const WAIT_KINDS = {
  card: "otra tarjeta", human: "decisión humana", resource: "recursos", window: "ventana operativa",
  deployment: "despliegue", publication: "publicación", other: "otro motivo"
}
const HUMAN = {
  required: "Requiere intervención humana", pending: "Espera una respuesta humana",
  not_required: "No requiere intervención humana", unknown: "Intervención humana: sin dato"
}
const EXECUTION_STATUSES = {
  none_reported: "Sin información de ejecución",
  incomplete: "Sin dato: la cobertura del producto está incompleta",
  product_failed: "Sin dato: la fuente del producto falló",
  unregistered: "Producto sin registro de ejecución",
  source_failed: "Sin dato: la fuente de ejecución falló",
  source_not_configured: "Sin dato: la fuente de ejecución no está configurada"
}
const PRODUCT_STATUSES = {
  ok: "al día", partial: "cobertura incompleta", failed: "fuente fallida",
  unregistered: "sin registro de ejecución", source_failed: "fuente de ejecución fallida",
  source_not_configured: "fuente de ejecución no configurada"
}

export default class extends Controller {
  static targets = [ "data", "svg", "canvas", "panel", "status", "coverage", "search", "filters",
    "productFilters", "filterCount", "chainButton" ]

  connect() {
    this.payload = JSON.parse(this.dataTarget.textContent)
    this.graph = buildGraph(this.payload)
    this.view = { x: 0, y: 0, k: 1 }
    this.pointers = new Map()
    this.selected = null
    this.#renderProductFilters()
    this.#renderCoverage()
    this.#draw()
    requestAnimationFrame(() => this.#initialView())
  }

  // Navigation

  zoomIn() { this.#zoomAt(1.25) }
  zoomOut() { this.#zoomAt(0.8) }

  fit() {
    this.#fitBox(this.box)
  }

  focusChain() {
    if (!this.selected) return
    const ids = [ this.selected, ...chain(this.graph, this.selected, "up"), ...chain(this.graph, this.selected, "down") ]
    const boxes = ids.map(id => this.layout.positions.get(id)).filter(Boolean)
    if (boxes.length) {
      this.#fitBox({
        x: Math.min(...boxes.map(box => box.x)), y: Math.min(...boxes.map(box => box.y)),
        width: Math.max(...boxes.map(box => box.x)) - Math.min(...boxes.map(box => box.x)) + NODE_WIDTH,
        height: Math.max(...boxes.map(box => box.y)) - Math.min(...boxes.map(box => box.y)) + NODE_HEIGHT
      })
    }
  }

  // Readable from the start: the map's width at no less than 60 %, from its
  // top-left corner. «Ajustar» shows the whole map, however small.
  #initialView() {
    const { width } = this.canvasTarget.getBoundingClientRect()
    if (!width) return
    const box = this.box
    const k = Math.min(1, Math.max(0.6, width / box.width))
    this.view = { k, x: Math.max(0, (width - box.width * k) / 2) - box.x * k, y: -box.y * k }
    this.#applyView()
  }

  wheel(event) {
    event.preventDefault()
    this.#zoomAt(Math.exp(-event.deltaY * 0.0015), this.#local(event))
  }

  pointerdown(event) {
    this.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY, startX: event.clientX, startY: event.clientY })
    this.canvasTarget.setPointerCapture?.(event.pointerId)
    this.dragged = false
    this.pressedNode = this.pointers.size === 1 ? event.target.closest?.("[data-node-id]")?.dataset.nodeId || null : null
    this.pinch = this.pointers.size === 2 ? this.#pinchState() : null
  }

  pointermove(event) {
    const pointer = this.pointers.get(event.pointerId)
    if (!pointer) return

    const dx = event.clientX - pointer.x
    const dy = event.clientY - pointer.y
    pointer.x = event.clientX
    pointer.y = event.clientY

    if (this.pointers.size === 2 && this.pinch) {
      const next = this.#pinchState()
      this.#zoomAt(next.distance / this.pinch.distance, next.center)
      this.pinch = next
      this.dragged = true
    } else if (this.pointers.size === 1) {
      if (Math.hypot(event.clientX - pointer.startX, event.clientY - pointer.startY) > DRAG_THRESHOLD) this.dragged = true
      if (this.dragged) {
        this.view.x += dx
        this.view.y += dy
        this.#applyView()
      }
    }
  }

  pointerup(event) {
    if (!this.pointers.has(event.pointerId)) return
    this.pointers.delete(event.pointerId)
    this.pinch = null

    // Pointer capture retargets pointerup to the canvas: the card is the one
    // pressed, and a press that became a drag or a pinch selects nothing.
    if (!this.dragged && event.type === "pointerup" && this.pointers.size === 0) {
      this.#select(this.pressedNode)
    }
  }

  keydown(event) {
    const actions = {
      ArrowLeft: () => this.#move(-1, 0), ArrowRight: () => this.#move(1, 0),
      ArrowUp: () => this.#move(0, -1), ArrowDown: () => this.#move(0, 1),
      Enter: () => this.#open(), Escape: () => this.#select(null),
      "+": () => this.zoomIn(), "=": () => this.zoomIn(), "-": () => this.zoomOut(),
      "0": () => this.fit(), c: () => this.focusChain()
    }
    const action = actions[event.key]
    if (action && !event.metaKey && !event.ctrlKey && !event.altKey) {
      // The page's own hotkeys (← goes Home) listen on the document.
      event.preventDefault()
      event.stopPropagation()
      action()
    }
  }

  // Search and filters

  search(event) {
    event.preventDefault()
    const query = this.searchTarget.value
    const matches = search(this.graph, query)

    if (!query.trim()) {
      this.#announce("")
    } else if (!matches.length) {
      this.#announce(`Ninguna tarjeta coincide con «${query}».`)
    } else {
      const shown = matches.find(id => this.visible.has(id))
      if (shown) {
        this.#select(shown, { center: true })
        this.#announce(matches.length > 1 ? `${matches.length} coincidencias; se muestra la primera.` : "")
      } else {
        this.#announce("La tarjeta existe, pero los filtros la ocultan. Usa «Restablecer filtros».")
      }
    }
  }

  filter() {
    this.#draw()
    this.fit()
  }

  resetFilters() {
    this.filtersTarget.querySelectorAll("input[type=checkbox]").forEach(input => input.checked = false)
    this.filter()
  }

  // Drawing

  get box() {
    return { x: -24, y: -24, width: this.layout.width + 48, height: this.layout.height + 48 }
  }

  #draw() {
    this.visible = visibleIds(this.graph, this.#filters())
    this.layout = layout(this.graph, this.visible)

    const svg = this.svgTarget
    svg.replaceChildren(this.#definitions())
    this.viewport = element("g", { class: "work-map__viewport" })
    const edgesLayer = element("g", { class: "work-map__edges" })
    const nodesLayer = element("g", { class: "work-map__nodes" })

    this.layout.labels.forEach(label => {
      const text = element("text", { class: "work-map__group-label", x: label.x, y: label.y + 18 })
      text.textContent = label.text
      nodesLayer.append(text)
    })

    this.edgeElements = new Map()
    this.graph.edges.forEach(edge => {
      if (!this.visible.has(edge.from) || !this.visible.has(edge.to)) return
      const path = this.#edgeElement(edge)
      this.edgeElements.set(edge.index, path)
      edgesLayer.append(path)
    })

    this.nodeElements = new Map()
    for (const id of this.visible) {
      const group = this.#nodeElement(this.graph.nodes.get(id), this.layout.positions.get(id))
      this.nodeElements.set(id, group)
      nodesLayer.append(group)
    }

    this.viewport.append(edgesLayer, nodesLayer)
    svg.append(this.viewport)
    this.#applyView()
    this.#renderStatus()

    // A filter that hides the chosen card clears the whole selection: the
    // panel and «Enfocar cadena» too, not only the highlight (Handy #2372).
    if (this.selected && !this.visible.has(this.selected)) this.#select(null)
    else this.#highlight()
  }

  #definitions() {
    const defs = element("defs")
    for (const status of Object.keys(RELATION_STATUSES)) {
      const marker = element("marker", { id: `work-map-arrow-${status}`, viewBox: "0 0 10 10", refX: 9, refY: 5,
        markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse" })
      marker.append(element("path", { d: "M 0 0 L 10 5 L 0 10 z", class: `work-map__arrow work-map__arrow--${status}` }))
      defs.append(marker)
    }
    return defs
  }

  #edgeElement(edge) {
    const from = this.layout.positions.get(edge.from)
    const to = this.layout.positions.get(edge.to)
    const cycle = this.layout.cycleEdges.has(edge.index)
    const start = { x: from.x + NODE_WIDTH, y: from.y + NODE_HEIGHT / 2 }
    const end = { x: to.x, y: to.y + NODE_HEIGHT / 2 }
    let d
    if (cycle || end.x <= start.x) {
      // A relation that closes a cycle goes back: drawn as a loop below.
      const dip = Math.max(start.y, end.y) + NODE_HEIGHT
      d = `M ${start.x} ${start.y} C ${start.x + 60} ${dip}, ${end.x - 60} ${dip}, ${end.x} ${end.y}`
    } else {
      const mid = (start.x + end.x) / 2
      d = `M ${start.x} ${start.y} C ${mid} ${start.y}, ${mid} ${end.y}, ${end.x} ${end.y}`
    }
    const path = element("path", { d, class: `work-map__edge work-map__edge--${edge.status}${cycle ? " work-map__edge--cycle" : ""}`,
      "marker-end": `url(#work-map-arrow-${edge.status})` })
    const title = element("title")
    title.textContent = `${this.#label(edge.from)} → ${this.#label(edge.to)}: ${CONDITIONS[edge.condition]}, ${RELATION_STATUSES[edge.status]}${cycle ? " (ciclo)" : ""}`
    path.append(title)
    return path
  }

  #nodeElement(node, position) {
    const group = element("g", { class: `work-map__node work-map__node--${node.kind} work-map__node--${node.disposition || node.kind}`,
      transform: `translate(${position.x} ${position.y})`, "data-node-id": node.id })
    group.style.setProperty("--product-color", this.#productColor(node.product))
    group.append(element("rect", { class: "work-map__node-box", width: NODE_WIDTH, height: NODE_HEIGHT, rx: 8 }))
    group.append(element("rect", { class: "work-map__node-stripe", width: 6, height: NODE_HEIGHT, rx: 3 }))

    const heading = element("text", { class: "work-map__node-heading", x: 14, y: 20 })
    const title = element("text", { class: "work-map__node-title", x: 14, y: 38 })
    const footer = element("text", { class: "work-map__node-footer", x: 14, y: 52 })

    if (node.kind === "card") {
      heading.textContent = `${this.#productName(node.product)} #${node.number}`
      title.textContent = clip(node.title, 30)
      footer.textContent = clip(`${node.stage} · ${this.#executionSummary(node)}`, 36)
      if (needsHuman(node)) group.classList.add("work-map__node--human")
      if (node.execution?.wait) group.classList.add("work-map__node--waiting")
    } else if (node.kind === "missing") {
      heading.textContent = `${this.#productName(node.product)} #${node.number}`
      title.textContent = "Referencia ausente"
      footer.textContent = "No existe en Fizzy"
    } else {
      heading.textContent = "Tarjeta sin acceso"
      title.textContent = "Fuera de tus tableros"
      footer.textContent = "Sin detalles"
    }

    group.append(heading, title, footer)
    const tooltip = element("title")
    tooltip.textContent = this.#label(node.id)
    group.append(tooltip)
    return group
  }

  #executionSummary(node) {
    if (node.execution) {
      const wait = node.execution.wait
      return wait ? `espera: ${WAIT_KINDS[wait.kind]}` : (waitsOnOthers(this.graph, node.id) ? node.execution.state : `${node.execution.state}, sin bloqueos`)
    } else {
      return EXECUTION_STATUSES[node.execution_status] || "Sin información de ejecución"
    }
  }

  #renderStatus() {
    const source = this.payload.source
    const parts = [ `Datos de Fizzy: ${formatTime(this.payload.generated_at)}` ]
    if (source.status === "ok") {
      parts.push(`Ejecución de Dédalo generada ${formatTime(source.generated_at)}`)
      if (source.dropped) parts.push(`${source.dropped} entradas de Dédalo fuera de contrato se descartaron`)
      if (source.over_limit.length) parts.push("Dédalo envió más datos que el límite: el mapa está incompleto")
    } else if (source.status === "not_configured") {
      parts.push("La fuente de ejecución de Dédalo no está configurada: sólo se ven tarjetas y columnas")
    } else {
      parts.push(`La fuente de ejecución de Dédalo falló (${source.error}): no se ven estados, esperas ni dependencias`)
    }

    const cards = [ ...this.visible ].filter(id => this.graph.nodes.get(id).kind === "card").length
    parts.push(`${cards} tarjetas en el mapa`)
    if (this.payload.truncated) parts.push(`Hay más de ${this.payload.max_cards} tarjetas abiertas: se muestran las de actividad más reciente`)
    const hidden = hiddenRelations(this.graph, this.visible)
    if (hidden) parts.push(`${hidden} relaciones tienen un extremo oculto por los filtros`)

    this.statusTarget.textContent = parts.join(" · ")
  }

  #renderCoverage() {
    this.coverageTarget.replaceChildren(...this.payload.products.map(product => {
      const item = document.createElement("li")
      item.className = `work-map__coverage-item work-map__coverage-item--${product.status}`
      item.style.setProperty("--product-color", this.#productColor(product.key))
      let text = `${product.name}: ${PRODUCT_STATUSES[product.status] || product.status}`
      if (product.error) text += ` (${product.error})`
      if (product.truncated) text += ", inventario truncado"
      item.textContent = text
      if (product.read_at) {
        const time = document.createElement("span")
        time.className = "work-map__coverage-time"
        time.textContent = `, leído ${formatTime(product.read_at)}`
        item.append(time)
      }
      return item
    }))
  }

  #renderProductFilters() {
    this.productFiltersTarget.replaceChildren(...this.payload.products.map(product => {
      const label = document.createElement("label")
      const input = document.createElement("input")
      Object.assign(input, { type: "checkbox", name: "product", value: product.key })
      label.append(input, ` ${product.name}`)
      return label
    }))
  }

  #filters() {
    const values = name => new Set([ ...this.filtersTarget.querySelectorAll(`input[name=${name}]:checked`) ].map(input => input.value))
    const filters = {
      products: values("product"), dispositions: values("disposition"), waits: values("wait"),
      human: values("human").size > 0, blocking: values("blocking").size > 0
    }
    const count = filters.products.size + filters.dispositions.size + filters.waits.size + (filters.human ? 1 : 0) + (filters.blocking ? 1 : 0)
    this.filterCountTarget.textContent = count ? `(${count})` : ""
    return filters
  }

  // Selection

  #select(id, { center = false } = {}) {
    this.selected = id
    this.chainButtonTarget.disabled = !id
    this.#highlight()
    this.#renderPanel()
    if (id && center) this.#center(id)
  }

  #highlight() {
    const upstream = this.selected ? chain(this.graph, this.selected, "up") : new Set()
    const downstream = this.selected ? chain(this.graph, this.selected, "down") : new Set()
    const related = new Set([ this.selected, ...upstream, ...downstream ])

    this.svgTarget.classList.toggle("work-map__svg--selecting", !!this.selected)
    for (const [ id, group ] of this.nodeElements) {
      group.classList.toggle("is-selected", id === this.selected)
      group.classList.toggle("is-upstream", upstream.has(id))
      group.classList.toggle("is-downstream", downstream.has(id))
      group.classList.toggle("is-related", related.has(id))
    }
    for (const edge of this.graph.edges) {
      this.edgeElements.get(edge.index)?.classList.toggle("is-related", related.has(edge.from) && related.has(edge.to))
    }
  }

  #renderPanel() {
    const panel = this.panelTarget
    const node = this.selected && this.graph.nodes.get(this.selected)
    panel.hidden = !node
    if (!node) return panel.replaceChildren()

    const parts = []
    if (node.kind === "card") {
      parts.push(heading(`${this.#productName(node.product)} #${node.number}`), paragraph(node.title, "work-map__panel-title"))
      parts.push(definitions([
        [ "Columna", node.stage ],
        [ "Ejecución", node.execution ? node.execution.state : EXECUTION_STATUSES[node.execution_status] ],
        ...this.#waitRows(node),
        ...this.#milestoneRows(node)
      ]))
      parts.push(...this.#relationLists(node))
      const link = document.createElement("a")
      Object.assign(link, { href: node.url, className: "btn work-map__open", textContent: "Abrir tarjeta" })
      link.dataset.turboFrame = "_top"
      parts.push(link)
    } else if (node.kind === "missing") {
      parts.push(heading(`${this.#productName(node.product)} #${node.number}`),
        paragraph("Referencia ausente: Dédalo nombra esta tarjeta, pero no existe en Fizzy."))
      parts.push(...this.#relationLists(node))
    } else {
      parts.push(heading("Tarjeta sin acceso"), paragraph("La relación apunta a una tarjeta fuera de tus tableros. No se muestran sus datos."))
      parts.push(...this.#relationLists(node))
    }

    const close = document.createElement("button")
    Object.assign(close, { type: "button", className: "btn work-map__panel-close", textContent: "Cerrar" })
    close.addEventListener("click", () => this.#select(null))
    panel.replaceChildren(close, ...parts)
  }

  #waitRows(node) {
    const wait = node.execution?.wait
    if (!wait) {
      if (!node.execution) return []
      return [ [ "Espera", waitsOnOthers(this.graph, node.id) ? "Espera dependencias vigentes" : "Sin bloqueos" ] ]
    }
    return [
      [ "Motivo de espera", WAIT_KINDS[wait.kind] ],
      wait.reason && [ "Detalle", wait.reason ],
      [ "Espera desde", wait.since ? formatTime(wait.since) : "Sin fecha en la fuente" ],
      [ "Última comprobación", wait.checked_at ? formatTime(wait.checked_at) : "Sin fecha en la fuente" ],
      [ "Atención", HUMAN[wait.human] || HUMAN.unknown ],
      wait.next_step && [ "Siguiente paso", wait.next_step ]
    ].filter(Boolean)
  }

  #milestoneRows(node) {
    const milestones = node.execution?.milestones || {}
    return [
      [ "Cerrada", node.closed_at ? formatTime(node.closed_at) : "No" ],
      node.execution && [ "Integrada a main", milestones.integrated_at ? formatTime(milestones.integrated_at) : "No" ],
      node.execution && [ "Desplegada", milestones.deployed_at ? formatTime(milestones.deployed_at) : "No" ],
      node.execution && [ "Publicada", milestones.published_at ? formatTime(milestones.published_at) : "No" ]
    ].filter(Boolean)
  }

  #relationLists(node) {
    const before = this.graph.incoming.get(node.id) || []
    const after = this.graph.outgoing.get(node.id) || []
    const freed = released(this.graph, node.id)
    const lists = []

    lists.push(heading("Prerrequisitos", "h3"))
    lists.push(before.length ? this.#relationList(before, edge => edge.from) : paragraph(this.#noRelations()))
    lists.push(heading("Dependientes", "h3"))
    lists.push(after.length ? this.#relationList(after, edge => edge.to) : paragraph(this.#noRelations()))
    if (freed.size) {
      lists.push(paragraph(`Resolverla destrabaría ${freed.size} ${freed.size === 1 ? "tarjeta" : "tarjetas"}, directas y transitivas: ` +
        [ ...freed ].map(id => this.#label(id)).join(", ") + "."))
    }
    return lists
  }

  #noRelations() {
    return this.payload.source.status === "ok" ? "Ninguna registrada." : "Sin dato: la fuente de ejecución no respondió."
  }

  #relationList(edges, other) {
    const list = document.createElement("ul")
    list.className = "work-map__relations"
    edges.forEach(edge => {
      const item = document.createElement("li")
      const scope = [ edge.environment, edge.channel ].filter(Boolean).join(" / ")
      item.textContent = `${this.#label(other(edge))}: ${CONDITIONS[edge.condition]}${scope ? ` (${scope})` : ""}, ${RELATION_STATUSES[edge.status]}` +
        (edge.since ? `, desde ${formatTime(edge.since)}` : "") + (edge.resolved_at ? `, resuelta ${formatTime(edge.resolved_at)}` : "")
      item.className = `work-map__relation work-map__relation--${edge.status}`
      list.append(item)
    })
    return list
  }

  #open() {
    const node = this.selected && this.graph.nodes.get(this.selected)
    if (node?.url) Turbo.visit(node.url)
    else if (!this.selected) this.#move(0, 0)
  }

  // Moves the selection to the nearest visible node in a direction; with no
  // selection, it selects the first node of the map.
  #move(dx, dy) {
    const positions = this.layout.positions
    if (!this.selected) {
      const first = [ ...positions.entries() ].sort(([ , a ], [ , b ]) => (a.y - b.y) || (a.x - b.x))[0]
      if (first) this.#select(first[0], { center: true })
      return
    }

    const here = positions.get(this.selected)
    let best = null
    let bestScore = Infinity
    for (const [ id, position ] of positions) {
      if (id === this.selected) continue
      const along = (position.x - here.x) * dx + (position.y - here.y) * dy
      if (along <= 0) continue
      const across = Math.abs((position.x - here.x) * dy) + Math.abs((position.y - here.y) * dx)
      const score = along + across * 2
      if (score < bestScore) {
        best = id
        bestScore = score
      }
    }
    if (best) this.#select(best, { center: true })
  }

  // View transform

  #zoomAt(factor, point = this.#viewCenter()) {
    const k = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.view.k * factor))
    const ratio = k / this.view.k
    this.view.x = point.x - (point.x - this.view.x) * ratio
    this.view.y = point.y - (point.y - this.view.y) * ratio
    this.view.k = k
    this.#applyView()
  }

  #fitBox(box) {
    const { width, height } = this.canvasTarget.getBoundingClientRect()
    if (!width || !height) return
    const k = Math.min(MAX_SCALE, Math.max(MIN_SCALE, Math.min(width / box.width, height / box.height, 1.2)))
    this.view = { k, x: (width - box.width * k) / 2 - box.x * k, y: (height - box.height * k) / 2 - box.y * k }
    this.#applyView()
  }

  #center(id) {
    const position = this.layout.positions.get(id)
    const { width, height } = this.canvasTarget.getBoundingClientRect()
    if (!position) return
    this.view.k = Math.max(this.view.k, 0.8)
    this.view.x = width / 2 - (position.x + NODE_WIDTH / 2) * this.view.k
    this.view.y = height / 2 - (position.y + NODE_HEIGHT / 2) * this.view.k
    this.#applyView()
  }

  #applyView() {
    this.viewport?.setAttribute("transform", `translate(${this.view.x} ${this.view.y}) scale(${this.view.k})`)
    this.canvasTarget.dataset.scale = this.view.k.toFixed(2)
  }

  #viewCenter() {
    const { width, height } = this.canvasTarget.getBoundingClientRect()
    return { x: width / 2, y: height / 2 }
  }

  #local(event) {
    const rect = this.canvasTarget.getBoundingClientRect()
    return { x: event.clientX - rect.left, y: event.clientY - rect.top }
  }

  #pinchState() {
    const [ a, b ] = [ ...this.pointers.values() ]
    const rect = this.canvasTarget.getBoundingClientRect()
    return { distance: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), center: { x: (a.x + b.x) / 2 - rect.left, y: (a.y + b.y) / 2 - rect.top } }
  }

  // Labels

  #productName(key) {
    return this.graph.products.get(key)?.name || key
  }

  #productColor(key) {
    const index = this.graph.products.get(key)?.index ?? 0
    return PRODUCT_COLORS[index % PRODUCT_COLORS.length]
  }

  #label(id) {
    const node = this.graph.nodes.get(id)
    if (node.kind === "card") return `${this.#productName(node.product)} #${node.number}`
    if (node.kind === "missing") return `${this.#productName(node.product)} #${node.number} (ausente)`
    return "Tarjeta sin acceso"
  }

  #announce(text) {
    this.element.querySelector(".work-map__search-result")?.remove()
    if (text) {
      const result = document.createElement("p")
      result.className = "work-map__search-result"
      result.setAttribute("role", "status")
      result.textContent = text
      this.searchTarget.closest("form").after(result)
    }
  }
}

function element(name, attributes = {}) {
  const node = document.createElementNS(SVG, name)
  for (const [ key, value ] of Object.entries(attributes)) node.setAttribute(key, value)
  return node
}

function heading(text, level = "h2") {
  const node = document.createElement(level)
  node.textContent = text
  return node
}

function paragraph(text, className) {
  const node = document.createElement("p")
  node.textContent = text
  if (className) node.className = className
  return node
}

function definitions(rows) {
  const list = document.createElement("dl")
  rows.forEach(([ term, value ]) => {
    const dt = document.createElement("dt")
    const dd = document.createElement("dd")
    dt.textContent = term
    dd.textContent = value
    list.append(dt, dd)
  })
  return list
}

function clip(text, length) {
  text = String(text || "")
  return text.length > length ? `${text.slice(0, length - 1)}…` : text
}

function formatTime(iso) {
  if (!iso) return "sin fecha"
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? "sin fecha" : date.toLocaleString("es-MX", { dateStyle: "medium", timeStyle: "short" })
}
