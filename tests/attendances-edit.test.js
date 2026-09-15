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

test("normaliza datas e token de concorrência sem misturar criação com atendimento", () => {
  const record = hooks.normalizeRecord({
    id: "attendance-1",
    store_id: "store-1",
    professional_name: "Ana",
    customer_name: "Cliente",
    attended_on: "2026-08-30",
    created_at: "2026-09-01T12:30:00-03:00",
    updated_at: "2026-09-01T13:44:59-03:00",
    expected_updated_at: "2026-09-01T13:45:00-03:00",
  });

  assert.equal(record.attendedOn, "2026-08-30");
  assert.equal(record.createdAt, "2026-08-30");
  assert.equal(record.registeredAt, "2026-09-01T12:30:00-03:00");
  assert.equal(record.updatedAt, "2026-09-01T13:45:00-03:00");
  assert.equal(hooks.attendanceRecordDate(record), "2026-08-30");
});

test("prefill mantém todos os campos comerciais e converte timestamp no fuso de São Paulo", () => {
  assert.equal(hooks.attendanceRecordDate({ createdAt: "2026-09-01T01:00:00Z" }), "2026-08-31");
  const draft = hooks.createAttendanceEditDraft({
    id: "attendance-2",
    storeId: "store-2",
    updatedAt: "2026-09-01T18:00:00Z",
    registeredAt: "2026-08-20T10:00:00-03:00",
    createdAt: "2026-08-31T15:00:00-03:00",
    professionalName: "Ana Arquivada",
    customerName: "Maria Souza",
    phone: "11999999999",
    cpf: "52998224725",
    description: "Compra concluída",
    serviceValue: 150.5,
    tag: "purchase",
    purchaseValue: 1200,
    serviceOrder: "OS-1048",
  });

  assert.deepEqual(plain(draft), {
    id: "attendance-2",
    storeId: "store-2",
    expectedUpdatedAt: "2026-09-01T18:00:00Z",
    registeredAt: "2026-08-20T10:00:00-03:00",
    originalProfessionalName: "Ana Arquivada",
    professionalName: "Ana Arquivada",
    attendedOn: "2026-08-31",
    customerName: "Maria Souza",
    phone: "(11) 99999-9999",
    cpf: "529.982.247-25",
    description: "Compra concluída",
    serviceValue: "150,50",
    tag: "purchase",
    purchaseValue: "1.200,00",
    serviceOrder: "OS-1048",
    serviceOrders: [{ serviceOrder: "OS-1048", value: "1.200,00" }],
  });

  assert.equal(hooks.formatDateTime("2026-09-01T02:30:00Z").includes("23:30"), true);
  assert.match(hooks.formatDateTime("2026-09-01T02:30:00Z"), /^31\s/);
});

test("parser monetário é estrito, brasileiro e não reinterpreta milhar como centavos", () => {
  assert.equal(hooks.parseAttendanceMoney("1.234"), 1234);
  assert.equal(hooks.parseAttendanceMoney("1.234,56"), 1234.56);
  assert.equal(hooks.parseAttendanceMoney("1234,56"), 1234.56);
  assert.equal(hooks.parseAttendanceMoney("1234"), 1234);
  assert.equal(hooks.parseAttendanceMoney("R$ 0,50"), 0.5);
  assert.equal(hooks.parseAttendanceMoney(""), null);
  assert.equal(hooks.parseAttendanceMoney("0"), 0);
  assert.throws(() => hooks.parseAttendanceMoney("1.23"), /formato brasileiro/i);
  assert.throws(() => hooks.parseAttendanceMoney("1,234"), /formato brasileiro/i);
  assert.throws(() => hooks.parseAttendanceMoney("valor 50"), /formato brasileiro/i);
});

test("múltiplas OS são normalizadas, somadas em centavos e preservadas no prefill", () => {
  const record = hooks.normalizeRecord({
    id: "attendance-multi-os",
    tag: "purchase",
    service_orders: [
      { service_order: "OS-200", amount: "100.01", position: 2 },
      { order_number: "OS-100", value: "200.02", position: 1 },
    ],
  });

  assert.equal(record.purchaseValue, 300.03);
  assert.deepEqual(plain(record.serviceOrders.map(({ serviceOrder, amount, position }) => ({ serviceOrder, amount, position }))), [
    { serviceOrder: "OS-100", amount: 200.02, position: 1 },
    { serviceOrder: "OS-200", amount: 100.01, position: 2 },
  ]);
  assert.equal(hooks.serviceOrdersTotalCents(record.serviceOrders), 30003);
  assert.deepEqual(plain(hooks.createAttendanceEditDraft(record).serviceOrders), [
    { serviceOrder: "OS-100", value: "200,02" },
    { serviceOrder: "OS-200", value: "100,01" },
  ]);
});

test("validação de compra gera payload de várias OS e rejeita duplicidade", () => {
  const common = {
    professional_name: "Ana",
    attended_on: "2026-09-01",
    customer_name: "Cliente",
    phone: "11999999999",
    cpf: "",
    description: "Duas compras no mesmo atendimento",
    tag: "purchase",
    service_value: "",
    service_orders: [
      { serviceOrder: "OS-10", value: "1.000,01" },
      { serviceOrder: "OS-11", value: "249,99" },
    ],
  };
  const options = {
    professionalNames: ["Ana"],
    dateLimits: { min: "2024-09-01", today: "2026-09-01" },
    retroactiveDatesGranted: true,
  };
  const submitted = hooks.validateAttendanceSubmission(common, options);

  assert.equal(submitted.purchaseValue, 1250);
  assert.equal(submitted.serviceOrder, "OS-10");
  assert.deepEqual(plain(submitted.serviceOrders), [
    { service_order: "OS-10", amount: 1000.01 },
    { service_order: "OS-11", amount: 249.99 },
  ]);
  assert.throws(() => hooks.validateAttendanceSubmission({
    ...common,
    service_orders: [
      { serviceOrder: "OS-10", value: "10,00" },
      { serviceOrder: " os-10 ", value: "20,00" },
    ],
  }, options), /adicionada mais de uma vez/i);
});

test("cancelamento normaliza auditoria e envia escopo, token e motivo", () => {
  const record = hooks.normalizeRecord({
    id: "attendance-canceled",
    store_id: "store-1",
    updated_at: "2026-09-15T12:00:00Z",
    canceled_at: "2026-09-15T12:05:00Z",
    canceled_by_name: "Admin",
    cancellation_reason: "Compra desfeita",
    links: {
      active: false,
      historical: true,
      lead: { id: "lead-original", name: "Cliente original", historical: true },
      prospection: { id: "prospection-original", historical: true },
    },
  });
  assert.equal(record.canceled, true);
  assert.equal(record.canceledBy, "Admin");
  assert.equal(record.cancellationReason, "Compra desfeita");
  assert.equal(record.linkedLead.linked, false);
  assert.equal(record.linkedLead.historical, true);
  assert.equal(record.linkedProspection.linked, false);
  assert.equal(record.linkedProspection.historical, true);
  assert.deepEqual(plain(hooks.attendanceCancelArgs(record, "  Cliente desistiu  ")), {
    p_attendance_id: "attendance-canceled",
    p_store_id: "store-1",
    p_expected_updated_at: "2026-09-15T12:00:00Z",
    p_reason: "Cliente desistiu",
  });
});

test("cancelamento só é confirmado por registro autoritativo cancelado do mesmo escopo", () => {
  const expected = { id: "attendance-canceled", storeId: "store-1" };
  const valid = hooks.authoritativeCanceledAttendance({
    canceled: true,
    attendance: {
      id: expected.id,
      store_id: expected.storeId,
      canceled_at: "2026-09-15T12:05:00Z",
    },
  }, expected);

  assert.equal(valid.id, expected.id);
  assert.equal(valid.canceled, true);
  assert.equal(hooks.authoritativeCanceledAttendance({ success: true }, expected), null);
  assert.equal(hooks.authoritativeCanceledAttendance({
    attendance: { id: expected.id, store_id: expected.storeId, canceled: false },
  }, expected), null);
  assert.equal(hooks.authoritativeCanceledAttendance({
    attendance: { id: expected.id, canceled_at: "2026-09-15T12:05:00Z" },
  }, expected), null);
  assert.equal(hooks.authoritativeCanceledAttendance({
    attendance: { id: expected.id, store_id: "store-2", canceled_at: "2026-09-15T12:05:00Z" },
  }, expected), null);
});

test("histórico cancelado não inventa uma segunda origem ausente", () => {
  const record = hooks.normalizeRecord({
    id: "attendance-canceled-single-origin",
    canceled_at: "2026-09-15T12:05:00Z",
    links: {
      active: false,
      historical: true,
      lead: { id: "lead-original", historical: true },
      prospection: null,
    },
  });

  assert.equal(record.linkedLead.historical, true);
  assert.equal(record.linkedProspection.historical, false);
  assert.equal(record.linkedProspection.id, "");
});

test("fallback de indicadores ignora cancelados no valor, meta e conversão", () => {
  const metrics = hooks.embeddedAttendanceMetricData([
    hooks.normalizeRecord({
      id: "active-purchase",
      tag: "purchase",
      purchase_value: 450,
      service_value: 25,
      phone: "11999990001",
    }),
    hooks.normalizeRecord({
      id: "canceled-purchase",
      tag: "purchase",
      purchase_value: 900,
      service_value: 50,
      phone: "11999990002",
      canceled_at: "2026-09-15T12:05:00Z",
    }),
  ]);

  assert.equal(metrics.total, 1);
  assert.equal(metrics.purchases, 1);
  assert.equal(metrics.revenue, 450);
  assert.equal(metrics.serviceValue, 25);
  assert.equal(metrics.conversion, 100);
  assert.equal(metrics.uniqueCustomers, 1);
});

test("normalização e prefill distinguem NULL de zero no valor do atendimento", () => {
  const emptyRecord = hooks.normalizeRecord({
    id: "attendance-null",
    service_value: null,
    purchase_value: null,
  });
  const zeroRecord = hooks.normalizeRecord({
    id: "attendance-zero",
    service_value: 0,
    purchase_value: 0,
  });

  assert.equal(emptyRecord.serviceValue, null);
  assert.equal(emptyRecord.purchaseValue, null);
  assert.equal(zeroRecord.serviceValue, 0);
  assert.equal(zeroRecord.purchaseValue, 0);
  assert.equal(hooks.createAttendanceEditDraft(emptyRecord).serviceValue, "");
  assert.equal(hooks.createAttendanceEditDraft(zeroRecord).serviceValue, "0,00");
});

test("edição reutiliza as validações do cadastro e aceita o atendente histórico sem liberá-lo globalmente", () => {
  const common = {
    professional_name: "Ana Arquivada",
    attended_on: "2026-08-31",
    customer_name: "Maria Souza",
    phone: "(11) 99999-9999",
    cpf: "",
    description: "Retorno e fechamento da compra",
    tag: "purchase",
    service_value: "150,50",
    purchase_value: "1.200,00",
    service_order: "OS-1048",
  };
  const options = {
    professionalNames: ["Profissional atual"],
    preservedProfessionalName: "Ana Arquivada",
    dateLimits: { min: "2024-09-01", today: "2026-09-01" },
    retroactiveDatesGranted: true,
  };

  const result = hooks.validateAttendanceSubmission(common, options);
  assert.equal(result.professionalName, "Ana Arquivada");
  assert.equal(result.phone, "11999999999");
  assert.equal(result.purchaseValue, 1200);
  assert.equal(hooks.validateAttendanceSubmission(common, {
    ...options,
    professionalNames: [],
  }).professionalName, "Ana Arquivada");
  assert.equal(hooks.validateAttendanceSubmission({
    ...common,
    professional_name: "Profissional atual",
  }, options).professionalName, "Profissional atual");

  assert.throws(
    () => hooks.validateAttendanceSubmission({ ...common, professional_name: "Nome adulterado" }, options),
    /profissional cadastrado/i,
  );
  assert.throws(
    () => hooks.validateAttendanceSubmission({ ...common, purchase_value: "0" }, options),
    /valor da compra/i,
  );

  const withoutServiceValue = hooks.validateAttendanceSubmission({
    ...common,
    tag: "budget",
    service_value: "",
    purchase_value: "",
    service_order: "",
  }, options);
  assert.equal(withoutServiceValue.serviceValue, null);
  assert.equal(withoutServiceValue.purchaseValue, null);
});

test("erros customizados identificam e focam o campo responsável", () => {
  let validationError;
  try {
    hooks.validateAttendanceSubmission({
      professional_name: "Ana",
      attended_on: "2026-09-01",
      customer_name: "Cliente",
      phone: "11999999999",
      cpf: "",
      description: "",
      tag: "budget",
      service_value: "",
    }, {
      professionalNames: ["Ana"],
      dateLimits: { min: "2024-09-01", today: "2026-09-01" },
      retroactiveDatesGranted: true,
    });
  } catch (error) {
    validationError = error;
  }

  assert.equal(validationError?.attendanceFieldName, "description");
  const attributes = new Map();
  let focused = false;
  let scrolled = false;
  const description = {
    focus() { focused = true; },
    scrollIntoView() { scrolled = true; },
    setAttribute(name, value) { attributes.set(name, value); },
  };
  const form = {
    elements: { namedItem: (name) => name === "description" ? description : null },
    querySelectorAll: () => [],
    querySelector: () => null,
  };

  assert.equal(hooks.focusAttendanceValidationError(form, validationError), description);
  assert.equal(attributes.get("aria-invalid"), "true");
  assert.equal(focused, true);
  assert.equal(scrolled, true);
});

test("RPC de atualização recebe todos os campos mutáveis e o expected_updated_at", () => {
  const submitted = {
    professionalName: "Ana",
    attendedOn: "2026-09-01",
    customerName: "Cliente",
    phone: "11999999999",
    cpf: "529.982.247-25",
    description: "Descrição atualizada",
    tag: "purchase",
    serviceValue: 25.5,
    purchaseValue: 300,
    serviceOrder: "OS-20",
    serviceOrders: [{ service_order: "OS-20", amount: 300 }],
  };
  const args = hooks.attendanceUpdateArgs({
    id: "attendance-3",
    storeId: "store-3",
    expectedUpdatedAt: "2026-09-01T18:00:00Z",
  }, submitted);

  assert.deepEqual(plain(args), {
    p_attendance_id: "attendance-3",
    p_store_id: "store-3",
    p_expected_updated_at: "2026-09-01T18:00:00Z",
    p_professional_name: "Ana",
    p_attended_on: "2026-09-01",
    p_customer_name: "Cliente",
    p_phone: "11999999999",
    p_cpf: "529.982.247-25",
    p_description: "Descrição atualizada",
    p_tag: "purchase",
    p_service_value: 25.5,
    p_service_orders: [{ service_order: "OS-20", amount: 300 }],
  });

  const nonPurchase = hooks.attendanceUpdateArgs(
    { id: "attendance-3", storeId: "store-3", expectedUpdatedAt: "token" },
    { ...submitted, tag: "budget" },
  );
  assert.deepEqual(plain(nonPurchase.p_service_orders), []);

  const nullService = hooks.attendanceUpdateArgs(
    { id: "attendance-3", storeId: "store-3", expectedUpdatedAt: "token" },
    { ...submitted, tag: "budget", serviceValue: null },
  );
  assert.equal(nullService.p_service_value, null);
});

test("retorno da edição substitui o card imediatamente sem cruzar lojas", () => {
  const original = [
    { id: "attendance-4", storeId: "store-4", customerName: "Antes", updatedAt: "old" },
    { id: "attendance-5", storeId: "store-4", customerName: "Outro" },
  ];
  const updated = { id: "attendance-4", storeId: "store-4", customerName: "Depois", updatedAt: "new" };
  const replaced = hooks.replaceAttendanceRecord(original, updated, {
    recordId: "attendance-4",
    storeId: "store-4",
  });

  assert.notEqual(replaced, original);
  assert.deepEqual(plain(replaced[0]), updated);
  assert.equal(replaced[1], original[1]);
  assert.equal(hooks.replaceAttendanceRecord(original, { ...updated, storeId: "store-99" }, {
    recordId: "attendance-4",
    storeId: "store-4",
  }), original);
});

test("feedback respeita mensagem e marcadores de replay/no-op do backend", () => {
  const feedback = hooks.normalizeSaveFeedback({
    message: "Esta atualização já havia sido salva; nada foi duplicado.",
    updated: false,
    edit_replay: true,
    attendance: {
      id: "attendance-6",
      store_id: "store-6",
      professional_name: "Ana",
      service_value: null,
      updated_at: "2026-09-01T20:00:00Z",
    },
  }, { professionalName: "Ana" });

  assert.equal(feedback.editReplay, true);
  assert.equal(feedback.updated, false);
  assert.equal(feedback.attendance.serviceValue, null);
  assert.equal(hooks.attendanceUpdateFeedbackMessage(feedback), feedback.message);
  assert.equal(hooks.attendanceUpdateFeedbackMessage({ editReplay: true }), "Esta atualização já havia sido salva; nada foi duplicado.");
  assert.equal(hooks.attendanceUpdateFeedbackMessage({ updated: false }), "Nenhuma alteração foi necessária.");
});

test("confirma a resposta autoritativa sem perder precisão de centavos", () => {
  const submitted = {
    attendedOn: "2026-08-31",
    professionalName: "João Silva",
    tag: "purchase",
    purchaseValue: 1234.56,
  };
  const raw = {
    attendance: {
      id: "attendance-authoritative-ok",
      attended_on: "2026-08-31",
      professional_name: "  JOAO SILVA  ",
      tag: "venda",
      purchase_value: "1234.56",
    },
  };
  const feedback = hooks.normalizeSaveFeedback(raw, submitted);
  const verification = hooks.verifyAttendanceAuthoritativeResponse(raw, feedback, submitted);

  assert.equal(verification.ok, true);
  assert.deepEqual(plain(verification.mismatches), []);
  assert.equal(verification.message, "");
  assert.equal(verification.attendance.id, "attendance-authoritative-ok");
});

test("bloqueia sucesso quando o banco devolve data ou dados comerciais diferentes", () => {
  const submitted = {
    attendedOn: "2026-08-31",
    professionalName: "Ana",
    tag: "purchase",
    purchaseValue: 1200,
  };
  const raw = {
    attendance: {
      id: "attendance-authoritative-mismatch",
      attended_on: "2026-09-01",
      professional_name: "Bia",
      tag: "budget",
      purchase_value: 1200.01,
    },
  };
  const feedback = hooks.normalizeSaveFeedback(raw, submitted);
  const verification = hooks.verifyAttendanceAuthoritativeResponse(raw, feedback, submitted);

  assert.equal(verification.ok, false);
  assert.deepEqual(plain(verification.mismatches.map((item) => item.field)), [
    "attended_on",
    "professional_name",
    "tag",
    "purchase_value",
  ]);
  assert.match(verification.message, /data do atendimento/);
  assert.match(verification.message, /atendente/);
  assert.match(verification.message, /classificação/);
  assert.match(verification.message, /valor da compra/);
  assert.match(verification.message, /tela foi atualizada/i);
});

test("compra com múltiplas OS exige confirmação autoritativa da composição", () => {
  const submitted = {
    attendedOn: "2026-09-15",
    professionalName: "Ana",
    tag: "purchase",
    purchaseValue: 300,
    serviceOrders: [
      { service_order: "OS-1", amount: 100 },
      { service_order: "OS-2", amount: 200 },
    ],
  };
  const missingOrders = {
    attendance: {
      id: "attendance-missing-orders",
      attended_on: "2026-09-15",
      professional_name: "Ana",
      tag: "purchase",
      purchase_value: 300,
    },
  };
  const feedback = hooks.normalizeSaveFeedback(missingOrders, submitted);
  const verification = hooks.verifyAttendanceAuthoritativeResponse(missingOrders, feedback, submitted);

  assert.equal(verification.ok, false);
  assert.deepEqual(plain(verification.mismatches.map((item) => item.field)), ["service_orders"]);
  assert.match(verification.message, /ordens de serviço/i);
});

test("exige data autoritativa e compara os demais campos somente quando retornados", () => {
  const submitted = {
    attendedOn: "2026-08-31",
    professionalName: "Ana",
    tag: "purchase",
    purchaseValue: 500,
  };
  const onlyDate = { attendance: { attended_on: "2026-08-31" } };
  assert.equal(hooks.verifyAttendanceAuthoritativeResponse(
    onlyDate,
    hooks.normalizeSaveFeedback(onlyDate, submitted),
    submitted,
  ).ok, true);

  const timestampDate = { attendance: { attended_at: "2026-09-01T02:30:00Z" } };
  assert.equal(hooks.verifyAttendanceAuthoritativeResponse(
    timestampDate,
    hooks.normalizeSaveFeedback(timestampDate, submitted),
    submitted,
  ).ok, true);

  const missingDate = { attendance: { professional_name: "Ana" } };
  const missingVerification = hooks.verifyAttendanceAuthoritativeResponse(
    missingDate,
    hooks.normalizeSaveFeedback(missingDate, submitted),
    submitted,
  );
  assert.equal(missingVerification.ok, false);
  assert.deepEqual(plain(missingVerification.mismatches.map((item) => item.field)), ["attended_on"]);
});

test("conflito otimista reconhece a mensagem exata emitida pelo SQL", () => {
  assert.equal(hooks.isAttendanceEditConflict({
    message: "Este atendimento foi alterado em outra tela. Atualize a listagem antes de tentar novamente.",
  }), true);
  assert.equal(hooks.isAttendanceEditConflict({ message: "Falha transitória de rede." }), false);
});

test("contrato e markup expõem edição dedicada sem fallback destrutivo", () => {
  const contract = window.AttendancesModule.getIntegrationContract();
  assert.equal(contract.version, 7);
  assert.equal(contract.rpc.update.name, "lc_update_attendance_v2");
  assert.equal(contract.rpc.save.name, "lc_upsert_attendance_v4");
  assert.equal(contract.rpc.list.name, "lc_list_attendances_v4");
  assert.equal(contract.rpc.cancel.name, "lc_cancel_attendance_v1");
  assert.equal(contract.rpc.update.args.p_expected_updated_at.startsWith("timestamptz"), true);
  assert.match(source, /data-attendance-action="edit-attendance"/);
  assert.match(source, /data-attendance-action="open-attendance-cancel"/);
  assert.match(source, /data-attendance-cancel-dialog/);
  assert.match(source, /data-attendance-action="add-service-order"/);
  assert.match(source, /p_service_orders:/);
  assert.match(source, /state\.cancelReason = target\.value/);
  assert.match(source, /\|\| Boolean\(state\.cancelingRecordId\)/);
  assert.match(source, /state\.generation \+= 1;\s+state\.listGeneration \+= 1;\s+state\.listLoading = false;\s+const replaceOptions = \{ recordId: cancelContext\.id/);
  assert.match(source, /data-attendance-edit-form/);
  assert.match(source, /A atualização do banco que libera a edição ainda não foi aplicada/);
  assert.match(source, /inert aria-hidden="true"/);
  assert.match(source, /id="attendanceEditError"/);
  assert.match(source, /aria-live="assertive"/);
  assert.equal((source.match(/const feedback = normalizeSaveFeedback\(raw, submitted\);\s+const authoritativeResponse = verifyAttendanceAuthoritativeResponse\(raw, feedback, submitted\);/g) || []).length, 2);
  assert.match(source, /if \(!authoritativeResponse\.ok\)[\s\S]*?await loadWorkspace\(\{ quiet: true \}\);/);
  assert.match(styles, /\.attendance-record\.is-canceled[\s\S]*?--att-danger/);
  assert.match(styles, /\.attendance-service-order-row[\s\S]*?grid-template-columns/);
  assert.match(styles, /\.attendance-card-action--cancel/);
});

test("rodapé da edição mantém ações alinhadas, com mesma altura e ícone", () => {
  assert.match(source, /class="attendance-secondary-button"[^>]*>Cancelar<\/button>/);
  assert.match(source, /class="attendance-button-idle"><i class="fa-solid fa-check" aria-hidden="true"><\/i>Salvar alterações<\/span>/);
  assert.match(styles, /\.attendance-edit-footer \.attendance-secondary-button,[\s\S]*?height: 44px;[\s\S]*?min-height: 44px;[\s\S]*?margin: 0;/);
  assert.match(styles, /\.attendance-edit-footer \.attendance-button-idle \{[\s\S]*?display: inline-flex;[\s\S]*?align-items: center;[\s\S]*?gap: 7px;/);
});
