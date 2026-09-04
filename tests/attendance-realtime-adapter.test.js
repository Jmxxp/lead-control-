"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const appSource = readFileSync(require.resolve("../app.js"), "utf8");
const adapterStart = appSource.indexOf("async function subscribeAttendanceRealtime");
const adapterEnd = appSource.indexOf("\nfunction assertLegacyModuleSelection", adapterStart);
assert.ok(adapterStart >= 0 && adapterEnd > adapterStart, "adapter Realtime deve permanecer isolável para teste");
const adapterSource = appSource.slice(adapterStart, adapterEnd);

const STORE_ID = "00000000-0000-4000-8000-00000000000a";
const TOPIC = `lc:attendance:${"a".repeat(64)}`;

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function createAdapterHarness(overrides = {}, behavior = {}) {
  const capability = {
    transport: "broadcast",
    store_id: STORE_ID,
    topic: TOPIC,
    event: "invalidate",
    private: true,
    payload_version: 1,
    expires_at: new Date(Date.now() + 60000).toISOString(),
    ...overrides,
  };
  const rpcCalls = [];
  const channelCalls = [];
  const removeCalls = [];
  const realtimeChannels = [];
  let realtimeAuthCalls = 0;
  const unregister = (channel) => {
    for (let index = realtimeChannels.length - 1; index >= 0; index -= 1) {
      if (realtimeChannels[index].topic === channel.topic) realtimeChannels.splice(index, 1);
    }
  };
  const closeChannel = (channel, error) => {
    unregister(channel);
    channel.__statusHandler?.("CLOSED", error);
  };
  const createChannel = (topic, options) => {
    const channel = {
      topic: `realtime:${topic}`,
      joinedOnce: false,
      __broadcastHandler: null,
      __statusHandler: null,
      on(type, filter, handler) {
        assert.equal(type, "broadcast");
        assert.equal(filter?.event, "invalidate");
        this.__broadcastHandler = handler;
        return this;
      },
      subscribe(handler) {
        if (this.joinedOnce) return this;
        this.joinedOnce = true;
        this.__statusHandler = handler;
        return this;
      },
    };
    channelCalls.push({ topic, options, channel });
    realtimeChannels.push(channel);
    return channel;
  };
  const context = {
    ATTENDANCE_REALTIME_SUBSCRIPTION_RPC: "lc_get_attendance_realtime_subscription_v1",
    attendanceRealtimeChannels: new Map(),
    currentProfile: { sessionToken: "opaque-session" },
    firstRow: (value) => value,
    authenticatedRpc: async (name, args) => {
      rpcCalls.push({ name, args });
      return capability;
    },
    supabaseClient: {
      realtime: {
        async setAuth() {
          realtimeAuthCalls += 1;
        },
      },
      channel(topic, options) {
        return realtimeChannels.find((channel) => channel.topic === `realtime:${topic}`)
          || createChannel(topic, options);
      },
      getChannels() {
        return realtimeChannels.slice();
      },
      async removeChannel(channel) {
        removeCalls.push(channel);
        if (typeof behavior.removeChannel === "function") {
          return behavior.removeChannel({ channel, close: () => closeChannel(channel), unregister });
        }
        closeChannel(channel);
        return "ok";
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(`${adapterSource}\nglobalThis.adapter = subscribeAttendanceRealtime;\nglobalThis.clearChannels = clearAttendanceRealtimeChannels;`, context);
  return {
    adapter: context.adapter,
    clearChannels: context.clearChannels,
    rpcCalls,
    channelCalls,
    removeCalls,
    realtimeAuthCalls: () => realtimeAuthCalls,
    realtimeChannels,
    emit(payload, channel = channelCalls.at(-1)?.channel) {
      channel?.__broadcastHandler?.({ payload });
    },
    status(value, error, channel = channelCalls.at(-1)?.channel) {
      if (value === "CLOSED") unregister(channel);
      channel?.__statusHandler?.(value, error);
    },
  };
}

test("adapter exige capability autenticada completa e abre somente Broadcast privado", async () => {
  const harness = createAdapterHarness();
  const events = [];
  const statuses = [];
  const cleanup = await harness.adapter({
    storeId: STORE_ID,
    onEvent: (payload) => events.push(payload),
    onStatus: (status) => statuses.push(status),
  });

  assert.equal(harness.rpcCalls.length, 1);
  assert.equal(harness.rpcCalls[0].name, "lc_get_attendance_realtime_subscription_v1");
  assert.equal(harness.rpcCalls[0].args.p_store_id, STORE_ID);
  assert.equal(harness.channelCalls.length, 1);
  assert.equal(harness.realtimeAuthCalls(), 1);
  assert.equal(harness.channelCalls[0].topic, TOPIC);
  assert.equal(harness.channelCalls[0].options.config.private, true);

  harness.emit({ scope: "attendance" });
  harness.status("SUBSCRIBED");
  assert.equal(JSON.stringify(events), JSON.stringify([{ scope: "attendance", storeId: STORE_ID }]));
  assert.deepEqual(statuses, ["SUBSCRIBED"]);

  await cleanup();
  await cleanup();
  assert.equal(harness.removeCalls.length, 1);
});

test("adapter multiplexa consumidores do mesmo tópico e remove o canal somente no último cleanup", async () => {
  const harness = createAdapterHarness();
  const firstEvents = [];
  const secondEvents = [];
  const secondStatuses = [];
  const cleanupFirst = await harness.adapter({
    storeId: STORE_ID,
    onEvent: (payload) => firstEvents.push(payload),
  });
  harness.status("SUBSCRIBED");
  const cleanupSecond = await harness.adapter({
    storeId: STORE_ID,
    onEvent: (payload) => secondEvents.push(payload),
    onStatus: (status) => secondStatuses.push(status),
  });

  assert.equal(harness.channelCalls.length, 1);
  assert.equal(harness.rpcCalls.length, 2);
  assert.equal(harness.realtimeAuthCalls(), 2);
  assert.deepEqual(secondStatuses, ["SUBSCRIBED"]);

  harness.emit({ resources: ["attendance"], version: 1 });
  assert.equal(firstEvents.length, 1);
  assert.equal(secondEvents.length, 1);

  await cleanupFirst();
  assert.equal(harness.removeCalls.length, 0);
  harness.emit({ resources: ["morning"], version: 1 });
  assert.equal(firstEvents.length, 1);
  assert.equal(secondEvents.length, 2);

  await cleanupSecond();
  await cleanupSecond();
  assert.equal(harness.removeCalls.length, 1);
});

test("limpeza global encerra todos os canais compartilhados no logout", async () => {
  const harness = createAdapterHarness();
  const cleanup = await harness.adapter({ storeId: STORE_ID });

  await harness.clearChannels();
  await cleanup();

  assert.equal(harness.removeCalls.length, 1);
});

test("CLOSED invalida o canal compartilhado e permite criar outro sem prender os consumidores", async () => {
  const harness = createAdapterHarness();
  const firstStatuses = [];
  const secondStatuses = [];
  const cleanupFirst = await harness.adapter({
    storeId: STORE_ID,
    onStatus: (status) => firstStatuses.push(status),
  });
  const cleanupSecond = await harness.adapter({
    storeId: STORE_ID,
    onStatus: (status) => secondStatuses.push(status),
  });

  harness.status("SUBSCRIBED");
  harness.status("CLOSED");
  await Promise.resolve();
  assert.deepEqual(firstStatuses, ["SUBSCRIBED", "CLOSED"]);
  assert.deepEqual(secondStatuses, ["SUBSCRIBED", "CLOSED"]);
  assert.equal(harness.removeCalls.length, 0);

  await cleanupFirst();
  await cleanupSecond();
  const replacementStatusesA = [];
  const replacementStatusesB = [];
  const [cleanupReplacementA, cleanupReplacementB] = await Promise.all([
    harness.adapter({
      storeId: STORE_ID,
      onStatus: (status) => replacementStatusesA.push(status),
    }),
    harness.adapter({
      storeId: STORE_ID,
      onStatus: (status) => replacementStatusesB.push(status),
    }),
  ]);
  assert.equal(harness.channelCalls.length, 2);
  assert.deepEqual(replacementStatusesA, []);
  assert.deepEqual(replacementStatusesB, []);

  harness.status("SUBSCRIBED");
  assert.deepEqual(replacementStatusesA, ["SUBSCRIBED"]);
  assert.deepEqual(replacementStatusesB, ["SUBSCRIBED"]);

  await cleanupReplacementA();
  await cleanupReplacementB();
  assert.equal(harness.removeCalls.length, 1);
});

test("nova inscrição aguarda o teardown anterior e nunca reutiliza o canal enquanto fecha", async () => {
  const removal = deferred();
  const harness = createAdapterHarness({}, {
    async removeChannel({ close }) {
      const result = await removal.promise;
      if (result !== "error") close();
      return result;
    },
  });
  const cleanupFirst = await harness.adapter({ storeId: STORE_ID });
  const firstChannel = harness.channelCalls[0].channel;
  const closing = cleanupFirst();
  const replacement = harness.adapter({ storeId: STORE_ID });

  await Promise.resolve();
  await Promise.resolve();
  assert.equal(harness.channelCalls.length, 1);
  assert.equal(harness.realtimeChannels[0], firstChannel);

  removal.resolve("ok");
  await closing;
  const cleanupReplacement = await replacement;
  assert.equal(harness.channelCalls.length, 2);
  assert.notEqual(harness.channelCalls[1].channel, firstChannel);

  await cleanupReplacement();
});

test("falha de removeChannel mantém tombstone e a aquisição seguinte refaz o teardown", async () => {
  let removalAttempt = 0;
  const harness = createAdapterHarness({}, {
    async removeChannel({ close }) {
      removalAttempt += 1;
      if (removalAttempt === 1) return "error";
      close();
      return "ok";
    },
  });
  const cleanupFirst = await harness.adapter({ storeId: STORE_ID });

  await assert.rejects(
    () => cleanupFirst(),
    /não confirmou o encerramento do canal Realtime/,
  );
  assert.equal(harness.channelCalls.length, 1);
  assert.equal(harness.realtimeChannels.length, 1);

  const cleanupReplacement = await harness.adapter({ storeId: STORE_ID });
  assert.equal(removalAttempt, 2);
  assert.equal(harness.channelCalls.length, 2);
  assert.equal(harness.realtimeChannels.length, 1);

  await cleanupReplacement();
  assert.equal(removalAttempt, 3);
});

for (const [label, override] of [
  ["transport", { transport: "postgres_changes" }],
  ["store_id ausente", { store_id: undefined }],
  ["store_id cruzado", { store_id: "00000000-0000-4000-8000-00000000000b" }],
  ["topic previsível", { topic: `store:${STORE_ID}:attendances` }],
  ["event", { event: "changed" }],
  ["private", { private: false }],
  ["payload_version", { payload_version: 2 }],
  ["expires_at inválido", { expires_at: "amanhã" }],
  ["expires_at vencido", { expires_at: new Date(Date.now() - 60000).toISOString() }],
]) {
  test(`adapter rejeita capability com ${label} inválido antes de abrir canal`, async () => {
    const harness = createAdapterHarness(override);
    await assert.rejects(
      () => harness.adapter({ storeId: STORE_ID }),
      /capability de Realtime inválida/,
    );
    assert.equal(harness.channelCalls.length, 0);
  });
}
