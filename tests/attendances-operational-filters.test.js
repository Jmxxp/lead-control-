"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const source = readFileSync(require.resolve("../attendances.js"), "utf8");
const styles = readFileSync(require.resolve("../attendances.css"), "utf8");
const hooks = {};
const window = { __ATTENDANCES_TEST_HOOKS__: hooks };
vm.runInNewContext(source, { window }, { filename: "attendances.js" });

const plain = (value) => JSON.parse(JSON.stringify(value));
const reference = new Date("2026-09-04T15:00:00Z");

test("listagem operacional inicia em Hoje sem contar o padrão como filtro extra", () => {
  assert.deepEqual(plain(hooks.createOperationalFilters()), {
    search: "",
    tag: "all",
    professional: "all",
    period: "today",
    specificDate: "",
    startDate: "",
    endDate: "",
    link: "all",
  });
  assert.deepEqual(plain(hooks.embeddedAttendanceRange(hooks.createOperationalFilters(), reference)), {
    startDate: "2026-09-04",
    endDate: "2026-09-04",
    label: "Hoje",
  });
  assert.deepEqual(
    plain(hooks.embeddedAttendanceRange({}, reference)),
    plain(hooks.embeddedAttendanceRange(undefined, reference)),
  );
  assert.equal(hooks.embeddedAttendanceRange({}, reference).label, "Hoje");
});

test("atalhos de semana, mês e ano enviam limites exatos ao RPC", () => {
  assert.deepEqual(plain(hooks.embeddedAttendanceRange({ period: "currentWeek" }, reference)), {
    startDate: "2026-08-31",
    endDate: "2026-09-04",
    label: "Esta semana",
  });
  assert.deepEqual(plain(hooks.embeddedAttendanceRange({ period: "currentMonth" }, reference)), {
    startDate: "2026-09-01",
    endDate: "2026-09-04",
    label: "Mês atual",
  });
  assert.deepEqual(plain(hooks.embeddedAttendanceRange({ period: "currentYear" }, reference)), {
    startDate: "2026-01-01",
    endDate: "2026-09-04",
    label: "Ano atual",
  });
});

test("data específica, intervalo e todo o período produzem recortes sem ambiguidade", () => {
  assert.deepEqual(plain(hooks.embeddedAttendanceRange({
    period: "specificDate",
    specificDate: "2026-07-18",
  }, reference)), {
    startDate: "2026-07-18",
    endDate: "2026-07-18",
    label: "18/07/2026",
  });
  assert.deepEqual(plain(hooks.embeddedAttendanceRange({
    period: "custom",
    startDate: "2026-06-10",
    endDate: "2026-07-18",
  }, reference)), {
    startDate: "2026-06-10",
    endDate: "2026-07-18",
    label: "10/06/2026 a 18/07/2026",
  });
  assert.deepEqual(plain(hooks.embeddedAttendanceRange({ period: "all" }, reference)), {
    startDate: null,
    endDate: null,
    label: "Todo o período",
  });
});

test("controles de data aparecem apenas no recorte correspondente e mantêm layout responsivo", () => {
  assert.match(source, /<option value="currentYear"[^>]*>Este ano<\/option>/);
  assert.match(source, /<option value="specificDate"[^>]*>Data específica<\/option>/);
  assert.match(source, /<option value="custom"[^>]*>Período personalizado<\/option>/);
  assert.match(source, /data-attendance-filter-date="specific"/);
  assert.match(source, /data-attendance-filter-date="start"/);
  assert.match(source, /data-attendance-filter-date="end"/);
  assert.match(source, /queueMicrotask\(\(\) => \{[\s\S]*?focusSelector[\s\S]*?data-attendance-filter-date="specific"[\s\S]*?\.focus\(\)/);
  assert.match(styles, /\.attendance-operational-filter-panel\s*\{[\s\S]*?grid-template-columns:\s*repeat\(4,/);
  assert.match(styles, /\.attendance-operational-date-input:not\(\.is-visible\)\s*\{[\s\S]*?display:\s*none;/);
});
