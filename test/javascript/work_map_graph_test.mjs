// Authoring answers: docs/test-audits/handy-2348.md.
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import test from "node:test"

// The helper imports nothing, so it loads as the browser loads it: one ES
// module, read from the file the importmap serves.
const path = resolve(dirname(fileURLToPath(import.meta.url)), "../../app/javascript/helpers/work_map_graph.js")
const source = await readFile(path, "utf8")
const graphModule = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)
const { buildGraph, chain, visibleIds, hiddenRelations, search, layout, needsHuman, blocksOthers, NODE_WIDTH } = graphModule

function card(product, number, extra = {}) {
  return { id: `card-${number}`, kind: "card", product, number, title: `Tarjeta ${number}`, disposition: "column", execution: null, ...extra }
}

function edge(from, to, status = "pending") {
  return { from: `card-${from}`, to: `card-${to}`, condition: "integration", status }
}

function payload(nodes, edges) {
  return {
    products: [ { key: "dedalo", name: "Dédalo" }, { key: "handy", name: "Handy" }, { key: "promo", name: "Promo" } ],
    nodes, edges
  }
}

// A → B → C across three products, plus D waiting on B, an isolated E and a
// satisfied relation F → C.
function crossChain() {
  return buildGraph(payload([
    card("dedalo", 1), card("handy", 2, { execution: { state: "held", wait: { kind: "card", human: "not_required" } } }),
    card("promo", 3), card("handy", 4), card("promo", 5, { disposition: "maybe" }), card("dedalo", 6, { disposition: "closed" })
  ], [ edge(1, 2), edge(2, 3), edge(2, 4), edge(6, 3, "satisfied") ]))
}

test("resolving A releases its direct and transitive dependents across products", () => {
  const graph = crossChain()

  assert.deepEqual([ ...chain(graph, "card-1", "down") ].sort(), [ "card-2", "card-3", "card-4" ])
  assert.deepEqual([ ...chain(graph, "card-3", "up") ].sort(), [ "card-1", "card-2", "card-6" ])
  assert.deepEqual([ ...chain(graph, "card-3", "up", { onlyPending: true }) ].sort(), [ "card-1", "card-2" ],
    "a satisfied relation releases nothing")
})

test("a cycle ends the walk and keeps every relation", () => {
  const graph = buildGraph(payload([ card("handy", 1), card("handy", 2), card("promo", 3) ], [ edge(1, 2), edge(2, 3), edge(3, 1) ]))

  assert.deepEqual([ ...chain(graph, "card-1", "down") ].sort(), [ "card-2", "card-3" ])
  const drawn = layout(graph, visibleIds(graph))
  assert.equal(drawn.cycleEdges.size, 1, "one relation closes the cycle and is drawn back")
  assert.equal(drawn.positions.size, 3)
})

test("with no filter every product shows together; each filter narrows, and none hides a relation silently", () => {
  const graph = crossChain()
  const all = visibleIds(graph, {})

  assert.equal(all.size, 6)
  assert.deepEqual([ ...visibleIds(graph, { products: new Set([ "handy" ]) }) ].sort(), [ "card-2", "card-4" ])
  assert.deepEqual([ ...visibleIds(graph, { dispositions: new Set([ "maybe" ]) }) ], [ "card-5" ])
  assert.deepEqual([ ...visibleIds(graph, { waits: new Set([ "card" ]) }) ], [ "card-2" ])
  assert.deepEqual([ ...visibleIds(graph, { blocking: true }) ].sort(), [ "card-1", "card-2" ])
  assert.equal(hiddenRelations(graph, visibleIds(graph, { products: new Set([ "handy" ]) })), 2,
    "A → B and B → C cross the product filter and are counted")
  assert.equal(hiddenRelations(graph, all), 0)
})

test("needs a person: a human wait, or a wait that asks for one", () => {
  assert.equal(needsHuman(card("handy", 1, { execution: { wait: { kind: "human", human: "unknown" } } })), true)
  assert.equal(needsHuman(card("handy", 1, { execution: { wait: { kind: "card", human: "required" } } })), true)
  assert.equal(needsHuman(card("handy", 1, { execution: { wait: { kind: "card", human: "not_required" } } })), false)
  assert.equal(needsHuman(card("handy", 1)), false, "no execution data is not a request for a person")

  const graph = buildGraph(payload([ card("handy", 1, { execution: { wait: { kind: "human", human: "required" } } }), card("handy", 2) ], []))
  assert.deepEqual([ ...visibleIds(graph, { human: true }) ], [ "card-1" ])
  assert.equal(blocksOthers(graph, "card-1"), false)
})

test("a hidden or missing reference shows while a related card shows", () => {
  const graph = buildGraph(payload([
    card("handy", 1), { id: "hidden-0-p", kind: "inaccessible", product: null, number: null },
    { id: "missing-promo-77", kind: "missing", product: "promo", number: 77 }
  ], [ { from: "hidden-0-p", to: "card-1", status: "pending" }, { from: "card-1", to: "missing-promo-77", status: "pending" } ]))

  assert.deepEqual([ ...visibleIds(graph, {}) ].sort(), [ "card-1", "hidden-0-p", "missing-promo-77" ])
  assert.deepEqual([ ...visibleIds(graph, { products: new Set([ "promo" ]) }) ], [])
})

test("search finds product and number, a bare number, or a title without accents", () => {
  const graph = buildGraph(payload([ card("handy", 2348, { title: "Mapa de trabajo" }), card("promo", 12, { title: "Campaña de diciembre" }) ], []))

  assert.deepEqual(search(graph, "handy 2348"), [ "card-2348" ])
  assert.deepEqual(search(graph, "Handy #2348"), [ "card-2348" ])
  assert.deepEqual(search(graph, "#12"), [ "card-12" ])
  assert.deepEqual(search(graph, "promo 2348"), [], "the product must match too")
  assert.deepEqual(search(graph, "campana"), [ "card-12" ])
  assert.deepEqual(search(graph, "dédalo"), [])
})

test("layout: relations go left to right, isolated cards follow grouped by product", () => {
  const graph = crossChain()
  const drawn = layout(graph, visibleIds(graph))

  const x = id => drawn.positions.get(id).x
  assert.ok(x("card-1") < x("card-2") && x("card-2") < x("card-3"))
  assert.ok(drawn.positions.get("card-5").y > Math.max(...[ "card-1", "card-2", "card-3", "card-4" ].map(id => drawn.positions.get(id).y)))
  assert.deepEqual(drawn.labels.map(label => label.text), [ "Promo" ])
  assert.ok(drawn.width >= NODE_WIDTH)
})

test("volume: 3000 cards, 3000 relations and cycles lay out in well under a second", () => {
  const products = [ "dedalo", "handy", "handy-sales", "jace", "promo" ]
  const nodes = Array.from({ length: 3000 }, (_, index) => card(products[index % products.length], index + 1))
  const edges = []
  for (let index = 1; index <= 3000; index++) {
    if (index % 3 !== 0) edges.push(edge(index, ((index * 7) % 3000) + 1))
  }
  edges.push(edge(10, 20), edge(20, 10))
  const graph = buildGraph(payload(nodes, edges))

  const started = performance.now()
  const drawn = layout(graph, visibleIds(graph))
  const elapsed = performance.now() - started

  assert.equal(drawn.positions.size, 3000)
  assert.ok(elapsed < 1000, `layout took ${elapsed.toFixed(0)} ms`)
  console.log(`# volume: ${nodes.length} cards, ${graph.edges.length} relations, layout ${elapsed.toFixed(0)} ms`)
})
