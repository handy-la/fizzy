import { reconcilePushSubscription } from "helpers/push_subscription"

function reconcile() {
  reconcilePushSubscription().catch(() => {})
}

document.addEventListener("turbo:load", reconcile)
window.addEventListener("pageshow", reconcile)
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") reconcile()
})
