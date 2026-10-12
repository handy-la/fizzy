import { clearOfflineCache } from "lib/offline_cache"

// The worker owns cache policy and session transitions, including native forms
// and JSON requests. Turbo's offline preloader must not bypass that policy.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/service-worker.js", { scope: "/" }).catch(console.error)
}

clearOfflineCache().catch(console.error)
document.addEventListener("turbo:load", () => clearOfflineCache().catch(console.error))
window.addEventListener("pageshow", () => clearOfflineCache().catch(console.error))
