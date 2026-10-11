// These names belong to the retired worker, which cached private responses.
// Keep them aligned with service_worker.js.erb during the migration.
export async function clearOfflineCache() {
  if ("caches" in window) {
    await Promise.all([ "main", "storage", "assets" ].map(name => caches.delete(name)))
  }
}
