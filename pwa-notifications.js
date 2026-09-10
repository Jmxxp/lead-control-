(function exposePushNotifications(root, factory) {
  "use strict";

  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  if (root) root.LeadControlPushNotifications = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function createPushNotificationsApi() {
  "use strict";

  const PUSH_STATES = Object.freeze({
    UNSUPPORTED: "unsupported",
    NEEDS_INSTALL: "needs-install",
    IDLE: "idle",
    LOADING: "loading",
    SUBSCRIBED: "subscribed",
    DENIED: "denied",
    ERROR: "error",
  });

  function isLoopbackHostname(hostname) {
    const normalized = String(hostname || "").trim().toLowerCase();
    return normalized === "localhost"
      || normalized === "127.0.0.1"
      || normalized === "[::1]"
      || normalized.endsWith(".localhost");
  }

  function isAppleMobile(navigatorObject) {
    const userAgent = String(navigatorObject?.userAgent || "");
    const platform = String(navigatorObject?.platform || "");
    return /iPad|iPhone|iPod/i.test(userAgent)
      || (platform === "MacIntel" && Number(navigatorObject?.maxTouchPoints || 0) > 1);
  }

  function isStandalone(windowObject, navigatorObject) {
    return navigatorObject?.standalone === true
      || windowObject?.matchMedia?.("(display-mode: standalone)")?.matches === true
      || windowObject?.matchMedia?.("(display-mode: fullscreen)")?.matches === true;
  }

  function inspectPushSupport(environment = {}) {
    const windowObject = environment.windowObject
      || (typeof window !== "undefined" ? window : null);
    const navigatorObject = environment.navigatorObject
      || (typeof navigator !== "undefined" ? navigator : null);
    const notificationApi = environment.notificationApi
      || (typeof Notification !== "undefined" ? Notification : null);
    const locationObject = environment.locationObject || windowObject?.location || null;
    const secureContext = windowObject?.isSecureContext === true
      || isLoopbackHostname(locationObject?.hostname);
    const appleMobile = isAppleMobile(navigatorObject);
    const standalone = isStandalone(windowObject, navigatorObject);

    if (!secureContext) {
      return {
        supported: false,
        state: PUSH_STATES.UNSUPPORTED,
        reason: "As notificações exigem uma conexão HTTPS segura.",
        appleMobile,
        standalone,
      };
    }
    if (appleMobile && !standalone) {
      return {
        supported: false,
        state: PUSH_STATES.NEEDS_INSTALL,
        reason: "No iPhone ou iPad, adicione este app à Tela de Início antes de ativar notificações.",
        appleMobile,
        standalone,
      };
    }
    if (!navigatorObject?.serviceWorker || !notificationApi) {
      return {
        supported: false,
        state: PUSH_STATES.UNSUPPORTED,
        reason: "Este navegador não oferece notificações em segundo plano.",
        appleMobile,
        standalone,
      };
    }
    const hasPushManager = Boolean(windowObject?.PushManager)
      || (typeof PushManager !== "undefined");
    if (!hasPushManager) {
      return {
        supported: false,
        state: PUSH_STATES.UNSUPPORTED,
        reason: "O serviço de notificações deste navegador não está disponível.",
        appleMobile,
        standalone,
      };
    }

    return {
      supported: true,
      state: PUSH_STATES.IDLE,
      reason: "",
      appleMobile,
      standalone,
    };
  }

  function decodeBase64Url(value) {
    const normalized = String(value || "").trim().replace(/-/g, "+").replace(/_/g, "/");
    if (!normalized || !/^[A-Za-z0-9+/]*={0,2}$/.test(normalized)) {
      throw new Error("A chave pública de notificações é inválida.");
    }
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    let binary;
    if (typeof atob === "function") {
      binary = atob(padded);
    } else if (typeof Buffer !== "undefined") {
      binary = Buffer.from(padded, "base64").toString("binary");
    } else {
      throw new Error("Este navegador não consegue interpretar a chave de notificações.");
    }
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  }

  function extractApplicationServerKey(response) {
    const value = typeof response === "string"
      ? response
      : response?.vapid_public_key
        || response?.public_key
        || response?.application_server_key
        || response?.applicationServerKey;
    const bytes = decodeBase64Url(value);
    if (bytes.length !== 65 || bytes[0] !== 4) {
      throw new Error("O servidor retornou uma chave pública de notificações inválida.");
    }
    return bytes;
  }

  function subscriptionToPayload(subscription) {
    const serialized = subscription?.toJSON?.() || {};
    const endpoint = String(serialized.endpoint || subscription?.endpoint || "").trim();
    const keys = serialized.keys || {};
    const p256dh = String(keys.p256dh || "").trim();
    const auth = String(keys.auth || "").trim();
    if (!endpoint.startsWith("https://") || !p256dh || !auth) {
      throw new Error("A assinatura de notificações retornada pelo navegador está incompleta.");
    }
    return {
      endpoint,
      expiration_time: serialized.expirationTime ?? subscription?.expirationTime ?? null,
      keys: { p256dh, auth },
      content_encoding: "aes128gcm",
    };
  }

  function collectDeviceMetadata(environment = {}) {
    const windowObject = environment.windowObject
      || (typeof window !== "undefined" ? window : null);
    const navigatorObject = environment.navigatorObject
      || (typeof navigator !== "undefined" ? navigator : null);
    let timezone = "";
    try {
      timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
    } catch {}
    return {
      user_agent: String(navigatorObject?.userAgent || "").slice(0, 512),
      language: String(navigatorObject?.language || "").slice(0, 32),
      timezone: timezone.slice(0, 120),
      platform: String(navigatorObject?.platform || "").slice(0, 80),
      display_mode: isStandalone(windowObject, navigatorObject) ? "standalone" : "browser",
    };
  }

  function createClient(options = {}) {
    const environment = options.environment || {};
    const windowObject = environment.windowObject
      || (typeof window !== "undefined" ? window : null);
    const navigatorObject = environment.navigatorObject
      || (typeof navigator !== "undefined" ? navigator : null);
    const notificationApi = environment.notificationApi
      || (typeof Notification !== "undefined" ? Notification : null);
    const onStateChange = typeof options.onStateChange === "function"
      ? options.onStateChange
      : () => {};
    const getPublicKey = options.getPublicKey;
    const registerSubscription = options.registerSubscription;
    const unregisterSubscription = options.unregisterSubscription;
    const serviceWorkerUrl = options.serviceWorkerUrl || "./service-worker.js";
    const serviceWorkerScope = options.serviceWorkerScope || "./";

    let registrationPromise = null;
    let publicKeyPromise = null;
    let activeSessionKey = "";
    let lastSynchronizedIdentity = "";
    let state = {
      phase: PUSH_STATES.IDLE,
      permission: notificationApi?.permission || "default",
      subscribed: false,
      busy: false,
      error: "",
      support: inspectPushSupport(environment),
    };

    function publish(patch = {}) {
      state = Object.freeze({ ...state, ...patch });
      onStateChange(state);
      return state;
    }

    function currentState() {
      return state;
    }

    async function ensureServiceWorker() {
      const support = inspectPushSupport(environment);
      if (!support.supported) throw new Error(support.reason);
      if (!registrationPromise) {
        registrationPromise = navigatorObject.serviceWorker
          .register(serviceWorkerUrl, { scope: serviceWorkerScope, updateViaCache: "none" })
          .then(async (registered) => {
            const ready = navigatorObject.serviceWorker.ready;
            return ready && typeof ready.then === "function" ? ready : registered;
          })
          .catch((error) => {
            registrationPromise = null;
            throw error;
          });
      }
      return registrationPromise;
    }

    async function loadPublicKey() {
      if (typeof getPublicKey !== "function") {
        throw new Error("O servidor ainda não disponibilizou a chave de notificações.");
      }
      if (!publicKeyPromise) {
        publicKeyPromise = Promise.resolve()
          .then(() => getPublicKey())
          .then(extractApplicationServerKey)
          .catch((error) => {
            publicKeyPromise = null;
            throw error;
          });
      }
      return publicKeyPromise;
    }

    async function synchronizeSubscription(subscription, force = false) {
      const sessionKey = activeSessionKey;
      if (!sessionKey || typeof registerSubscription !== "function") return;
      const payload = subscriptionToPayload(subscription);
      const identity = `${sessionKey}:${payload.endpoint}`;
      if (!force && identity === lastSynchronizedIdentity) return;
      if (sessionKey !== activeSessionKey) return;
      await registerSubscription(payload, collectDeviceMetadata(environment));
      if (sessionKey === activeSessionKey) lastSynchronizedIdentity = identity;
    }

    async function refresh({ synchronize = false } = {}) {
      const support = inspectPushSupport(environment);
      if (!support.supported) {
        return publish({
          phase: support.state,
          permission: notificationApi?.permission || "default",
          subscribed: false,
          busy: false,
          error: "",
          support,
        });
      }

      const permission = notificationApi.permission || "default";
      if (permission === "denied") {
        return publish({
          phase: PUSH_STATES.DENIED,
          permission,
          subscribed: false,
          busy: false,
          error: "",
          support,
        });
      }

      try {
        const registration = await ensureServiceWorker();
        const subscription = permission === "granted"
          ? await registration.pushManager.getSubscription()
          : null;
        if (subscription && synchronize) await synchronizeSubscription(subscription);
        return publish({
          phase: subscription ? PUSH_STATES.SUBSCRIBED : PUSH_STATES.IDLE,
          permission,
          subscribed: Boolean(subscription),
          busy: false,
          error: "",
          support,
        });
      } catch (error) {
        return publish({
          phase: PUSH_STATES.ERROR,
          permission,
          busy: false,
          error: error?.message || "Não foi possível sincronizar as notificações.",
          support,
        });
      }
    }

    async function initialize() {
      const support = inspectPushSupport(environment);
      publish({ support, phase: support.state, busy: false, error: "" });
      if (!support.supported) return state;
      try {
        await ensureServiceWorker();
      } catch (error) {
        return publish({
          phase: PUSH_STATES.ERROR,
          error: error?.message || "Não foi possível preparar as notificações.",
        });
      }
      return refresh();
    }

    async function activateSession(sessionKey) {
      activeSessionKey = String(sessionKey || "").trim();
      lastSynchronizedIdentity = "";
      if (!activeSessionKey) return refresh();
      if (inspectPushSupport(environment).supported) void loadPublicKey().catch(() => {});
      return refresh({ synchronize: true });
    }

    function deactivateSession() {
      activeSessionKey = "";
      lastSynchronizedIdentity = "";
    }

    async function enable() {
      const support = inspectPushSupport(environment);
      if (!support.supported) {
        publish({ phase: support.state, support, error: "" });
        return state;
      }
      if (!activeSessionKey) {
        return publish({
          phase: PUSH_STATES.ERROR,
          error: "Entre novamente antes de ativar as notificações.",
        });
      }

      publish({ phase: PUSH_STATES.LOADING, busy: true, error: "", support });
      try {
        const registrationPromiseValue = ensureServiceWorker();
        const keyPromise = loadPublicKey();
        const permission = notificationApi.permission === "granted"
          ? "granted"
          : await notificationApi.requestPermission();
        if (permission !== "granted") {
          return publish({
            phase: permission === "denied" ? PUSH_STATES.DENIED : PUSH_STATES.IDLE,
            permission,
            subscribed: false,
            busy: false,
          });
        }

        const [registration, applicationServerKey] = await Promise.all([
          registrationPromiseValue,
          keyPromise,
        ]);
        const existing = await registration.pushManager.getSubscription();
        const subscription = existing || await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey,
        });
        await synchronizeSubscription(subscription, true);
        return publish({
          phase: PUSH_STATES.SUBSCRIBED,
          permission,
          subscribed: true,
          busy: false,
          error: "",
        });
      } catch (error) {
        return publish({
          phase: PUSH_STATES.ERROR,
          permission: notificationApi.permission || "default",
          busy: false,
          error: error?.message || "Não foi possível ativar as notificações.",
        });
      }
    }

    async function disable() {
      const support = inspectPushSupport(environment);
      if (!support.supported) return refresh();
      publish({ phase: PUSH_STATES.LOADING, busy: true, error: "", support });
      try {
        const registration = await ensureServiceWorker();
        const subscription = await registration.pushManager.getSubscription();
        if (subscription) {
          const payload = subscriptionToPayload(subscription);
          if (typeof unregisterSubscription !== "function") {
            throw new Error("O servidor ainda não permite desativar notificações.");
          }
          await unregisterSubscription(payload.endpoint);
          await subscription.unsubscribe();
        }
        lastSynchronizedIdentity = "";
        return publish({
          phase: PUSH_STATES.IDLE,
          permission: notificationApi.permission || "default",
          subscribed: false,
          busy: false,
          error: "",
        });
      } catch (error) {
        return publish({
          phase: PUSH_STATES.ERROR,
          busy: false,
          error: error?.message || "Não foi possível desativar as notificações.",
        });
      }
    }

    function handleServiceWorkerMessage(event) {
      if (event?.data?.type !== "LC_PUSH_SUBSCRIPTION_CHANGED") return;
      lastSynchronizedIdentity = "";
      if (activeSessionKey) void refresh({ synchronize: true });
    }

    navigatorObject?.serviceWorker?.addEventListener?.("message", handleServiceWorkerMessage);

    return Object.freeze({
      initialize,
      activateSession,
      deactivateSession,
      refresh,
      enable,
      disable,
      getState: currentState,
    });
  }

  return Object.freeze({
    PUSH_STATES,
    inspectPushSupport,
    decodeBase64Url,
    extractApplicationServerKey,
    subscriptionToPayload,
    collectDeviceMetadata,
    createClient,
  });
});
