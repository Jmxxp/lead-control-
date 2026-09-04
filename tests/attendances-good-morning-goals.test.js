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

test("cards repartem exatamente o saldo coletivo pelo déficit mensal vivo", () => {
  const configured = midMonthConfigurationResponseWithoutActuals(midMonthWorkspaceBeforeConfiguration());
  const context = hooks.calculateMorningWorkingDayContext(
    configured.today,
    configured.weekStart,
    configured.weekEnd,
    configured.closedDays,
  );

  const today = hooks.calculateMorningIndividualRemaining(configured, "today", context);
  const week = hooks.calculateMorningIndividualRemaining(configured, "week", context);
  const month = hooks.calculateMorningIndividualRemaining(configured, "month", context);

  // A venda anterior à configuração já formou o alvo diário e não pode ser
  // descontada duas vezes. Todos os períodos fecham com o saldo da equipe.
  assert.deepEqual(plain([...today.entries()]), [
    ["seller-a", 82381],
    ["seller-b", 123571],
  ]);
  assert.deepEqual(plain([...week.entries()]), [
    ["seller-a", 247143],
    ["seller-b", 370714],
  ]);
  assert.deepEqual(plain([...month.entries()]), [
    ["seller-a", 800000],
    ["seller-b", 1200000],
  ]);
  assert.equal(sumTargets(today), 205952);
  assert.equal(sumTargets(week), 767857 - 150000);
  assert.equal(sumTargets(month), 2600000 - 600000);
});

test("venda reduz o saldo coletivo e a rotação não altera a distribuição personalizada", () => {
  const configured = midMonthConfigurationResponseWithoutActuals(midMonthWorkspaceBeforeConfiguration());
  configured.goals.month.actual += 400;
  configured.goals.week.actual += 400;
  configured.goals.today.actual += 400;
  configured.professionals[0].actualMonth += 400;
  configured.professionals[0].actualWeek += 400;
  configured.professionals[0].actualToday += 400;

  const context = hooks.calculateMorningWorkingDayContext(
    configured.today,
    configured.weekStart,
    configured.weekEnd,
    configured.closedDays,
  );
  const balancesBeforeRotation = Object.fromEntries(
    ["today", "week", "month"].map((period) => [
      period,
      Object.fromEntries(hooks.calculateMorningIndividualRemaining(configured, period, context)),
    ]),
  );

  assert.deepEqual(plain(balancesBeforeRotation), {
    today: { "seller-a": 64349, "seller-b": 101603 },
    week: { "seller-a": 224067, "seller-b": 353790 },
    month: { "seller-a": 760000, "seller-b": 1200000 },
  });

  configured.professionals = [...configured.professionals].reverse().map((professional, index) => ({
    ...professional,
    queuePosition: index + 1,
    current: index === 0,
  }));
  configured.currentProfessionalId = "seller-b";
  const balancesAfterRotation = Object.fromEntries(
    ["today", "week", "month"].map((period) => [
      period,
      Object.fromEntries(hooks.calculateMorningIndividualRemaining(configured, period, context)),
    ]),
  );

  assert.deepEqual(plain(balancesAfterRotation), plain(balancesBeforeRotation));
});

test("frontend aceita somente saldos explícitos v3 que fecham com o coletivo", () => {
  const contract = window.AttendancesModule.getIntegrationContract();
  assert.equal(
    contract.rpc.morningWorkspace.returns.individual_goal_strategy,
    "team_remaining_personalized_v3",
  );
  assert.match(contract.rpc.morningWorkspace.returns.professionals, /remaining_today\/week\/month/);

  const workspace = hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: true,
    today: "2026-09-04",
    week_start: "2026-08-31",
    week_end: "2026-09-06",
    goal_strategy: "hierarchical_weekly_daily_team_balance_v1",
    individual_goal_strategy: "team_remaining_personalized_v3",
    rotation_affects_individual_goals: false,
    monthly_goal: 10000,
    goals: {
      today: { target: 500, actual: 250 },
      week: { target: 2500, actual: 1300 },
      month: { target: 10000, actual: 4300 },
    },
    professionals: [
      {
        id: "seller-a",
        name: "Ana",
        goal_today: 999,
        goal_week: 999,
        goal_month: 5000,
        goal_amount: 4999,
        goal_today_target: 201,
        goal_today_target_cents: 20000,
        goal_week_target: 1200,
        goal_month_target: 5001,
        goal_month_target_cents: 500000,
        actual_today: 150,
        actual_week: 900,
        actual_month: 3000,
        remaining_today: 999,
        remaining_today_cents: 8772,
        remaining_week: 421.05,
        remaining_month: 2000,
      },
      {
        id: "seller-b",
        name: "Bia",
        goal_today_target: 400,
        goal_week_target: 1800,
        goal_month_target: 5000,
        actual_today: 100,
        actual_week: 400,
        actual_month: 1300,
        remaining_today_cents: 16228,
        remaining_today: 999,
        remaining_week_cents: 77895,
        remaining_month_cents: 370000,
      },
    ],
  });

  assert.equal(workspace.professionals[0].goalToday, 200);
  assert.equal(workspace.professionals[0].goalAmount, 5000);
  assert.equal(workspace.professionals[0].goalWeek, 1200);
  assert.equal(workspace.rotationAffectsIndividualGoals, false);
  assert.equal(hooks.morningUsesServerGoalBalance(workspace), true);
  assert.deepEqual(plain([...hooks.calculateMorningIndividualRemaining(workspace, "today").entries()]), [
    ["seller-a", 8772],
    ["seller-b", 16228],
  ]);
  assert.deepEqual(plain([...hooks.calculateMorningIndividualRemaining(workspace, "week").entries()]), [
    ["seller-a", 42105],
    ["seller-b", 77895],
  ]);
  assert.deepEqual(plain([...hooks.calculateMorningIndividualRemaining(workspace, "month").entries()]), [
    ["seller-a", 200000],
    ["seller-b", 370000],
  ]);

  workspace.professionals[0].remainingToday += 0.01;
  assert.equal(hooks.morningUsesServerGoalBalance(workspace), false);
  assert.deepEqual(plain([...hooks.calculateMorningIndividualRemaining(workspace, "today").entries()]), [
    ["seller-a", 8772],
    ["seller-b", 16228],
  ]);

  const wrongProportion = hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: true,
    today: "2026-09-04",
    week_start: "2026-08-31",
    week_end: "2026-09-06",
    goal_strategy: "hierarchical_weekly_daily_team_balance_v1",
    individual_goal_strategy: "team_remaining_personalized_v3",
    rotation_affects_individual_goals: false,
    goals: {
      today: { target: 600, actual: 350 },
      week: { target: 2500, actual: 1300 },
      month: { target: 10000, actual: 4300 },
    },
    professionals: [
      {
        id: "seller-a",
        name: "Ana",
        goal_month_target_cents: 500000,
        goal_week_target_cents: 120000,
        goal_today_target_cents: 20000,
        actual_month: 3000,
        remaining_month_cents: 200000,
        remaining_week_cents: 60000,
        remaining_today_cents: 12500,
      },
      {
        id: "seller-b",
        name: "Bia",
        goal_month_target_cents: 500000,
        goal_week_target_cents: 130000,
        goal_today_target_cents: 40000,
        actual_month: 1300,
        remaining_month_cents: 370000,
        remaining_week_cents: 60000,
        remaining_today_cents: 12500,
      },
    ],
  });
  assert.equal(
    hooks.morningUsesServerGoalBalance(wrongProportion),
    false,
    "fechar a soma não basta: a proporção do déficit também precisa estar exata",
  );
  assert.deepEqual(
    plain([...hooks.calculateMorningIndividualRemaining(wrongProportion, "today").entries()]),
    [["seller-a", 8772], ["seller-b", 16228]],
  );
});

test("cutoff usa apenas delta positivo sem esconder o realizado histórico", () => {
  const workspace = hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: true,
    today: "2026-09-16",
    week_start: "2026-09-14",
    week_end: "2026-09-20",
    goal_strategy: "hierarchical_weekly_daily_team_balance_v1",
    configuration_actual_snapshot_active: true,
    actual_today_before_configuration: 300,
    goals: {
      today: { target: 1000, actual: 200 },
      week: { target: 5000, actual: 200 },
      month: { target: 10000, actual: 200 },
    },
    professionals: [
      {
        id: "00000000-0000-4000-8000-000000000001",
        name: "Ana",
        goal_amount: 10000,
        actual_month: 200,
        actual_week: 200,
        actual_today: 200,
      },
    ],
  });

  assert.equal(workspace.goals.today.actual, 200, "o card mantém o realizado completo do dia");
  assert.equal(hooks.morningEffectiveActualCents(workspace, "today"), 0);
  assert.equal(
    hooks.calculateMorningIndividualRemaining(workspace, "today").get(workspace.professionals[0].id),
    100000,
  );

  workspace.goals.today.actual = 450;
  assert.equal(hooks.morningEffectiveActualCents(workspace, "today"), 15000);
  assert.equal(
    hooks.calculateMorningIndividualRemaining(workspace, "today").get(workspace.professionals[0].id),
    85000,
  );
});

test("um centavo é atribuído pelo UUID e não muda com a ordem da rotação", () => {
  const raw = {
    licensed: true,
    configured: true,
    today: "2026-09-04",
    week_start: "2026-09-01",
    week_end: "2026-09-06",
    goal_strategy: "hierarchical_weekly_daily_team_balance_v1",
    individual_goal_strategy: "own_remaining_balance_v2",
    monthly_goal: 0.01,
    goals: {
      today: { target: 0.01, actual: 0 },
      week: { target: 0.01, actual: 0 },
      month: { target: 0.01, actual: 0 },
    },
    professionals: [
      { id: "00000000-0000-4000-8000-000000000003", name: "C", goal_amount: 0.01, actual_month: 0 },
      { id: "00000000-0000-4000-8000-000000000001", name: "A", goal_amount: 0.01, actual_month: 0 },
      { id: "00000000-0000-4000-8000-000000000002", name: "B", goal_amount: 0.01, actual_month: 0 },
    ],
  };
  const before = hooks.normalizeMorningWorkspace(raw);
  const after = hooks.normalizeMorningWorkspace({
    ...raw,
    professionals: [...raw.professionals].reverse(),
  });

  const expected = {
    "00000000-0000-4000-8000-000000000001": 1,
    "00000000-0000-4000-8000-000000000002": 0,
    "00000000-0000-4000-8000-000000000003": 0,
  };
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(before, "today"))), expected);
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(after, "today"))), expected);
});

test("venda de não participante reduz o saldo coletivo sem quebrar o fechamento individual", () => {
  const workspace = hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: true,
    today: "2026-09-04",
    week_start: "2026-09-01",
    week_end: "2026-09-06",
    goal_strategy: "hierarchical_weekly_daily_team_balance_v1",
    individual_goal_strategy: "own_remaining_balance_v2",
    monthly_goal: 10000,
    goals: {
      today: { target: 1000, actual: 300 },
      week: { target: 5000, actual: 1500 },
      month: { target: 10000, actual: 3000 },
    },
    professionals: [
      {
        id: "00000000-0000-4000-8000-000000000001",
        name: "Ana",
        good_morning_seller_enabled: true,
        goal_amount: 5000,
        actual_month: 1000,
      },
      {
        id: "00000000-0000-4000-8000-000000000002",
        name: "Bia",
        good_morning_seller_enabled: true,
        goal_amount: 5000,
        actual_month: 1000,
      },
      {
        id: "00000000-0000-4000-8000-000000000003",
        name: "Sem meta",
        good_morning_seller_enabled: false,
        goal_amount: 0,
        actual_month: 1000,
      },
    ],
  });

  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "today"))), {
    "00000000-0000-4000-8000-000000000001": 35000,
    "00000000-0000-4000-8000-000000000002": 35000,
  });
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "week"))), {
    "00000000-0000-4000-8000-000000000001": 175000,
    "00000000-0000-4000-8000-000000000002": 175000,
  });
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "month"))), {
    "00000000-0000-4000-8000-000000000001": 350000,
    "00000000-0000-4000-8000-000000000002": 350000,
  });
});

test("caso real fecha dia, semana e mês sem zerar quem ainda tem déficit mensal", () => {
  const workspace = hooks.normalizeMorningWorkspace({
    licensed: true,
    configured: true,
    today: "2026-09-04",
    week_start: "2026-09-01",
    week_end: "2026-09-06",
    goal_strategy: "hierarchical_weekly_daily_team_balance_v1",
    individual_goal_strategy: "own_remaining_balance_v2",
    rotation_affects_individual_goals: false,
    monthly_goal: 130800,
    closed_days: [{ date: "2026-09-30", reason: "Sem expediente" }],
    goals: {
      today: { target: 3853, actual: 0 },
      week: { target: 26160, actual: 18454 },
      month: { target: 130800, actual: 18454 },
    },
    professionals: [
      {
        id: "00000000-0000-4000-8000-000000000001",
        name: "Ana",
        goal_amount: 65400,
        actual_month: 14315,
        actual_week: 14315,
        actual_today: 0,
        goal_today_target: 0,
        goal_week_target: 13080,
        goal_month_target: 65400,
        remaining_today: 0,
        remaining_week: 0,
        remaining_month: 51085,
        queue_position: 2,
        is_current: false,
      },
      {
        id: "00000000-0000-4000-8000-000000000002",
        name: "Kézia",
        goal_amount: 65400,
        actual_month: 4139,
        actual_week: 4139,
        actual_today: 0,
        goal_today_target: 4470.5,
        goal_week_target: 13080,
        goal_month_target: 65400,
        remaining_today: 4470.5,
        remaining_week: 8941,
        remaining_month: 61261,
        queue_position: 1,
        is_current: true,
      },
    ],
  });
  const context = hooks.calculateMorningWorkingDayContext(
    workspace.today,
    workspace.weekStart,
    workspace.weekEnd,
    workspace.closedDays,
  );
  const plan = hooks.calculateMorningRemainingGoalPlan(workspace, context);

  assert.equal(context.total, 25);
  assert.equal(context.weekWorkdays, 5);
  assert.equal(context.remainingWeekWorkdays, 2);
  assert.equal(plan.weekTargetCents, 2616000);
  assert.equal(plan.todayTargetCents, 385300);
  assert.equal(sumTargets(plan.weekTargetsCents), plan.weekTargetCents);
  assert.equal(sumTargets(plan.todayTargetsCents), plan.todayTargetCents);
  assert.equal(hooks.morningUsesServerGoalBalance(workspace), false, "v2 não pode mais ser confiado");
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "week", context))), {
    "00000000-0000-4000-8000-000000000001": 350401,
    "00000000-0000-4000-8000-000000000002": 420199,
  });
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "today", context))), {
    "00000000-0000-4000-8000-000000000001": 175200,
    "00000000-0000-4000-8000-000000000002": 210100,
  });
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "month", context))), {
    "00000000-0000-4000-8000-000000000001": 5108500,
    "00000000-0000-4000-8000-000000000002": 6126100,
  });
  const kezia = workspace.professionals.find((professional) => professional.name === "Kézia");
  assert.equal(
    hooks.morningProfessionalRemainingAmount(kezia, "today", context, plan, workspace),
    2101,
    "a camada de apresentação deve converter centavos para reais exatamente uma vez",
  );

  workspace.currentProfessionalId = "00000000-0000-4000-8000-000000000001";
  workspace.professionals.forEach((professional) => {
    professional.current = professional.id === workspace.currentProfessionalId;
    professional.queuePosition = professional.current ? 1 : 2;
  });
  assert.deepEqual(plain(Object.fromEntries(hooks.calculateMorningIndividualRemaining(workspace, "today", context))), {
    "00000000-0000-4000-8000-000000000001": 175200,
    "00000000-0000-4000-8000-000000000002": 210100,
  });
});
