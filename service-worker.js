(function installLeadControlServiceWorker(scope) {
  "use strict";

  const DEFAULT_TITLE = "Controle de Leads";
  const DEFAULT_BODY = "Seu relatório diário está pronto.";
  const DEFAULT_ICON = "./assets/app-icon-192.png";
  const DEFAULT_BADGE = "./assets/favicon-32.png";
  const MAX_TITLE_LENGTH = 90;
  const MAX_BODY_LENGTH = 240;

  function boundedText(value, fallback, limit) {
    const normalized = String(value || "").trim();
    return (normalized || fallback).slice(0, limit);
  }

  function safeUrl(value, { origin, scopeUrl }) {
    const fallback = new URL("./", scopeUrl).href;
    try {
      const candidate = new URL(String(value || "./"), scopeUrl);
      const scopeAddress = new URL(scopeUrl);
      if (candidate.origin !== origin) return fallback;
      if (!candidate.pathname.startsWith(scopeAddress.pathname)) return fallback;
      return candidate.href;
    } catch {
      return fallback;
    }
  }

  function parsePushPayload(rawPayload, context) {
    let payload = {};
    try {
      payload = rawPayload && typeof rawPayload === "object"
        ? rawPayload
        : JSON.parse(String(rawPayload || "{}"));
    } catch {}
    const source = payload.notification && typeof payload.notification === "object"
      ? payload.notification
      : payload;
    const data = source.data && typeof source.data === "object" ? source.data : {};
    const targetUrl = safeUrl(data.url || source.url || "./", context);
    const tag = boundedText(source.tag, "daily-report", 128);

    return {
      title: boundedText(source.title, DEFAULT_TITLE, MAX_TITLE_LENGTH),
      options: {
        body: boundedText(source.body, DEFAULT_BODY, MAX_BODY_LENGTH),
        icon: DEFAULT_ICON,
        badge: DEFAULT_BADGE,
        tag,
        renotify: source.renotify === true,
        requireInteraction: false,
        data: {
          url: targetUrl,
          reportDate: boundedText(data.reportDate || data.report_date, "", 10),
          storeId: boundedText(data.storeId || data.store_id, "", 80),
        },
      },
    };
  }

  async function focusOrOpenClient(clientApi, targetUrl, origin) {
    const windows = await clientApi.matchAll({ type: "window", includeUncontrolled: true });
    const exact = windows.find((client) => client.url === targetUrl);
    if (exact) return exact.focus();

    const sameOrigin = windows.find((client) => {
      try {
        return new URL(client.url).origin === origin;
      } catch {
        return false;
      }
    });
    if (sameOrigin) {
      if (typeof sameOrigin.navigate === "function") await sameOrigin.navigate(targetUrl);
      return sameOrigin.focus();
    }
    return clientApi.openWindow?.(targetUrl);
  }

  if (scope?.addEventListener) {
    scope.addEventListener("install", (event) => {
      event.waitUntil(scope.skipWaiting());
    });

    scope.addEventListener("activate", (event) => {
      event.waitUntil(scope.clients.claim());
    });

    scope.addEventListener("push", (event) => {
      const rawPayload = event.data?.text?.() || "{}";
      const notification = parsePushPayload(rawPayload, {
        origin: scope.location.origin,
        scopeUrl: scope.registration.scope,
      });
      event.waitUntil(scope.registration.showNotification(notification.title, notification.options));
    });

    scope.addEventListener("notificationclick", (event) => {
      event.notification?.close?.();
      const targetUrl = safeUrl(event.notification?.data?.url, {
        origin: scope.location.origin,
        scopeUrl: scope.registration.scope,
      });
      event.waitUntil(focusOrOpenClient(scope.clients, targetUrl, scope.location.origin));
    });

    scope.addEventListener("pushsubscriptionchange", (event) => {
      event.waitUntil((async () => {
        let subscription = event.newSubscription || null;
        if (!subscription && event.oldSubscription?.options) {
          try {
            subscription = await scope.registration.pushManager.subscribe(event.oldSubscription.options);
          } catch {}
        }
        const windows = await scope.clients.matchAll({ type: "window", includeUncontrolled: true });
        windows.forEach((client) => client.postMessage({
          type: "LC_PUSH_SUBSCRIPTION_CHANGED",
        }));
      })());
    });
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { safeUrl, parsePushPayload, focusOrOpenClient };
  }
})(typeof self !== "undefined" ? self : null);
