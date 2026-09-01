"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const source = readFileSync(require.resolve("../attendances.js"), "utf8");
const hooks = {};
const window = { __ATTENDANCES_TEST_HOOKS__: hooks };
vm.runInNewContext(source, { window }, { filename: "attendances.js" });

const plain = (value) => JSON.parse(JSON.stringify(value));

test("normaliza, ordena e deduplica dias fechados do mês atual", () => {
  const result = hooks.normalizeMorningClosedDays([
    { date: "2026-09-10", reason: "" },
    { date: "2026-09-07", reason: "  Feriado   municipal  " },
    { date: "2026-09-07", reason: "Duplicado" },
    { date: "2026-09-06", reason: "Domingo" },
    { date: "2026-08-31", reason: "Outro mês" },
    { date: "inválida", reason: "Inválida" },
  ], "2026-09-08");

  assert.deepEqual(plain(result), [
    { date: "2026-09-07", reason: "Feriado municipal" },
    { date: "2026-09-10", reason: "Sem expediente" },
  ]);
});

test("valida mês atual, domingo, duplicata, limite e tamanho do motivo", () => {
  assert.match(hooks.validateMorningClosedDayEntry("2026-08-31", "", [], "2026-09-08").error, /mês atual/i);
  assert.match(hooks.validateMorningClosedDayEntry("2026-09-06", "", [], "2026-09-08").error, /domingos/i);
  assert.match(hooks.validateMorningClosedDayEntry(
    "2026-09-07",
    "",
    [{ date: "2026-09-07", reason: "Sem expediente" }],
    "2026-09-08",
  ).error, /já foi adicionada/i);
  assert.match(hooks.validateMorningClosedDayEntry(
    "2026-09-07",
    "",
    Array.from({ length: 31 }, (_, index) => ({ date: `existente-${index}` })),
    "2026-09-08",
  ).error, /no máximo 31/i);
  assert.match(hooks.validateMorningClosedDayEntry(
    "2026-09-07",
    "x".repeat(161),
    [],
    "2026-09-08",
  ).error, /160 caracteres/i);

  assert.deepEqual(plain(hooks.validateMorningClosedDayEntry(
    "2026-09-07",
    "",
    [],
    "2026-09-08",
  )), {
    valid: true,
    entry: { date: "2026-09-07", reason: "Sem expediente" },
  });
});

test("fallback conta segunda a sábado e exclui cada data fechada de todos os divisores", () => {
  const regular = hooks.calculateMorningWorkingDayContext(
    "2026-09-08",
    "2026-09-07",
    "2026-09-13",
    [],
  );
  assert.equal(regular.total, 26);
  assert.equal(regular.weekWorkdays, 6);
  assert.equal(regular.remainingWeekWorkdays, 5);
  assert.equal(regular.todayIsWorkingDay, true);

  const withClosures = hooks.calculateMorningWorkingDayContext(
    "2026-09-08",
    "2026-09-07",
    "2026-09-13",
    [
      { date: "2026-09-07", reason: "Feriado" },
      { date: "2026-09-10", reason: "Inventário" },
    ],
  );
  assert.deepEqual(plain(withClosures), {
    total: 24,
    throughToday: 6,
    beforeToday: 5,
    remainingWorkdays: 19,
    beforeWeek: 5,
    throughWeek: 9,
    weekWorkdays: 4,
    remainingMonthWorkdaysFromWeekStart: 19,
    remainingWeekWorkdays: 4,
    todayIsWorkingDay: true,
    weekStart: "2026-09-07",
    weekEnd: "2026-09-13",
  });

  const closedToday = hooks.calculateMorningWorkingDayContext(
    "2026-09-08",
    "2026-09-07",
    "2026-09-13",
    [
      { date: "2026-09-07", reason: "Feriado" },
      { date: "2026-09-08", reason: "Sem expediente" },
      { date: "2026-09-10", reason: "Inventário" },
    ],
  );
  assert.equal(closedToday.todayIsWorkingDay, false);
  assert.equal(closedToday.total, 23);
  assert.equal(closedToday.throughToday, 5);
  assert.equal(closedToday.beforeToday, 5);
  assert.equal(closedToday.weekWorkdays, 3);
  assert.equal(closedToday.remainingWeekWorkdays, 3);
});

test("rascunho preserva calendário e campos pendentes após clone e merge de participação", () => {
  const draft = {
    monthlyGoal: 120000,
    mode: "custom",
    professionals: [{ id: "seller-1", name: "Ana", enabled: true, goalAmount: 120000 }],
    closedDays: [{ date: "2026-09-07", reason: "Feriado" }],
    closedDayDate: "2026-09-10",
    closedDayReason: "Inventário",
  };
  const cloned = hooks.cloneMorningDraft(draft);
  const merged = hooks.mergeMorningDraftWithWorkspace(cloned, {
    today: "2026-09-08",
    professionals: [{ id: "seller-1", name: "Ana", enabled: false, goalAmount: 0 }],
  });

  assert.deepEqual(plain(merged.closedDays), [{ date: "2026-09-07", reason: "Feriado" }]);
  assert.equal(merged.closedDayDate, "2026-09-10");
  assert.equal(merged.closedDayReason, "Inventário");
  assert.equal(merged.professionals[0].enabled, false);
});

test("contrato público exige RPC v2 atômica e mantém a v1 apenas para rollout", () => {
  const contract = window.AttendancesModule.getIntegrationContract();
  assert.equal(contract.version, 5);
  assert.equal(contract.rpc.morningSave.name, "lc_save_good_morning_seller_settings_v2");
  assert.ok(contract.rpc.morningSave.args.p_closed_days);
  assert.equal(contract.rpc.morningSaveLegacy.name, "lc_save_good_morning_seller_settings");
});
