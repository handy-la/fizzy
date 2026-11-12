// Handy #2348: the pure part of the work map — graph indexes, transitive
// chains, filters, search and layout. No DOM here, so node tests run it as is
// (test/javascript/work_map_graph_test.mjs). Contract: docs/work-map.md.

export const NODE_WIDTH = 210
export const NODE_HEIGHT = 58
const COLUMN_GAP = 70
const ROW_GAP = 16
const BLOCK_GAP = 56
const GRID_COLUMNS = 6
const LABEL_HEIGHT = 28

const HUMAN_ATTENTION = [ "required", "pending" ]

export function buildGraph(payload) {
  const nodes = new Map(payload.nodes.map(node => [ node.id, node ]))
  const products = new Map(payload.products.map((product, index) => [ product.key, { ...product, index } ]))
  const outgoing = new Map()
  const incoming = new Map()
  const edges = payload.edges.filter(edge => nodes.has(edge.from) && nodes.has(edge.to))

  edges.forEach((edge, index) => {
    edge.index = index
    push(outgoing, edge.from, edge)
    push(incoming, edge.to, edge)
  })

  return { nodes, products, edges, outgoing, incoming }
}

// Every node reachable from `id` (not `id` itself) following `direction`:
// "up" walks to prerequisites, "down" to dependents. `onlyPending` keeps the
// relations still in force, which is what resolving a card would release.
export function chain(graph, id, direction, { onlyPending = false } = {}) {
  const adjacency = direction === "up" ? graph.incoming : graph.outgoing
  const next = edge => direction === "up" ? edge.from : edge.to
  const seen = new Set([ id ])
  const queue = [ id ]

  while (queue.length) {
    for (const edge of adjacency.get(queue.shift()) || []) {
      if (onlyPending && edge.status !== "pending") continue
      const other = next(edge)
      if (!seen.has(other)) {
        seen.add(other)
        queue.push(other)
      }
    }
  }

  seen.delete(id)
  return seen
}

export function needsHuman(node) {
  const wait = node.execution?.wait
  return !!wait && (wait.kind === "human" || HUMAN_ATTENTION.includes(wait.human))
}

export function blocksOthers(graph, id) {
  return (graph.outgoing.get(id) || []).some(edge => edge.status === "pending")
}

export function waitsOnOthers(graph, id) {
  return (graph.incoming.get(id) || []).some(edge => edge.status === "pending")
}

// The ids that pass the filters. An empty set in a filter means "all". A
// placeholder (hidden or missing reference) shows while a related card shows.
export function visibleIds(graph, filters = {}) {
  const visible = new Set()
  const { products, dispositions, waits, human, blocking } = filters

  for (const node of graph.nodes.values()) {
    if (node.kind !== "card") continue
    if (products?.size && !products.has(node.product)) continue
    if (dispositions?.size && !dispositions.has(node.disposition)) continue
    if (waits?.size && !waits.has(node.execution?.wait?.kind)) continue
    if (human && !needsHuman(node)) continue
    if (blocking && !blocksOthers(graph, node.id)) continue
    visible.add(node.id)
  }

  for (const edge of graph.edges) {
    const from = graph.nodes.get(edge.from)
    const to = graph.nodes.get(edge.to)
    if (from.kind !== "card" && visible.has(edge.to)) visible.add(edge.from)
    if (to.kind !== "card" && visible.has(edge.from)) visible.add(edge.to)
  }

  return visible
}

// Relations with one end shown and the other hidden by a filter: the map says
// how many, so a filter never hides a dependency silently.
export function hiddenRelations(graph, visible) {
  return graph.edges.filter(edge => visible.has(edge.from) !== visible.has(edge.to)).length
}

export function normalize(text) {
  return String(text || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").trim()
}

// "handy 2348", "Handy #2348", "#2348" or "2348" find by number (and product);
// anything else searches titles. Card numbers are unique per account.
export function search(graph, query) {
  const text = normalize(query)
  if (!text) return []

  const numbered = text.match(/^(?:(.*?)\s*)#?(\d+)$/)
  if (numbered) {
    const [ , productText, number ] = numbered
    const matches = [ ...graph.nodes.values() ].filter(node => String(node.number) === number &&
      (!productText || productMatches(graph.products.get(node.product), productText)))
    if (matches.length) return matches.map(node => node.id)
  }

  return [ ...graph.nodes.values() ]
    .filter(node => node.kind === "card" && normalize(node.title).includes(text))
    .map(node => node.id)
}

function productMatches(product, text) {
  return !!product && (normalize(product.key).startsWith(text) || normalize(product.name).startsWith(text))
}

// A deterministic layered layout. Connected groups first, largest first: each
// relation goes left to right, by longest path from its sources; a relation
// that closes a cycle is marked and drawn back. Cards with no visible
// relation follow in a grid per product, under the product's name.
export function layout(graph, visible) {
  const ids = [ ...visible ].sort((a, b) => order(graph, a, b))
  const edges = graph.edges.filter(edge => visible.has(edge.from) && visible.has(edge.to))
  const components = connectedComponents(ids, edges)
  const positions = new Map()
  const labels = []
  const cycleEdges = new Set()
  let top = 0
  let width = 0

  const linked = components.filter(component => component.length > 1).sort((a, b) => b.length - a.length)
  for (const component of linked) {
    const block = layoutComponent(graph, component, edges, cycleEdges)
    for (const [ id, position ] of block.positions) positions.set(id, { x: position.x, y: position.y + top })
    top += block.height + BLOCK_GAP
    width = Math.max(width, block.width)
  }

  const isolated = components.filter(component => component.length === 1).map(([ id ]) => id)
  const byProduct = groupBy(isolated, id => graph.nodes.get(id).product)
  for (const [ productKey, members ] of byProduct) {
    labels.push({ text: graph.products.get(productKey)?.name || productKey, product: productKey, x: 0, y: top })
    top += LABEL_HEIGHT
    members.forEach((id, index) => {
      positions.set(id, {
        x: (index % GRID_COLUMNS) * (NODE_WIDTH + COLUMN_GAP / 2),
        y: top + Math.floor(index / GRID_COLUMNS) * (NODE_HEIGHT + ROW_GAP)
      })
    })
    top += Math.ceil(members.length / GRID_COLUMNS) * (NODE_HEIGHT + ROW_GAP) + BLOCK_GAP / 2
    width = Math.max(width, Math.min(members.length, GRID_COLUMNS) * (NODE_WIDTH + COLUMN_GAP / 2))
  }

  return { positions, labels, cycleEdges, width, height: Math.max(top, NODE_HEIGHT) }
}

function layoutComponent(graph, component, allEdges, cycleEdges) {
  const members = new Set(component)
  const edges = allEdges.filter(edge => members.has(edge.from))
  const backEdges = findBackEdges(component, edges)
  backEdges.forEach(edge => cycleEdges.add(edge.index))
  const forward = edges.filter(edge => !backEdges.has(edge))

  const out = groupBy(forward, edge => edge.from)
  const into = groupBy(forward, edge => edge.to)

  const rank = new Map(component.map(id => [ id, 0 ]))
  for (const id of topologicalOrder(component, out)) {
    for (const edge of out.get(id) || []) rank.set(edge.to, Math.max(rank.get(edge.to), rank.get(id) + 1))
  }

  const columns = []
  for (const id of component) (columns[rank.get(id)] ||= []).push(id)

  const row = new Map()
  const positions = new Map()
  columns.forEach((column, columnIndex) => {
    // Barycenter of the prerequisites already placed keeps chains straight.
    const weight = id => {
      const rows = (into.get(id) || []).filter(edge => row.has(edge.from)).map(edge => row.get(edge.from))
      return rows.length ? rows.reduce((sum, value) => sum + value, 0) / rows.length : Infinity
    }
    const weights = new Map(column.map(id => [ id, weight(id) ]))
    column.sort((a, b) => compareWeights(weights.get(a), weights.get(b)) || order(graph, a, b))
    column.forEach((id, index) => {
      row.set(id, index)
      positions.set(id, { x: columnIndex * (NODE_WIDTH + COLUMN_GAP), y: index * (NODE_HEIGHT + ROW_GAP) })
    })
  })

  const tallest = Math.max(...columns.map(column => column.length))
  return { positions, width: columns.length * (NODE_WIDTH + COLUMN_GAP) - COLUMN_GAP, height: tallest * (NODE_HEIGHT + ROW_GAP) - ROW_GAP }
}

function findBackEdges(component, edges) {
  const out = new Map()
  edges.forEach(edge => push(out, edge.from, edge))
  const state = new Map()
  const back = new Set()

  for (const start of component) {
    if (state.has(start)) continue
    const stack = [ [ start, 0 ] ]
    state.set(start, "open")
    while (stack.length) {
      const frame = stack[stack.length - 1]
      const list = out.get(frame[0]) || []
      if (frame[1] < list.length) {
        const edge = list[frame[1]++]
        const status = state.get(edge.to)
        if (status === "open") back.add(edge)
        else if (!status) {
          state.set(edge.to, "open")
          stack.push([ edge.to, 0 ])
        }
      } else {
        state.set(frame[0], "done")
        stack.pop()
      }
    }
  }

  return back
}

function compareWeights(a, b) {
  if (a === b) return 0
  if (a === Infinity) return 1
  if (b === Infinity) return -1
  return a - b
}

function topologicalOrder(ids, out) {
  const indegree = new Map(ids.map(id => [ id, 0 ]))
  for (const list of out.values()) list.forEach(edge => indegree.set(edge.to, indegree.get(edge.to) + 1))
  const queue = ids.filter(id => indegree.get(id) === 0)
  const result = []
  for (let head = 0; head < queue.length; head++) {
    const id = queue[head]
    result.push(id)
    for (const edge of out.get(id) || []) {
      indegree.set(edge.to, indegree.get(edge.to) - 1)
      if (indegree.get(edge.to) === 0) queue.push(edge.to)
    }
  }
  return result
}

function connectedComponents(ids, edges) {
  const parent = new Map(ids.map(id => [ id, id ]))
  const find = id => {
    while (parent.get(id) !== id) {
      parent.set(id, parent.get(parent.get(id)))
      id = parent.get(id)
    }
    return id
  }
  edges.forEach(edge => parent.set(find(edge.from), find(edge.to)))
  return [ ...groupBy(ids, find).values() ]
}

function order(graph, a, b) {
  const left = graph.nodes.get(a)
  const right = graph.nodes.get(b)
  const productOrder = (graph.products.get(left.product)?.index ?? 1e6) - (graph.products.get(right.product)?.index ?? 1e6)
  return productOrder || ((left.number || 0) - (right.number || 0)) || (a < b ? -1 : a > b ? 1 : 0)
}

function groupBy(list, key) {
  const groups = new Map()
  list.forEach(item => push(groups, key(item), item))
  return groups
}

function push(map, key, value) {
  if (!map.has(key)) map.set(key, [])
  map.get(key).push(value)
}
