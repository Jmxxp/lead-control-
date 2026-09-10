"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  focusOrOpenClient,
  parsePushPayload,
  safeUrl,
} = require("../service-worker.js");

const CONTEXT = {
  origin: "https://app.example.test",
  scopeUrl: "https://app.example.test/lead-control/",
};
const FALLBACK_URL = "https://app.example.test/lead-control/";

test("URL de clique aceita somente a mesma origem dentro do escopo do app", () => {
  assert.equal(
    safeUrl("./?daily_report=2026-09-09", CONTEXT),
    "https://app.example.test/lead-control/?daily_report=2026-09-09",
  );
  assert.equal(safeUrl("https://evil.example/phishing", CONTEXT), FALLBACK_URL);
  assert.equal(safeUrl("https://app.example.test/admin", CONTEXT), FALLBACK_URL);
  assert.equal(safeUrl("/lead-control-falso/", CONTEXT), FALLBACK_URL);
  assert.equal(safeUrl("http://[::1", CONTEXT), FALLBACK_URL);
});

test("payload vazio ou inválido sempre produz notificação visível e segura", () => {
  const empty = parsePushPayload("{inválido", CONTEXT);

  assert.equal(empty.title, "Controle de Leads");
  assert.equal(empty.options.body, "Seu relatório diário está pronto.");
  assert.equal(empty.options.icon, "./assets/app-icon-192.png");
  assert.equal(empty.options.badge, "./assets/favicon-32.png");
  assert.equal(empty.options.tag, "daily-report");
  assert.equal(empty.options.requireInteraction, false);
  assert.deepEqual(empty.options.data, {
    url: FALLBACK_URL,
    reportDate: "",
    storeId: "",
  });
});

test("payload aninhado preserva conteúdo permitido, limita textos e bloqueia redirecionamento externo", () => {
  const parsed = parsePushPayload(JSON.stringify({
    notification: {
      title: `Resumo ${"x".repeat(120)}`,
      body: `Conteúdo ${"y".repeat(300)}`,
      tag: "relatorio-loja-01",
      renotify: true,
      data: {
        url: "https://malicioso.example/captura",
        report_date: "2026-09-09T12:00:00Z",
        store_id: "store-123",
      },
    },
  }), CONTEXT);

  assert.equal(parsed.title.length, 90);
  assert.equal(parsed.options.body.length, 240);
  assert.equal(parsed.options.tag, "relatorio-loja-01");
  assert.equal(parsed.options.renotify, true);
  assert.deepEqual(parsed.options.data, {
    url: FALLBACK_URL,
    reportDate: "2026-09-09",
    storeId: "store-123",
  });
});

test("clique foca janela que já está exatamente no destino", async () => {
  const events = [];
  const targetUrl = "https://app.example.test/lead-control/?daily_report=1";
  const exact = {
    url: targetUrl,
    async focus() {
      events.push("focus-exact");
      return "focused";
    },
  };
  const clientApi = {
    async matchAll(options) {
      assert.deepEqual(options, { type: "window", includeUncontrolled: true });
      return [exact];
    },
    async openWindow() {
      events.push("open");
    },
  };

  const result = await focusOrOpenClient(clientApi, targetUrl, CONTEXT.origin);

  assert.equal(result, "focused");
  assert.deepEqual(events, ["focus-exact"]);
});

test("clique reaproveita janela da mesma origem, navega e então a coloca em foco", async () => {
  const events = [];
  const targetUrl = "https://app.example.test/lead-control/?daily_report=2";
  const current = {
    url: "https://app.example.test/lead-control/",
    async navigate(url) {
      events.push(["navigate", url]);
    },
    async focus() {
      events.push(["focus"]);
      return "focused-after-navigation";
    },
  };
  const clientApi = {
    async matchAll() {
      return [
        { url: "https://other.example/", focus() {} },
        current,
      ];
    },
    async openWindow(url) {
      events.push(["open", url]);
    },
  };

  const result = await focusOrOpenClient(clientApi, targetUrl, CONTEXT.origin);

  assert.equal(result, "focused-after-navigation");
  assert.deepEqual(events, [
    ["navigate", targetUrl],
    ["focus"],
  ]);
});

test("clique abre nova janela quando não há cliente da mesma origem", async () => {
  const targetUrl = "https://app.example.test/lead-control/?daily_report=3";
  const opened = [];
  const clientApi = {
    async matchAll() {
      return [{ url: "https://other.example/" }];
    },
    async openWindow(url) {
      opened.push(url);
      return "new-window";
    },
  };

  assert.equal(await focusOrOpenClient(clientApi, targetUrl, CONTEXT.origin), "new-window");
  assert.deepEqual(opened, [targetUrl]);
});
