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
    p_purchase_value: 300,
    p_service_order: "OS-20",
  });

  const nonPurchase = hooks.attendanceUpdateArgs(
    { id: "attendance-3", storeId: "store-3", expectedUpdatedAt: "token" },
    { ...submitted, tag: "budget" },
  );
  assert.equal(nonPurchase.p_purchase_value, null);
  assert.equal(nonPurchase.p_service_order, null);

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
  assert.equal(contract.version, 6);
  assert.equal(contract.rpc.update.name, "lc_update_attendance_v1");
  assert.equal(contract.rpc.update.args.p_expected_updated_at.startsWith("timestamptz"), true);
  assert.match(source, /data-attendance-action="edit-attendance"/);
  assert.match(source, /data-attendance-edit-form/);
  assert.match(source, /A atualização do banco que libera a edição ainda não foi aplicada/);
  assert.match(source, /inert aria-hidden="true"/);
  assert.match(source, /id="attendanceEditError"/);
  assert.match(source, /aria-live="assertive"/);
  assert.equal((source.match(/const feedback = normalizeSaveFeedback\(raw, submitted\);\s+const authoritativeResponse = verifyAttendanceAuthoritativeResponse\(raw, feedback, submitted\);/g) || []).length, 2);
  assert.match(source, /if \(!authoritativeResponse\.ok\)[\s\S]*?await loadWorkspace\(\{ quiet: true \}\);/);
});

test("rodapé da edição mantém ações alinhadas, com mesma altura e ícone", () => {
  assert.match(source, /class="attendance-secondary-button"[^>]*>Cancelar<\/button>/);
  assert.match(source, /class="attendance-button-idle"><i class="fa-solid fa-check" aria-hidden="true"><\/i>Salvar alterações<\/span>/);
  assert.match(styles, /\.attendance-edit-footer \.attendance-secondary-button,[\s\S]*?height: 44px;[\s\S]*?min-height: 44px;[\s\S]*?margin: 0;/);
  assert.match(styles, /\.attendance-edit-footer \.attendance-button-idle \{[\s\S]*?display: inline-flex;[\s\S]*?align-items: center;[\s\S]*?gap: 7px;/);
});
