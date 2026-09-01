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

function midMonthWorkspaceBeforeConfiguration() {
  return hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: false,
    today: "2026-09-16",
    week_start: "2026-09-14",
    week_end: "2026-09-20",
    goals: {
      today: { target: 0, actual: 300 },
      week: { target: 0, actual: 1500 },
      month: { target: 0, actual: 6000 },
    },
    professionals: [
      {
        id: "seller-a",
        name: "Ana",
        good_morning_seller_enabled: true,
        actual_month: 5000,
        actual_week: 1500,
        actual_today: 300,
      },
      {
        id: "seller-b",
        name: "Bia",
        good_morning_seller_enabled: true,
        actual_month: 1000,
        actual_week: 0,
        actual_today: 0,
      },
    ],
  });
}

function midMonthConfigurationResponseWithoutActuals(previousWorkspace) {
  return hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: true,
    monthly_goal: 26000,
    today: "2026-09-16",
    week_start: "2026-09-14",
    week_end: "2026-09-20",
    closed_days: [{ date: "2026-09-17", reason: "Feriado municipal" }],
    configuration_actual_snapshot_active: true,
    configuration_actual_snapshot_strategy: "immutable_month_week_today_cents_v1",
    actual_month_at_configuration: 6000,
    actual_week_at_configuration: 1500,
    actual_today_before_configuration: 300,
    historical_actuals_strategy: "full_operational_month_with_initial_configuration_cutoff_v1",
    initial_configuration_cutoff_applied: true,
    goals: {
      today: { target: 0 },
      week: { target: 0 },
      month: { target: 26000 },
    },
    professionals: [
      {
        id: "seller-a",
        name: "Ana",
        good_morning_seller_enabled: true,
        goal_amount: 13000,
        goal_month: 13000,
        goal_week: 0,
        goal_today: 0,
        queue_position: 1,
        actual_month_at_configuration: 5000,
        actual_week_at_configuration: 1500,
        actual_today_before_configuration: 300,
      },
      {
        id: "seller-b",
        name: "Bia",
        good_morning_seller_enabled: true,
        goal_amount: 13000,
        goal_month: 13000,
        goal_week: 0,
        goal_today: 0,
        queue_position: 2,
        actual_month_at_configuration: 1000,
        actual_week_at_configuration: 0,
        actual_today_before_configuration: 0,
      },
    ],
  }, previousWorkspace);
}

function sumTargets(targets) {
  return [...targets.values()].reduce((sum, value) => sum + value, 0);
}

test("configuração no meio do mês não apaga realizados se a resposta de escrita omitir os snapshots", () => {
  const before = midMonthWorkspaceBeforeConfiguration();
  const configured = midMonthConfigurationResponseWithoutActuals(before);

  assert.deepEqual(plain(configured.goals), {
    today: { target: 0, actual: 300 },
    week: { target: 0, actual: 1500 },
    month: { target: 26000, actual: 6000 },
  });
  assert.deepEqual(plain(configured.professionals.map((professional) => ({
    id: professional.id,
    actualMonth: professional.actualMonth,
    actualWeek: professional.actualWeek,
    actualToday: professional.actualToday,
  }))), [
    { id: "seller-a", actualMonth: 5000, actualWeek: 1500, actualToday: 300 },
    { id: "seller-b", actualMonth: 1000, actualWeek: 0, actualToday: 0 },
  ]);
});

test("fallback do total preserva vendas fora da equipe ativa e respeita zero explícito", () => {
  const before = midMonthWorkspaceBeforeConfiguration();
  before.goals.month.actual = 6500;
  const partialResponse = {
    licensed: true,
    configured: true,
    monthly_goal: 26000,
    today: before.today,
    week_start: before.weekStart,
    week_end: before.weekEnd,
    goals: { month: { target: 26000 }, week: { target: 0 }, today: { target: 0 } },
    professionals: before.professionals.map((professional) => ({
      id: professional.id,
      name: professional.name,
      goal_amount: 13000,
      actual_month: professional.actualMonth,
      actual_week: professional.actualWeek,
      actual_today: professional.actualToday,
    })),
  };

  const preserved = hooks.normalizeMorningWorkspace(partialResponse, before);
  assert.equal(preserved.goals.month.actual, 6500);
  assert.equal(preserved.professionals.reduce((sum, professional) => sum + professional.actualMonth, 0), 6000);

  partialResponse.goals.month.actual = 0;
  const explicitZero = hooks.normalizeMorningWorkspace(partialResponse, before);
  assert.equal(explicitZero.goals.month.actual, 0);
});

test("meta no meio do mês desconta histórico do mês e da semana e fecha cada distribuição em centavos", () => {
  const configured = midMonthConfigurationResponseWithoutActuals(midMonthWorkspaceBeforeConfiguration());
  const context = hooks.calculateMorningWorkingDayContext(
    configured.today,
    configured.weekStart,
    configured.weekEnd,
    configured.closedDays,
  );
  const plan = hooks.calculateMorningRemainingGoalPlan(configured, context);

  assert.equal(context.total, 25);
  assert.equal(context.weekWorkdays, 5);
  assert.equal(context.remainingMonthWorkdaysFromWeekStart, 14);
  assert.equal(context.remainingWeekWorkdays, 3);

  // Saldo no início da semana: 26.000 - (6.000 - 1.500) = 21.500.
  // Meta fixa da semana: 21.500 * 5 / 14 = 7.678,57.
  assert.equal(plan.weekTargetCents, 767857);
  // Os R$ 300 vendidos antes da primeira configuração entram no saldo inicial:
  // (7.678,57 - (1.500 - 300 + 300)) / 3 = 2.059,52.
  assert.equal(plan.todayTargetCents, 205952);
  assert.deepEqual(plain([...plan.weekTargetsCents.entries()]), [
    ["seller-a", 339286],
    ["seller-b", 428571],
  ]);
  assert.deepEqual(plain([...plan.todayTargetsCents.entries()]), [
    ["seller-a", 63095],
    ["seller-b", 142857],
  ]);
  assert.equal(sumTargets(plan.weekTargetsCents), plan.weekTargetCents);
  assert.equal(sumTargets(plan.todayTargetsCents), plan.todayTargetCents);
});

test("compra de hoje aparece no realizado sem mover a meta; no próximo dia aberto reduz o saldo", () => {
  const configured = midMonthConfigurationResponseWithoutActuals(midMonthWorkspaceBeforeConfiguration());
  const contextToday = hooks.calculateMorningWorkingDayContext(
    configured.today,
    configured.weekStart,
    configured.weekEnd,
    configured.closedDays,
  );
  const beforeSale = hooks.calculateMorningRemainingGoalPlan(configured, contextToday);

  configured.goals.month.actual += 400;
  configured.goals.week.actual += 400;
  configured.goals.today.actual += 400;
  configured.professionals[0].actualMonth += 400;
  configured.professionals[0].actualWeek += 400;
  configured.professionals[0].actualToday += 400;
  const afterSameDaySale = hooks.calculateMorningRemainingGoalPlan(configured, contextToday);

  assert.equal(configured.goals.today.actual, 700);
  assert.equal(afterSameDaySale.weekTargetCents, beforeSale.weekTargetCents);
  assert.equal(afterSameDaySale.todayTargetCents, beforeSale.todayTargetCents);
  assert.deepEqual(
    plain([...afterSameDaySale.todayTargetsCents.entries()]),
    plain([...beforeSale.todayTargetsCents.entries()]),
  );

  // Uma edição pós-configuração pode mudar valor, data, tag ou profissional.
  // Enquanto o snapshot inicial está ativo, nem o alvo geral nem o individual
  // podem ser recalculados pelos totais ao vivo mutáveis.
  configured.goals.month.actual = 5200;
  configured.goals.week.actual = 200;
  configured.goals.today.actual = 0;
  configured.professionals[0].actualMonth = 0;
  configured.professionals[0].actualWeek = 0;
  configured.professionals[0].actualToday = 0;
  configured.professionals[1].actualMonth = 5200;
  configured.professionals[1].actualWeek = 200;
  configured.professionals[1].actualToday = 0;
  const afterIntradayEdit = hooks.calculateMorningRemainingGoalPlan(configured, contextToday);
  assert.equal(afterIntradayEdit.weekTargetCents, beforeSale.weekTargetCents);
  assert.equal(afterIntradayEdit.todayTargetCents, beforeSale.todayTargetCents);
  assert.deepEqual(
    plain([...afterIntradayEdit.todayTargetsCents.entries()]),
    plain([...beforeSale.todayTargetsCents.entries()]),
  );

  configured.today = "2026-09-18";
  configured.configurationActualSnapshotActive = false;
  configured.goals.month.actual = 6400;
  configured.goals.week.actual = 1900;
  configured.goals.today.actual = 0;
  configured.actualTodayBeforeConfiguration = 0;
  configured.professionals[0].actualMonth = 5400;
  configured.professionals[0].actualWeek = 1900;
  configured.professionals[0].actualToday = 0;
  configured.professionals[0].actualTodayBeforeConfiguration = 0;
  configured.professionals[1].actualMonth = 1000;
  configured.professionals[1].actualWeek = 0;
  configured.professionals[1].actualToday = 0;
  const nextOpenDayContext = hooks.calculateMorningWorkingDayContext(
    configured.today,
    configured.weekStart,
    configured.weekEnd,
    configured.closedDays,
  );
  const nextOpenDay = hooks.calculateMorningRemainingGoalPlan(configured, nextOpenDayContext);

  assert.equal(nextOpenDayContext.remainingWeekWorkdays, 2);
  assert.equal(nextOpenDay.weekTargetCents, 767857);
  assert.equal(nextOpenDay.todayTargetCents, 288929);
  assert.deepEqual(plain([...nextOpenDay.todayTargetsCents.entries()]), [
    ["seller-a", 74643],
    ["seller-b", 214286],
  ]);
  assert.equal(sumTargets(nextOpenDay.todayTargetsCents), nextOpenDay.todayTargetCents);
});
