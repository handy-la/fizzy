import { post } from "@rails/request.js"

export async function currentPushSubscription() {
  const registration = await navigator.serviceWorker?.getRegistration("/service-worker.js", { scope: "/" })
  return registration?.pushManager?.getSubscription()
}

export function pushSubscriptionBody(subscription) {
  const { endpoint, keys: { p256dh, auth } } = subscription.toJSON()
  return JSON.stringify({ push_subscription: { endpoint, p256dh_key: p256dh, auth_key: auth } })
}

export async function verifyPushSubscription(subscription, url) {
  if (!url) {
    await subscription.unsubscribe()
    return false
  }

  try {
    const response = await post(url, { body: pushSubscriptionBody(subscription), responseKind: "json" })
    if (response.statusCode === 204) return true

    if ([ 401, 403, 409 ].includes(response.statusCode)) {
      await subscription.unsubscribe()
    }
  } catch {
    // Keep the endpoint during temporary outages, but never enable unverified push.
  }

  return false
}

export async function reconcilePushSubscription() {
  const subscription = await currentPushSubscription()
  if (subscription) {
    const url = document.querySelector('meta[name="push-subscription-verification-url"]')?.content
    await verifyPushSubscription(subscription, url)
  }
}
