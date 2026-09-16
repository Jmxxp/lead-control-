"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const source = readFileSync(require.resolve("../prospections.js"), "utf8");
const marker = "  window.ProspectionsModule = {";
assert.ok(source.includes(marker));

const listeners = {};
const root = {
  addEventListener(name, handler) { listeners[name] = handler; },
  querySelector() { return null; },
};
const hooks = {};
const instrumentedSource = source.replace(marker, `
  Object.assign(window.__testHooks, {
    periodWindow,
    filteredStoreRows,
    prospectionAdvancedFiltersMarkup,
    setListPeriod(period, startDate = "", endDate = "") {
      listPeriod = period;
      listStartDate = startDate;
      listEndDate = endDate;
    },
    setProspects(rows) { prospects = rows; selectedStoreId = "store-1"; },
    listDates() { return { startDate: listStartDate, endDate: listEndDate }; },
  });
${marker}`);
vm.runInNewContext(instrumentedSource, {
  document: {
    querySelector(selector) { return selector === "#prospectionView" ? root : null; },
    addEventListener() {},
  },
  window: { __testHooks: hooks, addEventListener() {} },
}, { filename: "prospections.js" });

const localDate = (value) => `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
const record = (id, date) => ({
  id,
  storeId: "store-1",
  createdAt: date.toISOString(),
  name: id,
  phone: "",
  cpf: "",
  notes: "",
  professionalName: "",
  probability: "blue",
  tagValues: [],
  returnedAt: null,
  purchasedAt: null,
});

test("Mês passado usa mês completo inclusive na virada do ano", () => {
  const range = hooks.periodWindow("lastMonth", new Date(2026, 0, 15, 12));
  assert.equal(localDate(range.start), "2025-12-01");
  assert.equal(localDate(range.end), "2026-01-01");
  assert.equal(range.label, "Mês passado");
});

test("busca de Mês passado exclui os registros do mês atual", () => {
  const range = hooks.periodWindow("lastMonth");
  hooks.setProspects([
    record("last-month", new Date(range.start.getFullYear(), range.start.getMonth(), 1, 12)),
    record("current-month", new Date(range.end.getFullYear(), range.end.getMonth(), 1, 12)),
  ]);
  hooks.setListPeriod("lastMonth");
  assert.deepEqual(Array.from(hooks.filteredStoreRows("store-1"), (row) => row.id), ["last-month"]);
});

test("intervalo personalizado inclui o dia final e preserva o recorte da loja", () => {
  hooks.setProspects([
    record("before", new Date(2026, 6, 9, 23, 59)),
    record("first", new Date(2026, 6, 10, 0, 0)),
    record("last", new Date(2026, 6, 18, 23, 59)),
    record("after", new Date(2026, 6, 19, 0, 0)),
    { ...record("other-store", new Date(2026, 6, 15, 12)), storeId: "store-2" },
  ]);
  hooks.setListPeriod("custom", "2026-07-10", "2026-07-18");
  assert.deepEqual(Array.from(hooks.filteredStoreRows("store-1"), (row) => row.id), ["last", "first"]);
  const markup = hooks.prospectionAdvancedFiltersMarkup("store-1", 1);
  assert.match(markup, /Mês passado/);
  assert.match(markup, /data-prospection-list-start/);
  assert.match(markup, /data-prospection-list-end/);
});

test("ao mover uma ponta do intervalo, a outra acompanha se necessário", () => {
  hooks.setListPeriod("custom", "2026-07-10", "2026-07-18");
  listeners.change({ target: {
    value: "2026-08-03",
    matches(selector) { return selector === "[data-prospection-list-start]"; },
    closest() { return null; },
  } });
  assert.deepEqual(JSON.parse(JSON.stringify(hooks.listDates())), {
    startDate: "2026-08-03",
    endDate: "2026-08-03",
  });
});

test("limpar uma data mantém o limite restante", () => {
  hooks.setListPeriod("custom", "2026-07-10", "2026-07-18");
  listeners.change({ target: {
    value: "",
    matches(selector) { return selector === "[data-prospection-list-start]"; },
    closest() { return null; },
  } });
  assert.deepEqual(JSON.parse(JSON.stringify(hooks.listDates())), {
    startDate: "",
    endDate: "2026-07-18",
  });
  hooks.setProspects([
    record("before", new Date(2026, 6, 9, 23, 59)),
    record("after", new Date(2026, 6, 19, 0, 0)),
  ]);
  assert.deepEqual(Array.from(hooks.filteredStoreRows("store-1"), (row) => row.id), ["before"]);
});
