"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  PUSH_STATES,
  createClient,
  decodeBase64Url,
  extractApplicationServerKey,
  inspectPushSupport,
} = require("../pwa-notifications.js");

function base64Url(bytes) {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function validApplicationServerKey() {
  const bytes = Uint8Array.from({ length: 65 }, (_, index) => index === 0 ? 4 : index);
  return { bytes, encoded: base64Url(bytes) };
}

function createSubscription(overrides = {}) {
  let unsubscribeCalls = 0;
  const serialized = {
    endpoint: "https://push.example.test/subscriptions/device-1",
    expirationTime: 1760000000000,
    keys: {
      p256dh: "public-device-key",
      auth: "auth-secret",
    },
    ...overrides,
  };
  const subscription = {
    endpoint: serialized.endpoint,
    expirationTime: serialized.expirationTime,
    toJSON: () => ({ ...serialized, keys: { ...serialized.keys } }),
    async unsubscribe() {
      unsubscribeCalls += 1;
      return true;
    },
  };
  return { subscription, unsubscribeCalls: () => unsubscribeCalls };
}

function createPushHarness({
  permission = "default",
  existingSubscription = null,
  requestPermissionResult = "granted",
  registerSubscription,
  unregisterSubscription,
} = {}) {
  const calls = {
    serviceWorkerRegister: [],
    getSubscription: 0,
    subscribe: [],
    requestPermission: 0,
    registerSubscription: [],
    unregisterSubscription: [],
    messageListeners: [],
    states: [],
  };
  let currentSubscription = existingSubscription;
  const notificationApi = {
    permission,
    async requestPermission() {
      calls.requestPermission += 1;
      this.permission = requestPermissionResult;
      return requestPermissionResult;
    },
  };
  const registration = {
    pushManager: {
      async getSubscription() {
        calls.getSubscription += 1;
        return currentSubscription;
      },
      async subscribe(options) {
        calls.subscribe.push(options);
        const created = createSubscription().subscription;
        currentSubscription = created;
        return created;
      },
    },
  };
  const serviceWorker = {
    ready: Promise.resolve(registration),
    async register(url, options) {
      calls.serviceWorkerRegister.push({ url, options });
      return registration;
    },
    addEventListener(type, listener) {
      calls.messageListeners.push({ type, listener });
    },
  };
  const navigatorObject = {
    serviceWorker,
    userAgent: "Lead Control Test Browser",
    language: "pt-BR",
    platform: "TestOS",
    maxTouchPoints: 0,
  };
  const windowObject = {
    isSecureContext: true,
    location: { hostname: "app.example.test" },
    PushManager: function PushManager() {},
    matchMedia: () => ({ matches: false }),
  };
  const { encoded } = validApplicationServerKey();
  const client = createClient({
    environment: { windowObject, navigatorObject, notificationApi },
    serviceWorkerUrl: "./service-worker.js",
    serviceWorkerScope: "./",
    getPublicKey: async () => ({ vapid_public_key: encoded }),
    registerSubscription: async (payload, device) => {
      calls.registerSubscription.push({ payload, device });
      return registerSubscription?.(payload, device);
    },
    unregisterSubscription: async (endpoint) => {
      calls.unregisterSubscription.push(endpoint);
      return unregisterSubscription?.(endpoint);
    },
    onStateChange: (state) => calls.states.push(state),
  });
  return {
    calls,
    client,
    notificationApi,
    registration,
    navigatorObject,
    windowObject,
  };
}

test("VAPID base64url é decodificada sem perder bytes e rejeita chaves inválidas", () => {
  const { bytes, encoded } = validApplicationServerKey();

  assert.deepEqual(decodeBase64Url(encoded), bytes);
  assert.deepEqual(extractApplicationServerKey({ public_key: encoded }), bytes);
  assert.deepEqual(extractApplicationServerKey({ applicationServerKey: encoded }), bytes);
  assert.throws(() => decodeBase64Url("%%%"), /chave pública.*inválida/i);
  assert.throws(() => extractApplicationServerKey(base64Url(Uint8Array.of(4, 1, 2))), /servidor.*inválida/i);

  const wrongPrefix = Uint8Array.from(bytes);
  wrongPrefix[0] = 3;
  assert.throws(() => extractApplicationServerKey(base64Url(wrongPrefix)), /servidor.*inválida/i);
});

test("iPhone e iPad exigem instalação na Tela de Início antes do Web Push", () => {
  const common = {
    windowObject: {
      isSecureContext: true,
      location: { hostname: "app.example.test" },
      PushManager: function PushManager() {},
      matchMedia: () => ({ matches: false }),
    },
    navigatorObject: {
      userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)",
      platform: "iPhone",
      serviceWorker: {},
    },
    notificationApi: { permission: "default" },
  };

  const browserResult = inspectPushSupport(common);
  assert.equal(browserResult.supported, false);
  assert.equal(browserResult.state, PUSH_STATES.NEEDS_INSTALL);
  assert.equal(browserResult.appleMobile, true);
  assert.equal(browserResult.standalone, false);

  const installedResult = inspectPushSupport({
    ...common,
    navigatorObject: { ...common.navigatorObject, standalone: true },
  });
  assert.equal(installedResult.supported, true);
  assert.equal(installedResult.state, PUSH_STATES.IDLE);
  assert.equal(installedResult.standalone, true);

  const iPadDesktopUa = inspectPushSupport({
    ...common,
    navigatorObject: {
      ...common.navigatorObject,
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)",
      platform: "MacIntel",
      maxTouchPoints: 5,
    },
  });
  assert.equal(iPadDesktopUa.state, PUSH_STATES.NEEDS_INSTALL);
});

test("ativação pede permissão no gesto do usuário, assina com VAPID e registra payload seguro", async () => {
  const harness = createPushHarness();

  await harness.client.initialize();
  await harness.client.activateSession("agency-1:opaque-session");
  const state = await harness.client.enable();

  assert.equal(harness.calls.requestPermission, 1);
  assert.equal(harness.calls.serviceWorkerRegister.length, 1);
  assert.deepEqual(harness.calls.serviceWorkerRegister[0], {
    url: "./service-worker.js",
    options: { scope: "./", updateViaCache: "none" },
  });
  assert.equal(harness.calls.subscribe.length, 1);
  assert.equal(harness.calls.subscribe[0].userVisibleOnly, true);
  assert.deepEqual(harness.calls.subscribe[0].applicationServerKey, validApplicationServerKey().bytes);
  assert.equal(harness.calls.registerSubscription.length, 1);
  assert.deepEqual(harness.calls.registerSubscription[0].payload, {
    endpoint: "https://push.example.test/subscriptions/device-1",
    expiration_time: 1760000000000,
    keys: { p256dh: "public-device-key", auth: "auth-secret" },
    content_encoding: "aes128gcm",
  });
  assert.equal(harness.calls.registerSubscription[0].device.user_agent, "Lead Control Test Browser");
  assert.equal(harness.calls.registerSubscription[0].device.language, "pt-BR");
  assert.equal(harness.calls.registerSubscription[0].device.platform, "TestOS");
  assert.equal(harness.calls.registerSubscription[0].device.display_mode, "browser");
  assert.equal(state.phase, PUSH_STATES.SUBSCRIBED);
  assert.equal(state.permission, "granted");
  assert.equal(state.subscribed, true);
  assert.equal(state.busy, false);
});

test("sessão autenticada sincroniza assinatura já existente apenas uma vez por endpoint", async () => {
  const existing = createSubscription({ endpoint: "https://push.example.test/subscriptions/existing" });
  const harness = createPushHarness({
    permission: "granted",
    existingSubscription: existing.subscription,
  });

  const active = await harness.client.activateSession("agency-2:opaque-session");
  await harness.client.refresh({ synchronize: true });

  assert.equal(active.phase, PUSH_STATES.SUBSCRIBED);
  assert.equal(active.subscribed, true);
  assert.equal(harness.calls.subscribe.length, 0);
  assert.equal(harness.calls.registerSubscription.length, 1);
  assert.equal(
    harness.calls.registerSubscription[0].payload.endpoint,
    "https://push.example.test/subscriptions/existing",
  );
});

test("troca de sessão durante a leitura não registra assinatura no usuário errado", async () => {
  const existing = createSubscription({ endpoint: "https://push.example.test/subscriptions/session-race" });
  const harness = createPushHarness({ permission: "granted" });
  let releaseSubscription;
  harness.registration.pushManager.getSubscription = () => new Promise((resolve) => {
    releaseSubscription = () => resolve(existing.subscription);
  });

  const activation = harness.client.activateSession("agency-old:opaque-session");
  while (!releaseSubscription) await new Promise((resolve) => setImmediate(resolve));
  harness.client.deactivateSession();
  releaseSubscription();
  await activation;

  assert.equal(harness.calls.registerSubscription.length, 0);
});

test("desativação remove primeiro o endpoint no servidor e depois a assinatura do navegador", async () => {
  const order = [];
  const existing = createSubscription();
  existing.subscription.unsubscribe = async () => {
    order.push("browser");
    return true;
  };
  const harness = createPushHarness({
    permission: "granted",
    existingSubscription: existing.subscription,
    unregisterSubscription: async () => order.push("server"),
  });

  await harness.client.activateSession("agency-3:opaque-session");
  const state = await harness.client.disable();

  assert.deepEqual(order, ["server", "browser"]);
  assert.deepEqual(harness.calls.unregisterSubscription, [
    "https://push.example.test/subscriptions/device-1",
  ]);
  assert.equal(state.phase, PUSH_STATES.IDLE);
  assert.equal(state.subscribed, false);
});

test("falha ao remover no servidor preserva assinatura local para permitir nova tentativa", async () => {
  const existing = createSubscription();
  const harness = createPushHarness({
    permission: "granted",
    existingSubscription: existing.subscription,
    unregisterSubscription: async () => {
      throw new Error("backend indisponível");
    },
  });

  await harness.client.activateSession("agency-4:opaque-session");
  const state = await harness.client.disable();

  assert.equal(existing.unsubscribeCalls(), 0);
  assert.equal(state.phase, PUSH_STATES.ERROR);
  assert.equal(state.subscribed, true);
  assert.match(state.error, /backend indisponível/i);
});

test("permissão negada não cria assinatura nem envia dados ao backend", async () => {
  const harness = createPushHarness({ requestPermissionResult: "denied" });

  await harness.client.activateSession("agency-5:opaque-session");
  const state = await harness.client.enable();

  assert.equal(state.phase, PUSH_STATES.DENIED);
  assert.equal(state.subscribed, false);
  assert.equal(harness.calls.subscribe.length, 0);
  assert.equal(harness.calls.registerSubscription.length, 0);
});
