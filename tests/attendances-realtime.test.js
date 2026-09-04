"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const source = readFileSync(require.resolve("../attendances.js"), "utf8");

const STORE_A = "00000000-0000-4000-8000-00000000000a";
const STORE_B = "00000000-0000-4000-8000-00000000000b";
const DEBOUNCE_MS = 40;
const RETRY_BASE_MS = 100;

function loadHooks() {
  const hooks = {};
  const window = { __ATTENDANCES_TEST_HOOKS__: hooks };
  vm.runInNewContext(source, { window }, { filename: "attendances.js" });
  return hooks;
}

class FakeClock {
  constructor() {
    this.now = 0;
    this.nextId = 1;
    this.tasks = new Map();
  }

  setTimeout = (callback, delay = 0) => {
    const id = this.nextId;
    this.nextId += 1;
    this.tasks.set(id, {
      callback,
      dueAt: this.now + Math.max(Number(delay) || 0, 0),
    });
    return id;
  };

  clearTimeout = (id) => {
    this.tasks.delete(id);
  };

  tick(milliseconds) {
    const target = this.now + Math.max(Number(milliseconds) || 0, 0);
    while (true) {
      const next = [...this.tasks.entries()]
        .filter(([, task]) => task.dueAt <= target)
        .sort((left, right) => left[1].dueAt - right[1].dueAt || left[0] - right[0])[0];
      if (!next) break;
      const [id, task] = next;
      this.tasks.delete(id);
      this.now = task.dueAt;
      task.callback();
    }
    this.now = target;
  }

  get pendingCount() {
    return this.tasks.size;
  }
}

function createFakeRoot(ElementConstructor = class {}) {
  return Object.assign(new ElementConstructor(), {
    innerHTML: "",
    __attendanceHandlersBound: false,
    classList: {
      add() {},
    },
    setAttribute() {},
    addEventListener() {},
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
    replaceChildren() {
      this.innerHTML = "";
    },
  });
}

function loadModuleRuntime(clock = new FakeClock()) {
  const hooks = {};
  class Element {}
  const document = {
    visibilityState: "visible",
    addEventListener() {},
    removeEventListener() {},
    querySelector() {
      return null;
    },
  };
  let intervalId = 0;
  const window = {
    __ATTENDANCES_TEST_HOOKS__: hooks,
    document,
    navigator: {},
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    setInterval() {
      intervalId += 1;
      return intervalId;
    },
    clearInterval() {},
    addEventListener() {},
    removeEventListener() {},
    requestAnimationFrame(callback) {
      callback();
      return 1;
    },
  };
  vm.runInNewContext(source, {
    window,
    document,
    console,
    requestAnimationFrame: window.requestAnimationFrame,
    cancelAnimationFrame() {},
    queueMicrotask,
    Element,
  }, { filename: "attendances.js" });
  return { clock, hooks, module: window.AttendancesModule, Element };
}

function store(id, name) {
  return {
    id,
    name,
    attendanceEnabled: true,
    goodMorningSellerEnabled: false,
  };
}

function runtimeRpcCalls() {
  const calls = [];
  const rpc = async (name, args = {}) => {
    calls.push({ name, args });
    if (name.includes("workspace")) {
      return {
        store_id: args.p_store_id,
        attendances: [],
        professionals: [],
        metrics: {},
      };
    }
    if (name.includes("list_attendances")) {
      return {
        store_id: args.p_store_id,
        items: [],
        total: 0,
        has_more: false,
      };
    }
    return {};
  };
  return { calls, rpc };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function settle() {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((resolve) => setImmediate(resolve));
}

function event(storeId, resource, extra = {}) {
  return { storeId, resource, ...extra };
}

function createHarness(overrides = {}) {
  const hooks = loadHooks();
  assert.equal(
    typeof hooks.createAttendanceRealtimeCoordinator,
    "function",
    "attendances.js deve expor createAttendanceRealtimeCoordinator apenas pelos test hooks",
  );

  const clock = new FakeClock();
  const subscriptions = [];
  const workspaceCalls = [];
  const morningCalls = [];
  const notifications = [];
  let busy = false;

  const subscribe = (options) => {
    const subscription = {
      options,
      cleanupCalls: 0,
    };
    subscriptions.push(subscription);
    return () => {
      subscription.cleanupCalls += 1;
    };
  };

  const refreshWorkspace = async (context) => {
    workspaceCalls.push(context);
  };
  const refreshMorning = async (context) => {
    morningCalls.push(context);
  };

  const dependencies = {
    subscribe,
    attendanceRealtime: { subscribe },
    refreshWorkspace,
    refreshMorning,
    isBusy: () => busy,
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    debounceMs: DEBOUNCE_MS,
    retryBaseMs: RETRY_BASE_MS,
    retryMaxMs: RETRY_BASE_MS * 4,
    notify: (...args) => notifications.push(args),
    ...overrides,
  };

  const coordinator = hooks.createAttendanceRealtimeCoordinator(dependencies);
  assert.equal(typeof coordinator?.start, "function", "o coordenador deve expor start(storeId)");
  assert.equal(typeof coordinator?.stop, "function", "o coordenador deve expor stop()");
  assert.equal(typeof coordinator?.flush, "function", "o coordenador deve expor flush() para o finally dos saves");

  return {
    clock,
    coordinator,
    subscriptions,
    workspaceCalls,
    morningCalls,
    notifications,
    setBusy(value) {
      busy = value === true;
    },
    latestSubscription() {
      return subscriptions.at(-1);
    },
    emit(payload, subscription = subscriptions.at(-1)) {
      assert.equal(typeof subscription?.options?.onEvent, "function");
      subscription.options.onEvent(payload);
    },
    status(value, error, subscription = subscriptions.at(-1)) {
      assert.equal(typeof subscription?.options?.onStatus, "function");
      subscription.options.onStatus(value, error);
    },
  };
}

async function start(harness, storeId) {
  await harness.coordinator.start(storeId);
  await settle();
}

async function advance(harness, milliseconds = DEBOUNCE_MS) {
  harness.clock.tick(milliseconds);
  await settle();
}

test("expõe uma factory isolada em vez do estado interno do módulo", () => {
  const hooks = loadHooks();
  assert.equal(typeof hooks.createAttendanceRealtimeCoordinator, "function");
  assert.equal("attendanceRealtimeState" in hooks, false);
});

test("activate, refreshContext, deactivate e resetSession usam o lifecycle do coordenador real", async () => {
  const runtime = loadModuleRuntime();
  const root = createFakeRoot(runtime.Element);
  const { rpc } = runtimeRpcCalls();
  const subscriptions = [];
  const attendanceRealtime = {
    subscribe(options) {
      const subscription = { options, cleanupCalls: 0 };
      subscriptions.push(subscription);
      return () => {
        subscription.cleanupCalls += 1;
      };
    },
  };
  const commonBridge = {
    root,
    profile: { role: "admin", id: "admin-1" },
    stores: [store(STORE_A, "Loja A"), store(STORE_B, "Loja B")],
    initialStoreId: STORE_A,
    attendanceAccessGranted: true,
    rpc,
    attendanceRealtime,
  };

  await runtime.module.activate(commonBridge);
  await settle();
  assert.equal(subscriptions.length, 1);
  assert.equal(subscriptions[0].options.storeId, STORE_A);

  await runtime.module.refreshContext({
    stores: [store(STORE_B, "Loja B")],
    initialStoreId: STORE_B,
  });
  await settle();
  assert.equal(subscriptions[0].cleanupCalls, 1);
  assert.equal(subscriptions.length, 2);
  assert.equal(subscriptions[1].options.storeId, STORE_B);

  runtime.module.deactivate();
  await settle();
  assert.equal(subscriptions[1].cleanupCalls, 1);

  await runtime.module.activate({
    ...commonBridge,
    stores: [store(STORE_A, "Loja A")],
    initialStoreId: STORE_A,
  });
  await settle();
  assert.equal(subscriptions.length, 3);
  runtime.module.resetSession();
  await settle();
  assert.equal(subscriptions[2].cleanupCalls, 1);
});

test("trocar a implementação do bridge limpa a anterior mesmo mantendo a loja", async () => {
  const runtime = loadModuleRuntime();
  const root = createFakeRoot(runtime.Element);
  const { rpc } = runtimeRpcCalls();
  let cleanupA = 0;
  let cleanupB = 0;
  const bridgeA = {
    subscribe() {
      return () => {
        cleanupA += 1;
      };
    },
  };
  const bridgeB = {
    subscribe() {
      return () => {
        cleanupB += 1;
      };
    },
  };

  await runtime.module.activate({
    root,
    profile: { role: "admin", id: "admin-1" },
    stores: [store(STORE_A, "Loja A")],
    initialStoreId: STORE_A,
    attendanceAccessGranted: true,
    rpc,
    attendanceRealtime: bridgeA,
  });
  await settle();
  await runtime.module.refreshContext({ attendanceRealtime: bridgeB }, { reload: false });
  await settle();
  assert.equal(cleanupA, 1);
  assert.equal(cleanupB, 0);

  runtime.module.resetSession();
  await settle();
  assert.equal(cleanupB, 1);
});

test("delega ao adaptador somente a loja e os callbacks, sem construir tópico previsível", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);

  assert.equal(harness.subscriptions.length, 1);
  const options = harness.latestSubscription().options;
  assert.equal(options.storeId, STORE_A);
  assert.equal(typeof options.onEvent, "function");
  assert.equal(typeof options.onStatus, "function");
  assert.deepEqual(
    Object.keys(options).sort(),
    ["onEvent", "onStatus", "storeId"],
    "topic/event/private pertencem ao adaptador que busca a capability autenticada",
  );

  await start(harness, STORE_A);
  assert.equal(harness.subscriptions.length, 1, "refreshContext da mesma loja não pode duplicar canais");
});

for (const [resource, expectedScope] of [
  ["attendance", "workspace"],
  ["professional", "workspace"],
  ["settings", "morning"],
  ["allocation", "morning"],
  ["closed-day", "morning"],
]) {
  test(`evento ${resource} atualiza somente o escopo ${expectedScope}`, async () => {
    const harness = createHarness();
    await start(harness, STORE_A);

    harness.emit(event(STORE_A, resource));
    await advance(harness, DEBOUNCE_MS - 1);
    assert.equal(harness.workspaceCalls.length, 0);
    assert.equal(harness.morningCalls.length, 0);

    await advance(harness, 1);
    assert.equal(harness.workspaceCalls.length, expectedScope === "workspace" ? 1 : 0);
    assert.equal(harness.morningCalls.length, expectedScope === "morning" ? 1 : 0);
    const context = (harness.workspaceCalls[0] || harness.morningCalls[0]);
    assert.equal(context?.storeId, STORE_A);
  });
}

test("coalesce uma rajada mista e o workspace domina o refresh parcial", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);

  for (let index = 0; index < 20; index += 1) {
    harness.emit(event(STORE_A, index % 4 === 0 ? "attendance" : "allocation"));
  }
  harness.emit(event(STORE_A, "settings"));
  harness.emit(event(STORE_A, "closed-day"));
  harness.emit(event(STORE_A, "professional"));

  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 1);
  assert.equal(harness.morningCalls.length, 0);
  assert.equal(harness.workspaceCalls[0]?.storeId, STORE_A);
});

test("serializa refreshes e executa no máximo um trailing refresh", async () => {
  const firstRefresh = deferred();
  let activeRefreshes = 0;
  let maximumConcurrentRefreshes = 0;
  const workspaceCalls = [];
  const refreshWorkspace = async (context) => {
    workspaceCalls.push(context);
    activeRefreshes += 1;
    maximumConcurrentRefreshes = Math.max(maximumConcurrentRefreshes, activeRefreshes);
    if (workspaceCalls.length === 1) await firstRefresh.promise;
    activeRefreshes -= 1;
  };
  const harness = createHarness({ refreshWorkspace });
  await start(harness, STORE_A);

  harness.emit(event(STORE_A, "attendance"));
  await advance(harness);
  assert.equal(workspaceCalls.length, 1);

  for (let index = 0; index < 8; index += 1) {
    harness.emit(event(STORE_A, "attendance"));
  }
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(workspaceCalls.length, 1, "não deve iniciar um segundo RPC enquanto o primeiro está em voo");

  firstRefresh.resolve();
  await settle();
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(workspaceCalls.length, 2);
  assert.equal(maximumConcurrentRefreshes, 1);
});

test("troca de loja limpa o canal e timers antigos antes de aceitar B", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  const subscriptionA = harness.latestSubscription();

  harness.emit(event(STORE_A, "attendance"), subscriptionA);
  assert.equal(harness.clock.pendingCount, 1);
  await start(harness, STORE_B);
  const subscriptionB = harness.latestSubscription();

  assert.equal(subscriptionA.cleanupCalls, 1);
  assert.equal(harness.subscriptions.length, 2);
  assert.equal(subscriptionB.options.storeId, STORE_B);
  assert.equal(harness.clock.pendingCount, 0, "timer de A deve ser cancelado na troca");

  harness.emit(event(STORE_A, "attendance"), subscriptionA);
  harness.status("CHANNEL_ERROR", new Error("canal antigo"), subscriptionA);
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(harness.workspaceCalls.length, 0);
  assert.equal(harness.notifications.length, 0);

  harness.emit(event(STORE_B, "attendance"), subscriptionB);
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 1);
  assert.equal(harness.workspaceCalls[0]?.storeId, STORE_B);
});

test("stop/logout remove canal, timer e dirty state e bloqueiam callbacks tardios", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  const subscription = harness.latestSubscription();
  harness.emit(event(STORE_A, "attendance"), subscription);
  assert.equal(harness.clock.pendingCount, 1);

  await harness.coordinator.stop();
  await settle();
  assert.equal(subscription.cleanupCalls, 1);
  assert.equal(harness.clock.pendingCount, 0);

  harness.emit(event(STORE_A, "attendance"), subscription);
  harness.status("SUBSCRIBED", undefined, subscription);
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(harness.workspaceCalls.length, 0);
  assert.equal(harness.morningCalls.length, 0);

  await harness.coordinator.flush();
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 0);
});

test("store vazio equivale a unsubscribe e não abre canal sem escopo", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  const subscription = harness.latestSubscription();

  await start(harness, "");
  assert.equal(subscription.cleanupCalls, 1);
  assert.equal(harness.subscriptions.length, 1);

  harness.emit(event(STORE_A, "attendance"), subscription);
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 0);
});

test("cleanup de subscribe assíncrono é executado se resolver depois do stop", async () => {
  const pendingSubscription = deferred();
  const subscribeCalls = [];
  let cleanupCalls = 0;
  const subscribe = (options) => {
    subscribeCalls.push(options);
    return pendingSubscription.promise;
  };
  const harness = createHarness({
    subscribe,
    attendanceRealtime: { subscribe },
  });

  const startPromise = Promise.resolve(harness.coordinator.start(STORE_A));
  await settle();
  assert.equal(subscribeCalls.length, 1);
  const stopPromise = Promise.resolve(harness.coordinator.stop());
  await settle();

  pendingSubscription.resolve(() => {
    cleanupCalls += 1;
  });
  await Promise.all([startPromise, stopPromise]);
  await settle();
  assert.equal(cleanupCalls, 1, "a inscrição que chegou tarde não pode vazar após logout/deactivate");

  subscribeCalls[0].onEvent(event(STORE_A, "attendance"));
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 0);
});

test("resolução tardia da inscrição A é descartada sem remover a inscrição B", async () => {
  const pendingA = deferred();
  const subscribeCalls = [];
  let cleanupA = 0;
  let cleanupB = 0;
  const subscribe = (options) => {
    subscribeCalls.push(options);
    if (options.storeId === STORE_A) return pendingA.promise;
    return () => {
      cleanupB += 1;
    };
  };
  const harness = createHarness({
    subscribe,
    attendanceRealtime: { subscribe },
  });

  const startA = Promise.resolve(harness.coordinator.start(STORE_A));
  await settle();
  const startB = Promise.resolve(harness.coordinator.start(STORE_B));
  await settle();
  assert.deepEqual(subscribeCalls.map((call) => call.storeId), [STORE_A, STORE_B]);

  pendingA.resolve(() => {
    cleanupA += 1;
  });
  await Promise.all([startA, startB]);
  await settle();
  assert.equal(cleanupA, 1);
  assert.equal(cleanupB, 0);

  subscribeCalls[0].onEvent(event(STORE_A, "attendance"));
  subscribeCalls[1].onEvent(event(STORE_B, "attendance"));
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 1);
  assert.equal(harness.workspaceCalls[0]?.storeId, STORE_B);

  await harness.coordinator.stop();
  assert.equal(cleanupB, 1);
});

test("ignora payload cruzado e sem loja; recurso desconhecido usa refresh completo seguro", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);

  harness.emit(event(STORE_B, "attendance"));
  harness.emit({ resource: "attendance" });
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(harness.workspaceCalls.length, 0);
  assert.equal(harness.morningCalls.length, 0);

  harness.emit(event(STORE_A, "unknown-resource"));
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 1);
});

test("aceita envelope do Broadcast e aliases snake_case sem perder o escopo", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);

  harness.emit({
    event: "invalidate",
    payload: {
      store_id: STORE_A,
      resource: "allocation",
    },
  });
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 0);
  assert.equal(harness.morningCalls.length, 1);
  assert.equal(harness.morningCalls[0]?.storeId, STORE_A);
});

for (const resource of ["attendance", "settings", "professional", "closed-day"]) {
  test(`preserva evento ${resource} recebido durante save e drena uma vez no finally`, async () => {
    const harness = createHarness();
    await start(harness, STORE_A);
    harness.setBusy(true);

    for (let index = 0; index < 5; index += 1) {
      harness.emit(event(STORE_A, resource));
    }
    await advance(harness, DEBOUNCE_MS * 3);
    assert.equal(harness.workspaceCalls.length, 0);
    assert.equal(harness.morningCalls.length, 0);

    harness.setBusy(false);
    await harness.coordinator.flush();
    await advance(harness);
    const totalRefreshes = harness.workspaceCalls.length + harness.morningCalls.length;
    assert.equal(totalRefreshes, 1, "sucesso ou erro do save devem usar o mesmo flush no finally");
  });
}

test("troca/logout durante save descarta o dirty state da loja anterior", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  harness.setBusy(true);
  harness.emit(event(STORE_A, "attendance"));
  await advance(harness, DEBOUNCE_MS * 2);

  await start(harness, STORE_B);
  harness.setBusy(false);
  await harness.coordinator.flush();
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 0);
  assert.equal(harness.morningCalls.length, 0);
});

test("reconecta sem duplicar canal, notifica uma vez e faz catch-up autoritativo", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  harness.status("SUBSCRIBED");
  await advance(harness);
  assert.equal(
    harness.workspaceCalls.length,
    1,
    "o primeiro join também reconcilia a janela entre a carga inicial e a confirmação da assinatura",
  );
  harness.status("SUBSCRIBED");
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(harness.workspaceCalls.length, 1, "SUBSCRIBED repetido sem falha não duplica o catch-up");

  harness.status("CHANNEL_ERROR", new Error("socket caiu"));
  harness.status("CHANNEL_ERROR", new Error("socket ainda indisponível"));
  harness.status("TIMED_OUT", new Error("timeout"));
  assert.equal(harness.subscriptions.length, 1, "o SDK deve reconectar o mesmo canal; não criar retry paralelo");
  assert.equal(harness.notifications.length, 1, "uma indisponibilidade não deve gerar spam visual");

  harness.status("SUBSCRIBED");
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 2);
  assert.equal(harness.workspaceCalls.at(-1)?.storeId, STORE_A);

  harness.status("SUBSCRIBED");
  await advance(harness, DEBOUNCE_MS * 2);
  assert.equal(harness.workspaceCalls.length, 2);
});

test("CLOSED após cleanup intencional não alerta nem tenta ressuscitar o canal", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  const subscription = harness.latestSubscription();
  harness.status("SUBSCRIBED", undefined, subscription);
  await advance(harness);

  await harness.coordinator.stop();
  harness.status("CLOSED", undefined, subscription);
  await advance(harness, DEBOUNCE_MS * 2);

  assert.equal(harness.subscriptions.length, 1);
  assert.equal(subscription.cleanupCalls, 1);
  assert.equal(harness.notifications.length, 0);
});

test("falha síncrona ao assinar degrada sem impedir a tela e sem retry agressivo", async () => {
  const notifications = [];
  const subscribe = () => {
    throw new Error("Realtime indisponível");
  };
  const harness = createHarness({
    subscribe,
    attendanceRealtime: { subscribe },
    notify: (...args) => notifications.push(args),
  });

  await assert.doesNotReject(() => harness.coordinator.start(STORE_A));
  assert.equal(notifications.length, 1);
  assert.equal(harness.workspaceCalls.length, 0);
  assert.equal(harness.morningCalls.length, 0);
});

test("falha de refresh retém a invalidação sem criar loop de RPC a cada debounce", async () => {
  let shouldFail = true;
  let refreshCalls = 0;
  const notifications = [];
  const refreshWorkspace = async () => {
    refreshCalls += 1;
    if (shouldFail) throw new Error("RPC temporariamente indisponível");
  };
  const harness = createHarness({
    refreshWorkspace,
    notify: (...args) => notifications.push(args),
  });
  await start(harness, STORE_A);

  harness.emit(event(STORE_A, "attendance"));
  await advance(harness);
  assert.equal(refreshCalls, 1);
  assert.equal(notifications.length, 1);

  await advance(harness, DEBOUNCE_MS * 10);
  assert.equal(refreshCalls, 1, "uma indisponibilidade longa não pode gerar polling de 260 ms sem backoff");
  assert.equal(notifications.length, 1);

  shouldFail = false;
  await harness.coordinator.flush();
  await settle();
  assert.equal(refreshCalls, 2, "flush manual/reconnect deve reconciliar a invalidação retida");
});

test("rejeição de cleanup é absorvida e callbacks continuam invalidados", async () => {
  const cleanupFailure = new Error("falha ao remover canal");
  let options;
  const subscribe = (nextOptions) => {
    options = nextOptions;
    return async () => {
      throw cleanupFailure;
    };
  };
  const harness = createHarness({
    subscribe,
    attendanceRealtime: { subscribe },
  });
  await start(harness, STORE_A);

  await assert.doesNotReject(() => Promise.resolve(harness.coordinator.stop()));
  options.onEvent(event(STORE_A, "attendance"));
  await advance(harness);
  assert.equal(harness.workspaceCalls.length, 0);
});

test("falha tardia do refresh A não prende a invalidação pendente da loja B", async () => {
  const refreshA = deferred();
  const refreshCalls = [];
  const harness = createHarness({
    refreshWorkspace: async (context) => {
      refreshCalls.push(context);
      if (context.storeId === STORE_A) await refreshA.promise;
    },
  });
  await start(harness, STORE_A);
  const subscriptionA = harness.latestSubscription();
  harness.emit(event(STORE_A, "attendance"), subscriptionA);
  await advance(harness);
  assert.deepEqual(refreshCalls.map((call) => call.storeId), [STORE_A]);

  await start(harness, STORE_B);
  const subscriptionB = harness.latestSubscription();
  harness.emit(event(STORE_B, "attendance"), subscriptionB);
  await advance(harness);
  assert.deepEqual(refreshCalls.map((call) => call.storeId), [STORE_A]);

  refreshA.reject(new Error("A falhou depois da troca"));
  await settle();
  await advance(harness);
  assert.deepEqual(
    refreshCalls.map((call) => call.storeId),
    [STORE_A, STORE_B],
    "o finally de A deve reagendar o dirty state que pertence a B",
  );
});

test("CLOSED inesperado recria capability/canal uma vez após backoff", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  const firstSubscription = harness.latestSubscription();
  harness.status("SUBSCRIBED", undefined, firstSubscription);
  await advance(harness);

  harness.status("CLOSED", new Error("socket encerrado"), firstSubscription);
  harness.status("CLOSED", new Error("callback repetido"), firstSubscription);
  assert.equal(harness.notifications.length, 1);
  assert.equal(harness.subscriptions.length, 1);
  assert.equal(harness.clock.pendingCount, 1);

  await advance(harness, RETRY_BASE_MS - 1);
  assert.equal(harness.subscriptions.length, 1);
  await advance(harness, 1);
  assert.equal(harness.subscriptions.length, 2);
  assert.equal(firstSubscription.cleanupCalls, 1);
  assert.equal(harness.latestSubscription().options.storeId, STORE_A);
});

test("falha ao recriar após CLOSED usa backoff exponencial limitado, sem loop", async () => {
  let attempts = 0;
  let initialOptions;
  const subscribe = (options) => {
    attempts += 1;
    if (attempts === 1) initialOptions = options;
    if (attempts === 2) throw new Error("capability temporariamente indisponível");
    return () => {};
  };
  const harness = createHarness({
    subscribe,
    attendanceRealtime: { subscribe },
  });
  await start(harness, STORE_A);
  initialOptions.onStatus("SUBSCRIBED");
  await advance(harness);
  initialOptions.onStatus("CLOSED", new Error("fechado"));

  await advance(harness, RETRY_BASE_MS);
  assert.equal(attempts, 2);
  assert.equal(harness.clock.pendingCount, 1, "uma única nova tentativa deve ficar agendada");
  await advance(harness, (RETRY_BASE_MS * 2) - 1);
  assert.equal(attempts, 2);
  await advance(harness, 1);
  assert.equal(attempts, 3);
  assert.equal(harness.notifications.length, 1, "falhas do mesmo ciclo não devem gerar spam");
});

test("stop durante o backoff de CLOSED cancela retry e impede ressurreição", async () => {
  const harness = createHarness();
  await start(harness, STORE_A);
  const subscription = harness.latestSubscription();
  harness.status("SUBSCRIBED", undefined, subscription);
  await advance(harness);
  harness.status("CLOSED", new Error("fechado"), subscription);
  assert.equal(harness.clock.pendingCount, 1);

  await harness.coordinator.stop();
  assert.equal(harness.clock.pendingCount, 0);
  assert.equal(subscription.cleanupCalls, 1);
  await advance(harness, RETRY_BASE_MS * 8);
  assert.equal(harness.subscriptions.length, 1);
});
