// Matches the worker's public-only namespace. Includes every retired private cache.
export async function clearOfflineCache() {
  if ("caches" in window) {
    const names = await caches.keys()
    await Promise.all(names.filter(name => name !== "fizzy-assets-v3").map(name => caches.delete(name)))
  }
}
