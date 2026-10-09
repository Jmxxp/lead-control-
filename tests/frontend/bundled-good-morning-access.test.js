"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const appSource = readFileSync(require.resolve("../../assets/js/app.js"), "utf8");
const indexSource = readFileSync(require.resolve("../../index.html"), "utf8");
const plain = (value) => JSON.parse(JSON.stringify(value));

function functionSource(name) {
  const declaration = new RegExp(`^(?:async )?function ${name}\\(`, "m");
  const start = appSource.search(declaration);
  assert.ok(start >= 0, `função ${name} deve existir para testar o fluxo real`);
  const remaining = appSource.slice(start);
  const next = remaining.slice(1).search(/^(?:async )?function \w+\(/m);
  return next < 0 ? remaining : remaining.slice(0, next + 1);
}

function harness(names, dependencies = {}) {
  const context = {
    firstRow: (value) => Array.isArray(value) ? value[0] : value,
    moduleAccessContractVersion: 1,
    ...dependencies,
  };
  vm.createContext(context);
  vm.runInContext(names.map(functionSource).join("\n"), context, { filename: "assets/js/app.js" });
  return context;
}

function entitlementHarness() {
  return harness([
    "includesGoodMorningSellerInPremium",
    "normalizeProspectionEntitlements",
    "applyProspectionEntitlements",
  ], {
    stores: ["leads", "prospection", "attendance", "both", "absent"].map((id) => ({ id })),
    technicians: [{ id: "agency" }],
  });
}

test("contrato v3 inclui Bom Dia somente nas lojas com Atendimento, mesmo com flags antigas divergentes", () => {
  const context = entitlementHarness();
  context.applyProspectionEntitlements({
    profile: { module_access_version: 3, good_morning_included_in_premium: true },
    stores: [
      { store_id: "leads", lead_enabled: true, attendance_enabled: false, good_morning_seller_enabled: true },
      { store_id: "prospection", prospection_enabled: true, attendance_enabled: false, good_morning_seller_enabled: true },
      { store_id: "attendance", attendance_enabled: true, good_morning_seller_enabled: false },
      { store_id: "both", prospection_enabled: true, attendance_enabled: true },
    ],
    technicians: [{ technician_id: "agency", prospection_store_limit: 4, prospection_store_count: 3,
      good_morning_seller_store_limit: 0, good_morning_seller_store_count: 99 }],
  });

  assert.equal(context.moduleAccessContractVersion, 3);
  assert.equal(context.includesGoodMorningSellerInPremium(), true);
  assert.deepEqual(plain(context.stores.map((store) => ({
    id: store.id,
    lead: store.leadEnabled,
    prospection: store.prospectionEnabled,
    attendance: store.attendanceEnabled,
    morning: store.goodMorningSellerEnabled,
  }))), [
    { id: "leads", lead: true, prospection: false, attendance: false, morning: false },
    { id: "prospection", lead: false, prospection: true, attendance: false, morning: false },
    { id: "attendance", lead: false, prospection: false, attendance: true, morning: true },
    { id: "both", lead: false, prospection: true, attendance: true, morning: true },
    { id: "absent", lead: false, prospection: false, attendance: false, morning: false },
  ]);
  assert.equal(context.technicians[0].prospectionStoreCount, 3);
  assert.equal(context.technicians[0].prospectionStoreLimit, 4);
});

test("banco v2 preserva autorização antiga e nunca libera Bom Dia sem Atendimento", () => {
  const context = entitlementHarness();
  context.applyProspectionEntitlements({
    profile: { module_access_version: 2 },
    stores: [
      { store_id: "leads", lead_enabled: true, attendance_enabled: false, good_morning_seller_enabled: true },
      { store_id: "attendance", attendance_enabled: true, good_morning_seller_enabled: false },
      { store_id: "both", attendance_enabled: true, good_morning_seller_enabled: true },
    ],
  });

  assert.equal(context.moduleAccessContractVersion, 2);
  assert.equal(context.includesGoodMorningSellerInPremium(), false);
  assert.equal(context.stores.find((store) => store.id === "leads").goodMorningSellerEnabled, false);
  assert.equal(context.stores.find((store) => store.id === "attendance").goodMorningSellerEnabled, false);
  assert.equal(context.stores.find((store) => store.id === "both").goodMorningSellerEnabled, true);
});

test("fallback v1 mantém módulos combinados e exige a autorização antiga do Bom Dia", () => {
  const context = entitlementHarness();
  context.applyProspectionEntitlements({
    stores: [
      { store_id: "prospection", prospection_enabled: true, good_morning_seller_enabled: false },
      { store_id: "both", prospection_enabled: true, good_morning_seller_enabled: true },
      { store_id: "leads", prospection_enabled: false, good_morning_seller_enabled: true },
    ],
  });

  assert.equal(context.moduleAccessContractVersion, 1);
  assert.equal(context.stores.find((store) => store.id === "prospection").attendanceEnabled, true);
  assert.equal(context.stores.find((store) => store.id === "prospection").goodMorningSellerEnabled, false);
  assert.equal(context.stores.find((store) => store.id === "both").goodMorningSellerEnabled, true);
  assert.equal(context.stores.find((store) => store.id === "leads").goodMorningSellerEnabled, false);
});

test("recarregar um contrato antigo revoga a disponibilidade incluída do contrato v3", () => {
  const context = entitlementHarness();
  context.applyProspectionEntitlements({
    profile: { module_access_version: 3 },
    stores: [{ store_id: "attendance", attendance_enabled: true }],
  });
  assert.equal(context.stores.find((store) => store.id === "attendance").goodMorningSellerEnabled, true);

  context.applyProspectionEntitlements({
    profile: { module_access_version: 2 },
    stores: [{ store_id: "attendance", attendance_enabled: true, good_morning_seller_enabled: false }],
  });
  assert.equal(context.moduleAccessContractVersion, 2);
  assert.equal(context.stores.find((store) => store.id === "attendance").goodMorningSellerEnabled, false);
});

test("salvar a loja v3 não envia flag própria Bom Dia e no v2 preserva somente o acesso já autorizado", async () => {
  for (const [version, currentMorning, attendance, expectedMorning] of [
    [3, false, true, undefined],
    [2, false, true, false],
    [2, true, true, true],
    [2, true, false, false],
  ]) {
    const calls = [];
    const context = harness([
      "includesGoodMorningSellerInPremium",
      "assertLegacyModuleSelection",
      "updateStoreWithCompatibleModuleAccess",
    ], {
      moduleAccessContractVersion: version,
      stores: [{ id: "target", goodMorningSellerEnabled: currentMorning }],
      authenticatedRpc: async (name, args) => { calls.push({ name, args: plain(args) }); return {}; },
      isMissingRpcError: () => false,
    });
    await context.updateStoreWithCompatibleModuleAccess({
      storeId: "target", name: "Loja", nick: "loja", password: null,
      technicianId: "agency", leadEnabled: true, prospectionEnabled: false,
      attendanceEnabled: attendance,
    });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].name, "lc_update_store_with_module_access_v2");
    assert.equal(calls[0].args.p_attendance_enabled, attendance);
    assert.equal(calls[0].args.p_good_morning_seller_enabled, expectedMorning);
    if (version >= 3) assert.equal(Object.hasOwn(calls[0].args, "p_good_morning_seller_enabled"), false);
  }
});

test("RPC independente ausente não promove Atendimento ou Bom Dia pelo fallback legado", async () => {
  const calls = [];
  const context = harness([
    "includesGoodMorningSellerInPremium",
    "assertLegacyModuleSelection",
    "updateStoreWithCompatibleModuleAccess",
  ], {
    moduleAccessContractVersion: 2,
    stores: [{ id: "target", goodMorningSellerEnabled: false }],
    authenticatedRpc: async (name) => { calls.push(name); throw Object.assign(new Error("RPC ausente"), { code: "PGRST202" }); },
    isMissingRpcError: (error) => error.code === "PGRST202",
  });
  await assert.rejects(context.updateStoreWithCompatibleModuleAccess({
    storeId: "target", name: "Loja", nick: "loja", password: null,
    technicianId: "agency", leadEnabled: true, prospectionEnabled: false, attendanceEnabled: true,
  }), /Prospecção e Atendimento.*pendente/);
  assert.deepEqual(calls, ["lc_update_store_with_module_access_v2"]);
  assert.equal(context.moduleAccessContractVersion, 1);
});

function control(checked = false) {
  return { checked, disabled: false, dataset: {}, classList: { toggle() {} } };
}

function quotaHarness({ existingProspection = false, existingAttendance = false,
  requestedProspection = false, requestedAttendance = false, inUse = 5, limit = 5 } = {}) {
  return harness([
    "includesGoodMorningSellerInPremium",
    "additionalAttendanceFeaturesHelp",
    "syncFeatureAccessStatus",
    "syncManagedAccountLeadToggle",
    "syncManagedAccountProspectionToggle",
    "syncManagedAccountAttendanceToggle",
    "syncManagedStoreEntitlementQuotas",
  ], {
    moduleAccessContractVersion: 3,
    currentProfile: { role: "admin", id: "admin" },
    managedAccountType: { value: "store" },
    managedAccountId: { value: "target" },
    stores: [{ id: "target", agencyIds: ["agency"], prospectionEnabled: existingProspection,
      attendanceEnabled: existingAttendance, goodMorningSellerEnabled: false }],
    technicians: [{ id: "agency", fullName: "Agência", prospectionStoreCount: inUse,
      prospectionStoreLimit: limit, goodMorningSellerStoreCount: 99, goodMorningSellerStoreLimit: 0 }],
    managedAccountProspectionAccess: control(requestedProspection),
    managedAccountAttendanceAccess: control(requestedAttendance),
    managedAccountProspectionHelp: { textContent: "" },
    managedAccountAttendanceHelp: { textContent: "" },
    managedAccountProspectionStatus: { textContent: "", classList: { toggle() {} } },
    managedAccountAttendanceStatus: { textContent: "", classList: { toggle() {} } },
    managedAccountLeadAccess: null,
    managedAccountLeadStatus: null,
    managedAccountLeadHelp: null,
  });
}

test("ligar Atendimento em cliente já premium não consome outra licença nem consulta cota Bom Dia", () => {
  const context = quotaHarness({ existingProspection: true, requestedProspection: true, requestedAttendance: true });
  context.syncManagedStoreEntitlementQuotas();
  assert.equal(context.managedAccountAttendanceAccess.disabled, false);
  assert.equal(context.managedAccountProspectionAccess.disabled, false);
  assert.match(context.managedAccountAttendanceHelp.textContent, /^5 de 5 licenças compartilhadas/);
});

test("trocar Atendimento por Prospecção mantém um acesso premium, mesmo no limite contratado", () => {
  const context = quotaHarness({ existingAttendance: true, requestedProspection: true });
  context.syncManagedStoreEntitlementQuotas();
  assert.equal(context.managedAccountProspectionAccess.disabled, false);
  assert.equal(context.managedAccountAttendanceAccess.disabled, false);
  assert.match(context.managedAccountProspectionHelp.textContent, /^5 de 5 licenças compartilhadas/);
});

test("nova loja premium é bloqueada pela cota compartilhada e ambos módulos juntos contam uma vez", () => {
  const exhausted = quotaHarness();
  exhausted.syncManagedStoreEntitlementQuotas();
  assert.equal(exhausted.managedAccountProspectionAccess.disabled, true);
  assert.equal(exhausted.managedAccountAttendanceAccess.disabled, true);

  const available = quotaHarness({ requestedProspection: true, requestedAttendance: true, inUse: 4 });
  available.syncManagedStoreEntitlementQuotas();
  assert.equal(available.managedAccountProspectionAccess.disabled, false);
  assert.equal(available.managedAccountAttendanceAccess.disabled, false);
  assert.match(available.managedAccountAttendanceHelp.textContent, /^5 de 5 licenças compartilhadas/);
});

test("remover os dois módulos adicionais libera exatamente uma licença compartilhada", () => {
  const context = quotaHarness({ existingProspection: true, existingAttendance: true });
  context.syncManagedStoreEntitlementQuotas();
  assert.match(context.managedAccountProspectionHelp.textContent, /^4 de 5 licenças compartilhadas/);
  assert.match(context.managedAccountAttendanceHelp.textContent, /^4 de 5 licenças compartilhadas/);
});

test("criação de agência no contrato v3 salva somente limites total e de módulos adicionais", async () => {
  const calls = [];
  const context = harness(["includesGoodMorningSellerInPremium", "handleCreateTechnician"], {
    moduleAccessContractVersion: 3,
    currentProfile: { role: "admin" },
    technicianName: { value: "Agência" }, technicianNick: { value: "agencia" },
    technicianPassword: { value: "senha-de-teste" }, technicianStoreLimit: { value: "10" },
    technicianProspectionLimit: { value: "5" }, technicianAvatar: { files: [] },
    technicianAvatarPreview: {}, technicianForm: { reset() {} },
    normalizeNick: (value) => value,
    clearTechnicianMessage() {}, showTechnicianMessage() {}, setFormBusy() {},
    avatarFileToDataUrl: async () => null,
    setAvatarPreview() {}, setAvatarFileName() {}, refreshRemoteState: async () => {},
    renderAll() {}, closeAccountCreationModal() {}, readableError: (error) => { throw error; },
    authenticatedRpc: async (name, args) => { calls.push({ name, args: plain(args) }); return [{ id: "agency" }]; },
  });
  await context.handleCreateTechnician({ preventDefault() {} });
  assert.deepEqual(calls, [{
    name: "lc_create_technician_with_feature_plan",
    args: { p_full_name: "Agência", p_nick: "agencia", p_password: "senha-de-teste",
      p_store_limit: 10, p_prospection_limit: 5 },
  }]);
});

test("formulários e capacidade não oferecem licença ou franquia independente para Bom Dia", () => {
  ["technicianGoodMorningSellerLimit", "managedAccountGoodMorningSellerLimit",
    "managedAccountGoodMorningSellerAccess", "goodMorningSellerCapacityBadge"].forEach((id) => {
    assert.doesNotMatch(indexSource, new RegExp(`id=["']${id}["']`));
  });
  assert.match(indexSource, /id="technicianProspectionLimit"/);
  assert.match(indexSource, /id="managedAccountAttendanceAccess"/);

  const node = () => ({ hidden: false, textContent: "", innerHTML: "", style: {}, classList: { toggle() {} } });
  const context = harness(["renderClientCapacity"], {
    currentProfile: { role: "technician" }, activeTechnicianContext: null,
    getSelectedCapacityContext: () => ({ storeCount: 5, storeLimit: 10, prospectionStoreCount: 3, prospectionStoreLimit: 5 }),
    getDashboardStores: () => [], getCapacityPercent: () => 50, accountUsage: null,
    clientCapacityPanel: node(), clientCapacityEyebrow: node(), clientCapacityTitle: node(),
    clientCapacityHint: node(), clientCapacityProgress: node(), clientCapacityPercent: node(),
    featureCapacitySummary: node(), prospectionCapacityBadge: node(),
  });
  context.renderClientCapacity();
  assert.match(context.prospectionCapacityBadge.innerHTML, /3 de 5/);
  assert.match(context.prospectionCapacityBadge.innerHTML, /módulos adicionais/);
});
