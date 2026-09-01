(function registerAttendancesModule(global) {
  "use strict";

  const DEFAULT_RPC = Object.freeze({
    workspace: "lc_get_attendance_workspace",
    save: "lc_upsert_attendance_v3",
    saveLegacy: "lc_upsert_attendance_v2",
    list: "lc_list_attendances_v3",
    analysis: "lc_get_attendance_analysis_v1",
    morningWorkspace: "lc_get_good_morning_seller_workspace",
    morningSave: "lc_save_good_morning_seller_settings",
    morningAdvance: "lc_advance_good_morning_seller_turn",
    morningParticipation: "lc_set_good_morning_seller_participation",
  });

  const TAGS = Object.freeze({
    budget: { label: "Orçamento", icon: "fa-file-invoice-dollar", tone: "emerald" },
    purchase: { label: "Compra", icon: "fa-bag-shopping", tone: "forest" },
    other: { label: "Outro", icon: "fa-ellipsis", tone: "sage" },
  });

  const state = {
    root: null,
    bridge: {},
    active: false,
    view: "operations",
    loading: false,
    saving: false,
    generation: 0,
    listGeneration: 0,
    contextGeneration: 0,
    pendingSave: null,
    selectedStoreId: "",
    stores: [],
    records: [],
    listRecords: [],
    listTotal: 0,
    listHasMore: false,
    listLoading: false,
    listLoaded: false,
    listError: "",
    listSource: "workspace",
    listSearchTimer: 0,
    professionals: [],
    morning: null,
    morningGeneration: 0,
    morningLoading: false,
    morningSaving: false,
    morningParticipationSaving: "",
    morningError: "",
    morningConfigOpen: false,
    morningConfigGeneration: 0,
    morningDraft: null,
    legacyAttendanceSaveRequired: false,
    serverMetrics: {},
    feedback: null,
    loadError: "",
    idempotencyKey: "",
    idempotencyFingerprint: "",
    drafts: new Map(),
    filtersOpen: false,
    filters: {
      search: "",
      tag: "all",
      professional: "all",
      period: "30d",
      link: "all",
    },
  };
  const embeddedAnalysisStates = new WeakMap();
  const EMBEDDED_ANALYSIS_PAGE_SIZE = 200;
  const EMBEDDED_EXPORT_MAX_RECORDS = 50000;

  const escapeHtml = (value) => String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");

  const normalizeText = (value) => String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();

  const onlyDigits = (value) => String(value ?? "").replace(/\D/g, "");

  function formatCpf(value) {
    const digits = onlyDigits(value).slice(0, 11);
    return digits
      .replace(/^(\d{3})(\d)/, "$1.$2")
      .replace(/^(\d{3})\.(\d{3})(\d)/, "$1.$2.$3")
      .replace(/\.(\d{3})(\d)/, ".$1-$2");
  }

  function isValidCpf(value) {
    const digits = onlyDigits(value);
    if (digits.length !== 11 || /^(\d)\1{10}$/.test(digits)) return false;
    const digit = (length) => {
      let total = 0;
      for (let index = 0; index < length; index += 1) total += Number(digits[index]) * (length + 1 - index);
      const remainder = (total * 10) % 11;
      return remainder === 10 ? 0 : remainder;
    };
    return digit(9) === Number(digits[9]) && digit(10) === Number(digits[10]);
  }

  const firstDefined = (...values) => values.find((value) => value !== undefined && value !== null);

  function getRole() {
    return normalizeText(state.bridge?.profile?.role);
  }

  function isStoreRole() {
    return ["store", "client", "cliente", "loja"].includes(getRole());
  }

  function isAgencyRole() {
    return ["technician", "agency", "agencia", "tecnico"].includes(getRole());
  }

  function isAdminRole() {
    return getRole() === "admin";
  }

  function canManageMorningSettings() {
    return isStoreRole()
      && selectedStore()?.goodMorningSellerEnabled === true
      && state.morning?.licensed === true
      && state.morning?.canManageSettings === true;
  }

  function canOpenMorningConfig() {
    return (isAdminRole() || isStoreRole())
      && selectedStore()?.goodMorningSellerEnabled === true
      && state.morning?.licensed === true;
  }

  function canManageMorningParticipation() {
    return canOpenMorningConfig()
      && state.morning?.participationControlAvailable === true
      && state.morning?.participationUpdateAvailable === true;
  }

  function invalidateMorningRequests() {
    state.morningGeneration += 1;
    state.morningLoading = false;
  }

  function clearMorningState({ loading = false } = {}) {
    invalidateMorningRequests();
    state.morning = null;
    state.morningLoading = loading === true;
    state.morningSaving = false;
    state.morningParticipationSaving = "";
    state.morningError = "";
    state.morningConfigOpen = false;
    state.morningConfigGeneration += 1;
    state.morningDraft = null;
  }

  function notify(message, type = "info") {
    if (!message) return;
    if (typeof state.bridge?.notify === "function") {
      state.bridge.notify(message, type);
    }
  }

  function readableError(error) {
    const source = error?.message || error?.error_description || error?.details || error || "Erro inesperado.";
    return String(source)
      .replace(/^Error:\s*/i, "")
      .replace(/app_private\./g, "")
      .trim();
  }

  function isEntitlementError(error) {
    const message = normalizeText(error?.message || error?.details || error || "");
    return /cliente nao encontrado ou sem permissao|acesso.*atend|atend.*(?:bloque|desativ|nao.*liberad|nao.*licenciad)|acesso.*prospecc|prospecc.*(?:bloque|desativ|nao.*liberad)/.test(message);
  }

  function handleEntitlementLoss(error, storeId = state.selectedStoreId) {
    if (!isEntitlementError(error)) return false;
    const revokedStore = (state.bridge?.stores || []).find((store) => String(firstDefined(store.id, store.store_id, "")) === String(storeId || ""));
    if (revokedStore) {
      revokedStore.attendanceEnabled = false;
      revokedStore.attendance_enabled = false;
    }
    state.bridge?.onAccessRevoked?.(String(storeId || ""));
    state.generation += 1;
    state.listGeneration += 1;
    state.contextGeneration += 1;
    state.loading = false;
    state.saving = false;
    state.pendingSave = null;
    state.records = [];
    state.listRecords = [];
    state.listTotal = 0;
    state.listHasMore = false;
    state.listLoading = false;
    state.listLoaded = false;
    state.listError = "";
    state.listSource = "workspace";
    if (state.listSearchTimer) global.clearTimeout(state.listSearchTimer);
    state.listSearchTimer = 0;
    state.professionals = [];
    clearMorningState();
    state.serverMetrics = {};
    state.feedback = null;
    state.loadError = "";
    state.idempotencyKey = "";
    state.idempotencyFingerprint = "";
    if (storeId) state.drafts.delete(String(storeId));
    syncContext({ preserveSelection: false });
    renderWorkspace();
    notify("A licença de Atendimentos deste cliente foi desativada. Reative o acesso para continuar.", "warning");
    return true;
  }

  function normalizeMoney(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : 0;
    let source = String(value ?? "").replace(/[^\d,.-]/g, "").trim();
    if (!source) return 0;
    if (source.includes(",") && source.includes(".")) source = source.replace(/\./g, "").replace(",", ".");
    else if (source.includes(",")) source = source.replace(",", ".");
    const number = Number(source);
    return Number.isFinite(number) ? Math.round(number * 100) / 100 : 0;
  }

  function formatCurrency(value) {
    return new Intl.NumberFormat("pt-BR", {
      style: "currency",
      currency: "BRL",
      maximumFractionDigits: 2,
    }).format(Number(value || 0));
  }

  function formatPhone(value) {
    const digits = onlyDigits(value).slice(0, 13);
    const local = digits.startsWith("55") && digits.length > 11 ? digits.slice(2) : digits;
    if (local.length <= 2) return local;
    if (local.length <= 6) return `(${local.slice(0, 2)}) ${local.slice(2)}`;
    if (local.length <= 10) return `(${local.slice(0, 2)}) ${local.slice(2, 6)}-${local.slice(6)}`;
    return `(${local.slice(0, 2)}) ${local.slice(2, 7)}-${local.slice(7, 11)}`;
  }

  function formatDateTime(value) {
    if (!value) return "Data não informada";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "Data não informada";
    return new Intl.DateTimeFormat("pt-BR", {
      day: "2-digit",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    }).format(date).replace(" de ", " ");
  }

  function parseIsoDateParts(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ""));
    if (!match) return null;
    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    const date = new Date(Date.UTC(year, month - 1, day));
    if (
      Number.isNaN(date.getTime())
      || date.getUTCFullYear() !== year
      || date.getUTCMonth() !== month - 1
      || date.getUTCDate() !== day
    ) return null;
    return { year, month, day, date };
  }

  function isoDateFromUtc(value) {
    const date = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return [
      String(date.getUTCFullYear()).padStart(4, "0"),
      String(date.getUTCMonth() + 1).padStart(2, "0"),
      String(date.getUTCDate()).padStart(2, "0"),
    ].join("-");
  }

  function attendanceDateLimits(reference = new Date()) {
    const today = embeddedDateInput(reference);
    if (!attendanceRetroactiveDatesGranted()) {
      return { min: today, today };
    }
    const parts = parseIsoDateParts(today);
    if (!parts) return { min: "", today };
    const minimumYear = parts.year - 2;
    const lastDayOfMinimumMonth = new Date(Date.UTC(minimumYear, parts.month, 0)).getUTCDate();
    const minimumDay = Math.min(parts.day, lastDayOfMinimumMonth);
    return {
      min: `${String(minimumYear).padStart(4, "0")}-${String(parts.month).padStart(2, "0")}-${String(minimumDay).padStart(2, "0")}`,
      today,
    };
  }

  function isValidAttendanceDate(value, limits = attendanceDateLimits()) {
    const date = String(value || "");
    return Boolean(parseIsoDateParts(date))
      && (!limits.min || date >= limits.min)
      && (!limits.today || date <= limits.today);
  }

  function attendanceRetroactiveDatesGranted() {
    return state.legacyAttendanceSaveRequired !== true
      && state.bridge?.attendanceRetroactiveDatesGranted !== false;
  }

  function safeImageUrl(value) {
    const source = String(value || "").trim();
    if (!source) return "";
    if (/^data:image\/(png|jpe?g|webp|gif|svg\+xml);/i.test(source)) return source;
    if (/^https?:\/\//i.test(source)) return source;
    if (/^(\.\/|\/|assets\/)/i.test(source)) return source;
    return "";
  }

  function normalizeTag(value) {
    const tag = normalizeText(value);
    if (["purchase", "compra", "comprou", "sale", "venda"].includes(tag)) return "purchase";
    if (["budget", "orcamento", "orçamento", "quote", "cotacao", "cotação"].includes(tag)) return "budget";
    return "other";
  }

  function normalizeBoolean(value) {
    if (typeof value === "boolean") return value;
    if (typeof value === "number") return value === 1;
    const normalized = normalizeText(value);
    if (["true", "sim", "yes", "1", "eligible", "elegivel"].includes(normalized)) return true;
    if (["false", "nao", "não", "no", "0", "ineligible", "inelegivel"].includes(normalized)) return false;
    return null;
  }

  function normalizeProfessional(source, index = 0) {
    if (typeof source === "string") return { id: source, name: source, active: true };
    return {
      id: String(firstDefined(source?.id, source?.professional_id, source?.professionalId, source?.name, index)),
      name: String(firstDefined(source?.name, source?.professional_name, source?.professionalName, source?.full_name, "Profissional")),
      active: normalizeBoolean(firstDefined(source?.active, source?.is_active, true)) !== false,
    };
  }

  function normalizeLink(raw, prefix) {
    const nestedValue = firstDefined(raw?.links?.[prefix], raw?.[prefix]);
    const objectValue = nestedValue && typeof nestedValue === "object" ? nestedValue : null;
    const id = firstDefined(
      objectValue?.id,
      objectValue?.record_id,
      objectValue?.recordId,
      raw?.[`${prefix}_id`],
      raw?.[`${prefix}Id`],
      raw?.[`linked_${prefix}_id`],
      raw?.[`linked${prefix[0].toUpperCase()}${prefix.slice(1)}Id`],
    );
    const explicit = firstDefined(
      objectValue?.linked,
      objectValue?.matched,
      objectValue?.found,
      typeof nestedValue === "boolean" ? nestedValue : undefined,
      raw?.[`linked_${prefix}`],
      raw?.[`is_linked_${prefix}`],
      raw?.[`has_${prefix}`],
    );
    const linked = Boolean(id || normalizeBoolean(explicit) === true);
    return {
      linked,
      id: id ? String(id) : "",
      name: String(firstDefined(objectValue?.name, objectValue?.customer_name, objectValue?.customerName, "")),
      ambiguous: normalizeBoolean(firstDefined(objectValue?.ambiguous, objectValue?.is_ambiguous)) === true,
      candidateCount: Number(firstDefined(objectValue?.candidate_count, objectValue?.candidateCount, objectValue?.candidates_count, 0)) || 0,
    };
  }

  function normalizeRecord(source = {}, index = 0) {
    const lead = normalizeLink(source, "lead");
    const prospection = normalizeLink(source, "prospection");
    const links = source.links && typeof source.links === "object" ? source.links : {};
    const createdAt = firstDefined(source.attended_at, source.attendedAt, source.created_at, source.createdAt, source.registered_at, source.registeredAt, source.date);
    return {
      id: String(firstDefined(source.id, source.attendance_id, source.attendanceId, `${createdAt || "attendance"}-${index}`)),
      storeId: String(firstDefined(source.store_id, source.storeId, state.selectedStoreId, "")),
      professionalId: String(firstDefined(source.professional_id, source.professionalId, "")),
      professionalName: String(firstDefined(source.professional_name, source.professionalName, source.performed_by, source.performedBy, "Não informado")),
      customerName: String(firstDefined(source.customer_name, source.customerName, source.client_name, source.clientName, source.name, "Cliente não informado")),
      phone: formatPhone(firstDefined(source.phone, source.customer_phone, source.customerPhone, source.telephone, "")),
      cpf: formatCpf(firstDefined(source.customer_cpf, source.cpf, source.customerCpf, "")),
      description: String(firstDefined(source.description, source.notes, source.observation, source.observations, "")),
      tag: normalizeTag(firstDefined(source.tag, source.attendance_tag, source.type, source.kind)),
      serviceValue: normalizeMoney(firstDefined(source.service_value, source.serviceValue, source.value, source.attendance_value, 0)),
      purchaseValue: normalizeMoney(firstDefined(source.purchase_value, source.purchaseValue, source.sale_value, source.saleValue, 0)),
      serviceOrder: String(firstDefined(source.service_order, source.serviceOrder, source.os, source.order_number, "")),
      createdAt: createdAt || "",
      linkedLead: lead,
      linkedProspection: prospection,
      ambiguous: normalizeBoolean(firstDefined(source.match_ambiguous, source.matchAmbiguous, links.ambiguous)) === true,
      prospectionProfessionalName: String(firstDefined(
        source.prospection_professional_name,
        source.prospectionProfessionalName,
        source.credited_professional_name,
        source.creditedProfessionalName,
        source.prospection_professional?.name,
        "",
      )),
      bonusEligible: normalizeBoolean(firstDefined(source.bonus_eligible, source.bonusEligible, source.is_bonus_eligible)),
      bonusAmount: firstDefined(source.bonus_awarded_amount, source.bonusAwardedAmount, source.bonus_amount, source.bonusAmount) == null
        ? null
        : normalizeMoney(firstDefined(source.bonus_awarded_amount, source.bonusAwardedAmount, source.bonus_amount, source.bonusAmount)),
      bonusReason: String(firstDefined(source.bonus_reason, source.bonusReason, source.bonus_credit_reason, source.bonusCreditReason, source.bonus_message, "")),
    };
  }

  function unwrapPayload(raw) {
    if (Array.isArray(raw)) {
      if (raw.length === 1 && raw[0] && typeof raw[0] === "object") {
        const row = raw[0];
        if (row.workspace || row.data || row.attendances || row.records || row.professionals || row.metrics) {
          return unwrapPayload(firstDefined(row.workspace, row.data, row));
        }
      }
      return { attendances: raw };
    }
    if (!raw || typeof raw !== "object") return {};
    if (raw.workspace && typeof raw.workspace === "object") return unwrapPayload(raw.workspace);
    if (raw.data && typeof raw.data === "object" && !raw.attendances && !raw.records) return unwrapPayload(raw.data);
    return raw;
  }

  function normalizeWorkspace(raw) {
    const payload = unwrapPayload(raw);
    const records = firstDefined(payload.attendances, payload.records, payload.items, payload.recent_attendances, []);
    const professionals = firstDefined(payload.professionals, payload.team, payload.staff, []);
    return {
      records: Array.isArray(records) ? records.map(normalizeRecord) : [],
      professionals: Array.isArray(professionals)
        ? professionals.map(normalizeProfessional).filter((item) => item.name)
        : [],
      metrics: payload.metrics && typeof payload.metrics === "object" ? payload.metrics : {},
    };
  }

  function normalizeStore(store = {}) {
    const technicianId = String(firstDefined(store.technicianId, store.technician_id, store.agencyId, store.agency_id, ""));
    const agencyIds = [...new Set([
      ...(Array.isArray(store.agencyIds) ? store.agencyIds : []),
      ...(Array.isArray(store.agency_ids) ? store.agency_ids : []),
      technicianId,
    ].map((id) => String(id || "")).filter(Boolean))];
    return {
      ...store,
      id: String(firstDefined(store.id, store.store_id, store.storeId, "")),
      name: String(firstDefined(store.name, store.store_name, store.storeName, store.username, "Cliente")),
      technicianId,
      agencyIds,
      avatarUrl: safeImageUrl(firstDefined(store.avatarUrl, store.avatar_url, store.logoUrl, store.logo_url, "")),
      attendanceEnabled: firstDefined(store.attendanceEnabled, store.attendance_enabled) === true,
      goodMorningSellerEnabled: firstDefined(store.goodMorningSellerEnabled, store.good_morning_seller_enabled) === true,
    };
  }

  function bridgeAttendanceAccessGranted(bridge = state.bridge) {
    return firstDefined(bridge?.attendanceAccessGranted, bridge?.prospectionAccessGranted, true) !== false;
  }

  function storeHasAgencyAccess(store, agencyId) {
    const normalizedAgencyId = String(agencyId || "");
    if (!store || !normalizedAgencyId) return false;
    return store.agencyIds?.includes(normalizedAgencyId) || store.technicianId === normalizedAgencyId;
  }

  function visibleStores() {
    if (!bridgeAttendanceAccessGranted()) return [];
    const profile = state.bridge?.profile || {};
    const all = (Array.isArray(state.bridge?.stores) ? state.bridge.stores : [])
      .map(normalizeStore)
      .filter((store) => store.id && store.attendanceEnabled === true);
    if (isStoreRole()) {
      const ownId = String(firstDefined(profile.storeId, profile.store_id, profile.id, ""));
      return all.filter((store) => store.id === ownId);
    }
    if (isAgencyRole()) {
      const agencyId = String(firstDefined(profile.id, profile.technicianId, profile.technician_id, ""));
      return agencyId ? all.filter((store) => storeHasAgencyAccess(store, agencyId)) : [];
    }
    const initialAgencyId = String(state.bridge?.initialAgencyId || "");
    if (initialAgencyId) return all.filter((store) => storeHasAgencyAccess(store, initialAgencyId));
    return all;
  }

  function syncContext({ preserveSelection = true } = {}) {
    const previous = preserveSelection ? state.selectedStoreId : "";
    state.stores = visibleStores();
    const validIds = new Set(state.stores.map((store) => store.id));
    const initial = String(state.bridge?.initialStoreId || "");
    const own = isStoreRole()
      ? String(firstDefined(state.bridge?.profile?.storeId, state.bridge?.profile?.store_id, state.bridge?.profile?.id, ""))
      : "";

    if (previous && validIds.has(previous)) state.selectedStoreId = previous;
    else if (own && validIds.has(own)) state.selectedStoreId = own;
    else if (initial && validIds.has(initial)) state.selectedStoreId = initial;
    else state.selectedStoreId = "";
  }

  function selectedStore() {
    return state.stores.find((store) => store.id === state.selectedStoreId) || null;
  }

  function hasUnlicensedStoreInScope() {
    const profile = state.bridge?.profile || {};
    const all = (Array.isArray(state.bridge?.stores) ? state.bridge.stores : []).map(normalizeStore).filter((store) => store.id);
    let scoped = all;
    if (isStoreRole()) {
      const ownId = String(firstDefined(profile.storeId, profile.store_id, profile.id, ""));
      scoped = all.filter((store) => store.id === ownId);
    } else if (isAgencyRole()) {
      const agencyId = String(firstDefined(profile.id, profile.technicianId, profile.technician_id, ""));
      scoped = all.filter((store) => storeHasAgencyAccess(store, agencyId));
    } else if (state.bridge?.initialAgencyId) {
      scoped = all.filter((store) => storeHasAgencyAccess(store, state.bridge.initialAgencyId));
    }
    return !bridgeAttendanceAccessGranted() || scoped.some((store) => store.attendanceEnabled !== true);
  }

  function resolveRoot(target) {
    if (target instanceof Element) return target;
    if (typeof target === "string") return document.querySelector(target);
    if (state.bridge?.root instanceof Element) return state.bridge.root;
    if (state.bridge?.mountTarget instanceof Element) return state.bridge.mountTarget;
    if (typeof state.bridge?.root === "string") return document.querySelector(state.bridge.root);
    if (typeof state.bridge?.mountTarget === "string") return document.querySelector(state.bridge.mountTarget);
    return document.querySelector("#attendanceView, [data-attendances-root]");
  }

  function initials(value) {
    return String(value || "CL")
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((part) => part.charAt(0).toUpperCase())
      .join("") || "CL";
  }

  function renderAvatar(store, className = "attendance-store-avatar") {
    if (store?.avatarUrl) {
      return `<span class="${className} has-image"><img src="${escapeHtml(store.avatarUrl)}" alt="Logo de ${escapeHtml(store.name)}" /></span>`;
    }
    return `<span class="${className} ${className}--fallback" aria-hidden="true">${escapeHtml(initials(store?.name))}</span>`;
  }

  function renderStoreHeader() {
    const store = selectedStore();
    const canChoose = !isStoreRole() && state.stores.length > 0;
    const selector = canChoose
      ? `<label class="attendance-store-picker">
          <span>Cliente em análise</span>
          <span class="attendance-select-wrap">
            <i class="fa-solid fa-building" aria-hidden="true"></i>
            <select data-attendance-store aria-label="Selecionar cliente">
              <option value="">Selecione um cliente</option>
              ${state.stores.map((item) => `<option value="${escapeHtml(item.id)}" ${item.id === state.selectedStoreId ? "selected" : ""}>${escapeHtml(item.name)}</option>`).join("")}
            </select>
          </span>
        </label>`
      : store
        ? `<div class="attendance-locked-store"><i class="fa-solid fa-lock" aria-hidden="true"></i><span>Ambiente exclusivo desta empresa</span></div>`
        : "";

    const viewSwitcher = store
      ? `<nav class="attendance-view-switcher" aria-label="Área de Atendimentos">
          <button type="button" data-attendance-action="view-operations" class="${state.view === "operations" ? "is-active" : ""}" aria-current="${state.view === "operations" ? "page" : "false"}"><i class="fa-solid fa-pen-to-square" aria-hidden="true"></i><span>Registros</span></button>
          <button type="button" data-attendance-action="view-analysis" class="${state.view === "analysis" ? "is-active" : ""}" aria-current="${state.view === "analysis" ? "page" : "false"}"><i class="fa-solid fa-chart-line" aria-hidden="true"></i><span>Análise</span></button>
        </nav>`
      : "";

    return `<header class="attendance-module-header">
      <div class="attendance-heading">
        ${renderAvatar(store || { name: "Atendimentos", avatarUrl: safeImageUrl(state.bridge?.profile?.avatarUrl) }, "attendance-heading-avatar")}
        <div>
          <p class="attendance-eyebrow">Operação comercial</p>
          <h1>${store ? escapeHtml(store.name) : "Atendimentos"}</h1>
          <p>${store ? state.view === "analysis" ? "Acompanhe conversão, resultados e desempenho individual da equipe." : "Registre o atendimento e preserve a origem comercial do cliente." : "Selecione uma empresa para trabalhar com dados totalmente isolados."}</p>
        </div>
      </div>
      <div class="attendance-header-actions">
        ${viewSwitcher}
        ${selector}
        <button class="attendance-icon-button" type="button" data-attendance-action="refresh" aria-label="Atualizar atendimentos" title="Atualizar">
          <i class="fa-solid fa-arrow-rotate-right" aria-hidden="true"></i>
        </button>
      </div>
    </header>`;
  }

  function renderNoStore() {
    const hasStores = state.stores.length > 0;
    const blockedByPlan = !hasStores && hasUnlicensedStoreInScope();
    return `<section class="attendance-context-empty" aria-live="polite">
      <span class="attendance-context-empty-icon"><i class="fa-solid ${hasStores ? "fa-arrow-pointer" : blockedByPlan ? "fa-lock" : "fa-building-circle-exclamation"}" aria-hidden="true"></i></span>
      <p class="attendance-eyebrow">Dados protegidos por cliente</p>
      <h2>${hasStores ? "Escolha uma empresa para começar" : blockedByPlan ? "Atendimentos não liberado" : "Nenhum cliente disponível"}</h2>
      <p>${hasStores
        ? "O painel só carrega um cliente por vez. Assim, atendimentos, profissionais e valores nunca são misturados entre empresas."
        : blockedByPlan
          ? "Nenhum cliente desta conta possui Atendimentos liberado. Ative esse acesso em Editar acesso para continuar."
          : "Sua conta ainda não possui uma empresa disponível para registrar atendimentos. Vincule um cliente e tente novamente."}</p>
    </section>`;
  }

  function renderLoading() {
    return `<section class="attendance-workspace-loading" role="status" aria-live="polite">
      <span class="attendance-spinner" aria-hidden="true"></span>
      <div><strong>Carregando atendimentos</strong><span>Buscando somente os dados de ${escapeHtml(selectedStore()?.name || "deste cliente")}.</span></div>
    </section>`;
  }

  function renderLoadError() {
    return `<section class="attendance-context-empty attendance-context-empty--error" role="alert">
      <span class="attendance-context-empty-icon"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span>
      <p class="attendance-eyebrow">Não foi possível carregar</p>
      <h2>O painel deste cliente está indisponível</h2>
      <p>${escapeHtml(state.loadError)}</p>
      <button class="attendance-secondary-button" type="button" data-attendance-action="refresh"><i class="fa-solid fa-arrow-rotate-right" aria-hidden="true"></i>Tentar novamente</button>
    </section>`;
  }

  function registeredProfessionalRecords() {
    const unique = new Map();
    state.professionals.forEach((professional) => unique.set(normalizeText(professional.name), professional));
    return [...unique.values()].sort((a, b) => Number(b.active) - Number(a.active) || a.name.localeCompare(b.name, "pt-BR"));
  }

  function registeredProfessionalOptions() {
    return registeredProfessionalRecords().map((professional) => professional.name);
  }

  function professionalOptions() {
    const unique = new Map(registeredProfessionalOptions().map((name) => [normalizeText(name), name]));
    [...state.records, ...state.listRecords].forEach((record) => {
      if (record.professionalName && record.professionalName !== "Não informado") unique.set(normalizeText(record.professionalName), record.professionalName);
    });
    return [...unique.values()].sort((a, b) => a.localeCompare(b, "pt-BR"));
  }

  function normalizeMorningWorkspace(raw) {
    const payload = unwrapPayload(raw);
    const goals = payload.goals && typeof payload.goals === "object" ? payload.goals : {};
    const normalizeGoal = (value) => ({
      target: normalizeMoney(value?.target),
      actual: normalizeMoney(value?.actual),
    });
    const professionals = Array.isArray(payload.professionals) ? payload.professionals : [];
    const hasParticipationField = professionals.some((professional) => (
      Object.prototype.hasOwnProperty.call(professional || {}, "good_morning_seller_enabled")
      || Object.prototype.hasOwnProperty.call(professional || {}, "goodMorningSellerEnabled")
    ));
    return {
      licensed: payload.licensed === true,
      configured: payload.configured === true,
      canManageSettings: firstDefined(
        payload.can_manage_settings,
        payload.canManageSettings,
        isStoreRole()
      ) === true,
      participationControlAvailable: firstDefined(
        payload.participation_control_available,
        payload.participationControlAvailable,
        hasParticipationField
      ) === true,
      participationUpdateAvailable: firstDefined(
        payload.participation_update_available,
        payload.participationUpdateAvailable,
        false
      ) === true,
      goalMonth: String(firstDefined(payload.goal_month, payload.goalMonth, "")),
      savedGoalMonth: String(firstDefined(payload.saved_goal_month, payload.savedGoalMonth, "")),
      allocationMode: String(firstDefined(payload.allocation_mode, payload.allocationMode, "equal")) === "custom" ? "custom" : "equal",
      monthlyGoal: normalizeMoney(firstDefined(payload.monthly_goal, payload.monthlyGoal, 0)),
      lastMonthlyGoal: normalizeMoney(firstDefined(payload.last_monthly_goal, payload.lastMonthlyGoal, payload.monthly_goal, 0)),
      today: String(firstDefined(payload.today, "")),
      weekStart: String(firstDefined(payload.week_start, payload.weekStart, "")),
      weekEnd: String(firstDefined(payload.week_end, payload.weekEnd, "")),
      workdaysInMonth: Number(firstDefined(payload.workdays_in_month, payload.workdaysInMonth, 0)) || 0,
      workdaysInWeek: Number(firstDefined(payload.workdays_in_week, payload.workdaysInWeek, 0)) || 0,
      todayIsWorkingDay: firstDefined(payload.today_is_working_day, payload.todayIsWorkingDay, false) === true,
      teamProfessionalCount: Number(firstDefined(
        payload.team_professional_count,
        payload.teamProfessionalCount,
        professionals.length
      )) || 0,
      eligibleProfessionalCount: Number(firstDefined(
        payload.eligible_professional_count,
        payload.eligibleProfessionalCount,
        professionals.filter((professional) => firstDefined(
          professional?.good_morning_seller_enabled,
          professional?.goodMorningSellerEnabled,
          professional?.enabled,
          true
        ) !== false).length
      )) || 0,
      goals: {
        today: normalizeGoal(goals.today),
        week: normalizeGoal(goals.week),
        month: normalizeGoal(goals.month),
      },
      currentProfessionalId: String(firstDefined(payload.current_professional_id, payload.currentProfessionalId, "")),
      professionals: professionals.map((professional, index) => {
        const goalToday = firstDefined(professional.goal_today, professional.goalToday);
        const goalWeek = firstDefined(professional.goal_week, professional.goalWeek);
        const goalMonth = firstDefined(professional.goal_month, professional.goalMonth, professional.goal_amount, professional.goalAmount);
        return {
          id: String(firstDefined(professional.id, professional.professional_id, "")),
          name: String(firstDefined(professional.name, professional.professional_name, "Vendedor")),
          active: firstDefined(professional.is_active, professional.active, true) !== false,
          enabled: firstDefined(
            professional.good_morning_seller_enabled,
            professional.goodMorningSellerEnabled,
            professional.enabled,
            true
          ) !== false,
          goalAmount: normalizeMoney(firstDefined(professional.goal_amount, professional.goalAmount, goalMonth, 0)),
          goalToday: normalizeMoney(firstDefined(goalToday, 0)),
          goalWeek: normalizeMoney(firstDefined(goalWeek, 0)),
          goalMonth: normalizeMoney(firstDefined(goalMonth, 0)),
          hasPeriodGoals: goalToday != null && goalWeek != null && goalMonth != null,
          queuePosition: Number(firstDefined(professional.queue_position, professional.queuePosition, index + 1)) || index + 1,
          current: firstDefined(professional.is_current, professional.current, false) === true,
          actualMonth: normalizeMoney(firstDefined(professional.actual_month, professional.actualMonth, 0)),
          actualWeek: normalizeMoney(firstDefined(professional.actual_week, professional.actualWeek, 0)),
          actualToday: normalizeMoney(firstDefined(professional.actual_today, professional.actualToday, 0)),
        };
      }).filter((professional) => professional.id && professional.active)
        .sort((a, b) => a.queuePosition - b.queuePosition || a.name.localeCompare(b.name, "pt-BR")),
    };
  }

  function goalProgress(actual, target) {
    if (target <= 0) return 0;
    return Math.min(Math.max(Math.round((actual / target) * 100), 0), 100);
  }

  function formatShortDate(value) {
    if (!value) return "";
    const date = new Date(`${value}T12:00:00`);
    if (Number.isNaN(date.getTime())) return "";
    return new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "short" }).format(date).replace(" de ", " ");
  }

  function calculateEqualSellerGoals(goal, count) {
    if (!count) return [];
    const cents = Math.max(Math.round(Number(goal || 0) * 100), 0);
    const base = Math.floor(cents / count);
    const remainder = cents % count;
    return Array.from({ length: count }, (_, index) => (base + (index < remainder ? 1 : 0)) / 100);
  }

  function morningParticipants(professionals = []) {
    return professionals.filter((professional) => professional.enabled !== false);
  }

  function applyEqualMorningGoals(draft) {
    if (!draft) return;
    const participants = morningParticipants(draft.professionals);
    const goals = calculateEqualSellerGoals(draft.monthlyGoal, participants.length);
    let participantIndex = 0;
    draft.professionals.forEach((professional) => {
      if (professional.enabled === false) {
        professional.goalAmount = 0;
        return;
      }
      professional.goalAmount = goals[participantIndex] || 0;
      participantIndex += 1;
    });
  }

  function createMorningDraft() {
    const morning = state.morning;
    if (!morning) return null;
    const professionals = morning.professionals.map((professional) => ({
      id: professional.id,
      name: professional.name,
      enabled: professional.enabled !== false,
      goalAmount: professional.goalAmount,
    }));
    const monthlyGoal = morning.configured ? morning.monthlyGoal : morning.lastMonthlyGoal;
    const mode = morning.allocationMode || "equal";
    const draft = { monthlyGoal, mode, professionals };
    if (mode === "equal") applyEqualMorningGoals(draft);
    return draft;
  }

  function cloneMorningDraft(draft) {
    if (!draft) return null;
    return {
      monthlyGoal: normalizeMoney(draft.monthlyGoal),
      mode: draft.mode === "custom" ? "custom" : "equal",
      professionals: draft.professionals.map((professional) => ({
        id: professional.id,
        name: professional.name,
        enabled: professional.enabled !== false,
        goalAmount: normalizeMoney(professional.goalAmount),
      })),
    };
  }

  function mergeMorningDraftWithWorkspace(draft, morning) {
    if (!draft || !morning) return createMorningDraft();
    const previousById = new Map(draft.professionals.map((professional) => [professional.id, professional]));
    const merged = {
      monthlyGoal: normalizeMoney(draft.monthlyGoal),
      mode: draft.mode === "custom" ? "custom" : "equal",
      professionals: morning.professionals.map((professional) => {
        const previous = previousById.get(professional.id);
        return {
          id: professional.id,
          name: professional.name,
          enabled: professional.enabled !== false,
          goalAmount: normalizeMoney(previous?.goalAmount ?? professional.goalAmount),
        };
      }),
    };
    if (merged.mode === "equal") applyEqualMorningGoals(merged);
    return merged;
  }

  function morningQueue() {
    const professionals = morningParticipants(state.morning?.professionals || []);
    if (!professionals.length) return [];
    const currentIndex = professionals.findIndex((professional) => professional.current || professional.id === state.morning.currentProfessionalId);
    if (currentIndex <= 0) return professionals;
    return [...professionals.slice(currentIndex), ...professionals.slice(0, currentIndex)];
  }

  function morningWorkingDayContext() {
    const parsedToday = parseIsoDateParts(state.morning?.today);
    if (!parsedToday) return null;
    const today = parsedToday.date;
    const monthStart = new Date(Date.UTC(parsedToday.year, parsedToday.month - 1, 1));
    const monthEnd = new Date(Date.UTC(parsedToday.year, parsedToday.month, 0));
    const isoWeekday = today.getUTCDay() || 7;
    const isoWeekStart = new Date(today);
    isoWeekStart.setUTCDate(today.getUTCDate() - isoWeekday + 1);
    const isoWeekEnd = new Date(isoWeekStart);
    isoWeekEnd.setUTCDate(isoWeekStart.getUTCDate() + 6);
    const weekStart = isoWeekStart < monthStart ? monthStart : isoWeekStart;
    const weekEnd = isoWeekEnd > monthEnd ? monthEnd : isoWeekEnd;
    let total = 0;
    let throughToday = 0;
    let beforeToday = 0;
    let beforeWeek = 0;
    let throughWeek = 0;
    for (const cursor = new Date(monthStart); cursor <= monthEnd; cursor.setUTCDate(cursor.getUTCDate() + 1)) {
      if (cursor.getUTCDay() === 0) continue;
      total += 1;
      if (cursor <= today) throughToday += 1;
      if (cursor < today) beforeToday += 1;
      if (cursor < weekStart) beforeWeek += 1;
      if (cursor <= weekEnd) throughWeek += 1;
    }
    return {
      total,
      throughToday,
      beforeToday,
      beforeWeek,
      throughWeek,
      todayIsWorkingDay: today.getUTCDay() !== 0,
      weekStart: isoDateFromUtc(weekStart),
      weekEnd: isoDateFromUtc(weekEnd),
    };
  }

  function cumulativeGoalCents(goalCents, totalWorkdays, completedWorkdays) {
    if (goalCents <= 0 || totalWorkdays <= 0 || completedWorkdays <= 0) return 0;
    if (completedWorkdays >= totalWorkdays) return goalCents;
    return Math.round((goalCents * completedWorkdays) / totalWorkdays);
  }

  function morningProfessionalGoal(professional, key, context) {
    if (professional.hasPeriodGoals) {
      if (key === "today") return professional.goalToday;
      if (key === "week") return professional.goalWeek;
      return professional.goalMonth;
    }
    if (key === "month") return professional.goalAmount;
    if (!context?.total) return 0;
    const goalCents = Math.max(Math.round(Number(professional.goalAmount || 0) * 100), 0);
    if (key === "today") {
      if (!context.todayIsWorkingDay) return 0;
      return (
        cumulativeGoalCents(goalCents, context.total, context.throughToday)
        - cumulativeGoalCents(goalCents, context.total, context.beforeToday)
      ) / 100;
    }
    return (
      cumulativeGoalCents(goalCents, context.total, context.throughWeek)
      - cumulativeGoalCents(goalCents, context.total, context.beforeWeek)
    ) / 100;
  }

  function renderMorningIndividualGoals(key) {
    const context = morningWorkingDayContext();
    const professionals = morningQueue();
    if (!professionals.length) return "";
    return `<div class="attendance-morning-individual-goals"><span><i class="fa-solid fa-users" aria-hidden="true"></i>Metas individuais</span><div>${professionals.map((professional) => `<p><span title="${escapeHtml(professional.name)}">${escapeHtml(professional.name)}</span><strong>${escapeHtml(formatCurrency(morningProfessionalGoal(professional, key, context)))}</strong></p>`).join("")}</div></div>`;
  }

  function renderMorningGoalCard(key, label, icon, helper) {
    const goal = state.morning?.goals?.[key] || { target: 0, actual: 0 };
    const progress = goalProgress(goal.actual, goal.target);
    return `<article class="attendance-morning-goal is-${key}">
      <header><span><i class="fa-solid ${icon}" aria-hidden="true"></i>${label}</span><b>${progress}%</b></header>
      <span class="attendance-morning-general-label">Meta geral da equipe</span>
      <strong>${escapeHtml(formatCurrency(goal.target))}</strong>
      <small>${escapeHtml(formatCurrency(goal.actual))} realizado${helper ? ` · ${escapeHtml(helper)}` : ""}</small>
      <i class="attendance-morning-progress" aria-hidden="true"><b style="width:${progress}%"></b></i>
      ${renderMorningIndividualGoals(key)}
    </article>`;
  }

  function renderMorningConfigured() {
    const queue = morningQueue();
    const current = queue[0];
    const canConfigure = canManageMorningSettings();
    const canOpenConfig = canOpenMorningConfig();
    const weeklyPeriod = [formatShortDate(state.morning.weekStart), formatShortDate(state.morning.weekEnd)].filter(Boolean).join("–");
    return `<section class="attendance-morning-board" aria-labelledby="goodMorningSellerTitle">
      <header class="attendance-morning-heading">
        <div class="attendance-morning-brand"><span><i class="fa-solid fa-sun" aria-hidden="true"></i></span><div><p class="attendance-eyebrow">Bom Dia Vendedor</p><h2 id="goodMorningSellerTitle">Ritmo comercial de hoje</h2><small>Metas proporcionais aos dias do mês · compras registradas em Atendimentos</small></div></div>
        ${canOpenConfig
          ? `<button class="attendance-secondary-button" type="button" data-attendance-action="open-morning-config"><i class="fa-solid ${canConfigure ? "fa-sliders" : "fa-user-check"}" aria-hidden="true"></i>${canConfigure ? "Configurar metas" : "Gerenciar participantes"}</button>`
          : `<span class="attendance-morning-owner-note"><i class="fa-solid fa-store" aria-hidden="true"></i>Configuração da loja</span>`}
      </header>
      <div class="attendance-morning-content">
        <article class="attendance-turn-card">
          <div class="attendance-turn-label"><span><i class="fa-solid fa-bolt" aria-hidden="true"></i>Vendedor da vez</span><small>Fila compartilhada com toda a equipe</small></div>
          ${current ? `<div class="attendance-turn-current"><span>${escapeHtml(initials(current.name))}</span><div><strong>${escapeHtml(current.name)}</strong><small>Meta mensal ${escapeHtml(formatCurrency(current.goalAmount))} · ${escapeHtml(formatCurrency(current.actualMonth))} realizado</small></div></div>` : `<div class="attendance-turn-current is-empty"><span><i class="fa-solid fa-user-plus" aria-hidden="true"></i></span><div><strong>Fila ainda não configurada</strong><small>Abra as configurações para incluir a equipe.</small></div></div>`}
          <div class="attendance-turn-queue" aria-label="Ordem da vez">${queue.map((professional, index) => `<span class="${index === 0 ? "is-current" : ""}"><b>${index + 1}</b>${escapeHtml(professional.name)}</span>`).join("")}</div>
          ${canConfigure
            ? `<button class="attendance-turn-next" type="button" data-attendance-action="advance-morning-turn" ${state.morningSaving || state.morningParticipationSaving || queue.length < 2 ? "disabled" : ""}><i class="fa-solid fa-arrow-right" aria-hidden="true"></i>${state.morningSaving ? "Atualizando fila" : "Passar para o próximo"}</button>`
            : `<span class="attendance-turn-owner-note"><i class="fa-solid fa-lock" aria-hidden="true"></i>A loja controla a vez</span>`}
        </article>
        <div class="attendance-morning-goals">
          ${renderMorningGoalCard("today", "Meta de hoje", "fa-calendar-day", "dia")}
          ${renderMorningGoalCard("week", "Meta da semana", "fa-calendar-week", weeklyPeriod)}
          ${renderMorningGoalCard("month", "Meta do mês", "fa-bullseye", "equipe")}
        </div>
      </div>
    </section>`;
  }

  function renderMorningSetup() {
    const isNewMonth = Boolean(state.morning?.savedGoalMonth && state.morning.savedGoalMonth !== state.morning.goalMonth);
    const canConfigure = canManageMorningSettings();
    const canOpenConfig = canOpenMorningConfig();
    const teamProfessionalCount = state.morning?.teamProfessionalCount ?? state.morning?.professionals?.length ?? 0;
    const hasParticipants = (state.morning?.eligibleProfessionalCount ?? morningParticipants(state.morning?.professionals || []).length) > 0;
    const hasTeamProfessionals = teamProfessionalCount > 0;
    const setupTitle = !hasTeamProfessionals
      ? "Nenhum profissional cadastrado"
      : !hasParticipants
      ? "Nenhum vendedor participando"
      : isAdminRole()
      ? "Participantes do Bom Dia Vendedor"
      : isNewMonth ? "Comece o novo mês com a meta atualizada" : "Transforme a meta em ritmo diário";
    const setupCopy = !hasTeamProfessionals
      ? "Cadastre a equipe deste cliente antes de configurar metas e montar a rotação da vez."
      : isAdminRole()
        ? "Ative somente quem participa desta área. A loja continua responsável pela meta mensal e pela ordem da vez."
      : canConfigure
        ? "Defina a meta mensal, escolha a divisão por vendedor e organize a fila da vez. O sistema calcula automaticamente os objetivos de hoje e desta semana."
        : "O Admin ou a loja escolhem quem participa. A loja define a meta mensal e organiza a ordem da vez.";
    return `<section class="attendance-morning-board attendance-morning-board--setup">
      <div class="attendance-morning-setup-icon"><i class="fa-solid fa-sun" aria-hidden="true"></i></div>
      <div><p class="attendance-eyebrow">Bom Dia Vendedor</p><h2>${setupTitle}</h2><p>${setupCopy}</p></div>
      ${canOpenConfig && hasTeamProfessionals
        ? `<button class="attendance-primary-button" type="button" data-attendance-action="open-morning-config"><i class="fa-solid ${canConfigure ? "fa-wand-magic-sparkles" : "fa-user-check"}" aria-hidden="true"></i>${canConfigure ? (isNewMonth ? "Atualizar meta do mês" : "Configurar Bom Dia Vendedor") : "Gerenciar participantes"}</button>`
        : `<span class="attendance-morning-owner-note"><i class="fa-solid ${hasTeamProfessionals ? "fa-user-shield" : "fa-users"}" aria-hidden="true"></i>${hasTeamProfessionals ? "Gerenciamento do Admin ou da loja" : "Aguardando cadastro da equipe"}</span>`}
    </section>`;
  }

  function renderMorningLocked() {
    return `<section class="attendance-morning-board attendance-morning-board--locked">
      <span><i class="fa-solid fa-lock" aria-hidden="true"></i></span>
      <div><p class="attendance-eyebrow">Licença adicional</p><h2>Bom Dia Vendedor</h2><p>Metas, divisão por vendedor e fila da vez ficam disponíveis quando o Admin libera esta licença para o cliente.</p></div>
      <em><i class="fa-solid fa-sun" aria-hidden="true"></i>Recurso bloqueado</em>
    </section>`;
  }

  function morningDraftTotal() {
    return morningParticipants(state.morningDraft?.professionals || [])
      .reduce((sum, professional) => sum + normalizeMoney(professional.goalAmount), 0);
  }

  function renderMorningSellerConfigRow(professional, participants) {
    const enabled = professional.enabled !== false;
    const participationControlAvailable = state.morning?.participationControlAvailable === true
      && state.morning?.participationUpdateAvailable === true;
    const participationBusy = Boolean(state.morningParticipationSaving);
    const savingThisProfessional = state.morningParticipationSaving === professional.id;
    const canToggleParticipation = canManageMorningParticipation()
      && !state.morningSaving
      && !participationBusy;
    const canConfigure = canManageMorningSettings();
    const participantIndex = participants.findIndex((participant) => participant.id === professional.id);
    const participantNumber = participantIndex + 1;
    const isFirst = participantIndex === 0;
    const isLast = participantIndex === participants.length - 1;
    const escapedId = escapeHtml(professional.id);
    const escapedName = escapeHtml(professional.name);
    const queueLabel = enabled
      ? (isFirst ? "Primeiro da fila" : `${participantNumber}º na fila`)
      : "Fora da fila e do rateio";
    const visibleGoal = enabled ? professional.goalAmount : 0;
    const goalDisabled = !canConfigure
      || state.morningDraft?.mode === "equal"
      || !enabled
      || state.morningSaving
      || participationBusy;
    const participationLabel = savingThisProfessional ? "Salvando…" : (enabled ? "Participando" : "Pausado");
    return `<article class="${enabled ? "" : "is-disabled"}${savingThisProfessional ? " is-saving" : ""}" data-morning-professional="${escapedId}" data-morning-enabled="${enabled}" aria-busy="${savingThisProfessional ? "true" : "false"}">
      <b title="${enabled ? `${participantNumber}º na fila` : "Fora da fila"}">${enabled ? participantNumber : `<i class="fa-solid fa-pause" aria-hidden="true"></i>`}</b>
      <span class="attendance-morning-seller-avatar">${escapeHtml(initials(professional.name))}</span>
      <div class="attendance-morning-seller-identity"><strong>${escapedName}</strong><small>${queueLabel}</small><label class="attendance-morning-participation${canToggleParticipation || savingThisProfessional ? "" : " is-unavailable"}${savingThisProfessional ? " is-saving" : ""}"><input type="checkbox" role="switch" data-morning-seller-enabled="${escapedId}" ${enabled ? "checked" : ""}${canToggleParticipation ? "" : " disabled"} aria-checked="${enabled}" aria-label="${participationControlAvailable ? `${enabled ? "Retirar" : "Incluir"} ${escapedName} do Bom Dia Vendedor` : "Controle de participação indisponível até a atualização do banco"}" /><span class="attendance-morning-participation-switch" aria-hidden="true"></span><span>${participationLabel}</span></label></div>
      <label class="attendance-morning-seller-goal"><span>Meta mensal</span><span><b>R$</b><input data-morning-seller-goal="${escapedId}" inputmode="decimal" value="${escapeHtml(String(visibleGoal || 0))}" aria-label="Meta mensal de ${escapedName}" ${goalDisabled ? "disabled" : ""} /></span></label>
      <div class="attendance-morning-order-actions"><button type="button" data-attendance-action="move-morning-seller-up" data-professional-id="${escapedId}" aria-label="Mover ${escapedName} para cima" ${!canConfigure || state.morningSaving || participationBusy || !enabled || isFirst ? "disabled" : ""}><i class="fa-solid fa-chevron-up" aria-hidden="true"></i></button><button type="button" data-attendance-action="move-morning-seller-down" data-professional-id="${escapedId}" aria-label="Mover ${escapedName} para baixo" ${!canConfigure || state.morningSaving || participationBusy || !enabled || isLast ? "disabled" : ""}><i class="fa-solid fa-chevron-down" aria-hidden="true"></i></button></div>
    </article>`;
  }

  function renderMorningConfig() {
    const draft = state.morningDraft;
    if (!state.morningConfigOpen || !draft || !canOpenMorningConfig()) return "";
    const canConfigure = canManageMorningSettings();
    const participationControlAvailable = state.morning?.participationControlAvailable === true
      && state.morning?.participationUpdateAvailable === true;
    const participationBusy = Boolean(state.morningParticipationSaving);
    const configurationControlsEnabled = canConfigure && !state.morningSaving && !participationBusy;
    const participants = morningParticipants(draft.professionals);
    const total = morningDraftTotal();
    const difference = Math.round((normalizeMoney(draft.monthlyGoal) - total) * 100) / 100;
    const balanced = participants.length > 0 && Math.abs(difference) < 0.01;
    const allocationStatus = participants.length === 0
      ? "Ative ao menos 1 vendedor"
      : balanced
        ? "Distribuição completa"
        : `${difference > 0 ? "Faltam" : "Excedeu"} ${formatCurrency(Math.abs(difference))}`;
    const headerCopy = canConfigure
      ? "A participação é salva na hora; meta e ordem são salvas pelo botão abaixo."
      : "Ative ou pause quem participa. Meta mensal e ordem da vez continuam sob responsabilidade da loja.";
    return `<div class="attendance-morning-modal" role="presentation" data-morning-backdrop>
      <section class="attendance-morning-dialog" role="dialog" aria-modal="true" aria-labelledby="morningConfigTitle" data-morning-dialog>
        <header><div><p class="attendance-eyebrow">Bom Dia Vendedor</p><h2 id="morningConfigTitle">${canConfigure ? "Meta e fila da equipe" : "Participação da equipe"}</h2><span>${headerCopy}</span></div><button type="button" data-attendance-action="close-morning-config" aria-label="Fechar configurações"><i class="fa-solid fa-xmark" aria-hidden="true"></i></button></header>
        <form class="${canConfigure ? "" : "is-participation-only"}" data-morning-config-form aria-busy="${state.morningSaving || participationBusy ? "true" : "false"}">
          <div class="attendance-morning-config-top${canConfigure ? "" : " is-readonly"}">
            <label><span><i class="fa-solid fa-bullseye" aria-hidden="true"></i>Meta mensal da equipe</span><span class="attendance-morning-money"><b>R$</b><input name="monthly_goal" inputmode="decimal" value="${escapeHtml(String(draft.monthlyGoal || ""))}" placeholder="0,00" ${configurationControlsEnabled ? "required" : "disabled"} /></span></label>
            <fieldset ${configurationControlsEnabled ? "" : "disabled"}><legend><i class="fa-solid fa-scale-balanced" aria-hidden="true"></i>Como dividir</legend><label><input type="radio" name="allocation_mode" value="equal" ${draft.mode === "equal" ? "checked" : ""} /><span>Partes iguais</span></label><label><input type="radio" name="allocation_mode" value="custom" ${draft.mode === "custom" ? "checked" : ""} /><span>Personalizada</span></label></fieldset>
          </div>
          <div class="attendance-morning-config-heading"><div><strong>${canConfigure ? "Vendedores e ordem da vez" : "Quem participa desta área"}</strong><small>Quem estiver pausado continua cadastrado na equipe, mas fica fora da fila, das metas e do rateio.</small></div><span data-morning-allocation-status class="${canConfigure ? (balanced ? "is-balanced" : "is-warning") : "is-balanced"}" role="status" aria-live="polite">${escapeHtml(canConfigure ? allocationStatus : `${participants.length} ${participants.length === 1 ? "participante" : "participantes"}`)}</span></div>
          ${!participationControlAvailable ? `<p class="attendance-morning-capability-warning" role="alert"><i class="fa-solid fa-database" aria-hidden="true"></i>A atualização segura do banco ainda precisa ser aplicada para liberar estes switches.</p>` : ""}
          <div class="attendance-morning-seller-list">${draft.professionals.map((professional) => renderMorningSellerConfigRow(professional, participants)).join("") || `<div class="attendance-morning-seller-empty"><span><i class="fa-solid fa-user-plus" aria-hidden="true"></i></span><div><strong>Nenhum vendedor ativo</strong><small>Cadastre a equipe deste cliente para dividir a meta e montar a fila.</small></div></div>`}</div>
          ${state.morningError ? `<p class="attendance-morning-form-error" role="alert"><i class="fa-solid fa-circle-exclamation" aria-hidden="true"></i>${escapeHtml(state.morningError)}</p>` : ""}
          <footer><div><span>${canConfigure ? `Total distribuído · ${participants.length} ${participants.length === 1 ? "participante" : "participantes"}` : "Alterações de participação"}</span><strong data-morning-distributed-total>${canConfigure ? escapeHtml(formatCurrency(total)) : "Salvas na hora"}</strong></div><button class="attendance-secondary-button" type="button" data-attendance-action="close-morning-config">Fechar</button>${canConfigure ? `<button class="attendance-primary-button" type="submit" ${state.morningSaving || participationBusy || !participants.length || !balanced ? "disabled" : ""}><i class="fa-solid fa-check" aria-hidden="true"></i>${state.morningSaving ? "Salvando" : "Salvar meta e fila"}</button>` : ""}</footer>
        </form>
      </section>
    </div>`;
  }

  function renderGoodMorningSeller() {
    const store = selectedStore();
    if (!store) return "";
    let content = "";
    if (!store.goodMorningSellerEnabled) content = renderMorningLocked();
    else if (state.morningLoading) content = `<section class="attendance-morning-board attendance-morning-board--loading" role="status"><span class="attendance-spinner" aria-hidden="true"></span><div><strong>Preparando o Bom Dia Vendedor</strong><small>Calculando metas e carregando a fila da equipe.</small></div></section>`;
    else if (state.morningError && !state.morning) content = `<section class="attendance-morning-board attendance-morning-board--error"><span><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span><div><strong>Bom Dia Vendedor indisponível</strong><small>${escapeHtml(state.morningError)}</small></div><button class="attendance-secondary-button" type="button" data-attendance-action="retry-morning"><i class="fa-solid fa-rotate-right" aria-hidden="true"></i>Tentar novamente</button></section>`;
    else if (state.morning?.configured) content = renderMorningConfigured();
    else content = renderMorningSetup();
    return `<div class="attendance-morning-root" data-good-morning-seller>${content}${renderMorningConfig()}</div>`;
  }

  function refreshMorningRegion({ dialogScrollTop = null, focusSelector = "" } = {}) {
    const region = state.root?.querySelector("[data-good-morning-seller]");
    if (region) region.outerHTML = renderGoodMorningSeller();
    if (dialogScrollTop !== null || focusSelector) {
      requestAnimationFrame(() => {
        const dialog = state.root?.querySelector("[data-morning-dialog]");
        if (dialog && dialogScrollTop !== null) dialog.scrollTop = dialogScrollTop;
        if (focusSelector) state.root?.querySelector(focusSelector)?.focus();
      });
    }
  }

  function closeMorningConfig({ restoreFocus = true, force = false } = {}) {
    if (!force && (state.morningSaving || state.morningParticipationSaving)) {
      notify("Aguarde a atualização terminar antes de fechar.", "warning");
      return false;
    }
    state.morningConfigOpen = false;
    state.morningConfigGeneration += 1;
    state.morningDraft = null;
    state.morningError = "";
    refreshMorningRegion();
    if (restoreFocus) {
      requestAnimationFrame(() => {
        state.root?.querySelector('[data-attendance-action="open-morning-config"]')?.focus();
      });
    }
    return true;
  }

  function captureDraft() {
    const form = state.root?.querySelector("[data-attendance-form]");
    if (!form || !state.selectedStoreId) return;
    state.drafts.set(state.selectedStoreId, {
      professionalName: String(form.elements.professional_name?.value || ""),
      attendedOn: String(form.elements.attended_on?.value || ""),
      customerName: String(form.elements.customer_name?.value || ""),
      phone: String(form.elements.phone?.value || ""),
      cpf: String(form.elements.cpf?.value || ""),
      description: String(form.elements.description?.value || ""),
      serviceValue: String(form.elements.service_value?.value || ""),
      tag: String(form.querySelector('input[name="tag"]:checked')?.value || "budget"),
      purchaseValue: String(form.elements.purchase_value?.value || ""),
      serviceOrder: String(form.elements.service_order?.value || ""),
    });
  }

  function renderFeedback() {
    if (!state.feedback) return "";
    const feedback = state.feedback;
    const origins = [];
    if (feedback.linkedLead?.linked) origins.push("Lead");
    if (feedback.linkedProspection?.linked) origins.push("Prospecção");
    if (!origins.length) origins.push(feedback.ambiguous ? "Origem não atribuída" : "Avulso");
    const bonusApplicable = feedback.linkedProspection?.linked && feedback.attendance?.tag === "purchase" && !feedback.ambiguous;
    const bonusClass = bonusApplicable && feedback.bonusEligible === true
      ? "is-positive"
      : bonusApplicable && feedback.bonusEligible === false ? "is-negative" : "is-neutral";
    const bonusLabel = feedback.ambiguous
      ? "Não aplicado: vínculo ambíguo"
      : !bonusApplicable
        ? "Não se aplica a este atendimento"
        : feedback.bonusEligible === true
          ? `Elegível${feedback.bonusAmount != null ? ` · ${formatCurrency(feedback.bonusAmount)}` : ""}`
          : feedback.bonusEligible === false ? "Não elegível" : "Aguardando regra do servidor";
    const candidateSummary = [
      feedback.candidateCounts?.lead ? `${feedback.candidateCounts.lead} candidatos em Leads` : "",
      feedback.candidateCounts?.prospection ? `${feedback.candidateCounts.prospection} candidatos em Prospecções` : "",
    ].filter(Boolean).join(" e ");

    return `<aside class="attendance-save-feedback" aria-live="polite">
      <div class="attendance-feedback-title">
        <span><i class="fa-solid fa-circle-check" aria-hidden="true"></i></span>
        <div><strong>${feedback.idempotentReplay ? "Atendimento já estava registrado" : "Atendimento registrado"}</strong><small>${escapeHtml(feedback.message || "Vínculos identificados automaticamente")}</small></div>
        <button type="button" data-attendance-action="dismiss-feedback" aria-label="Fechar retorno"><i class="fa-solid fa-xmark" aria-hidden="true"></i></button>
      </div>
      ${feedback.ambiguous ? `<div class="attendance-ambiguity-warning"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i><span><strong>Correspondência ambígua.</strong> O atendimento foi preservado, mas nenhuma atribuição financeira incerta foi aplicada.${candidateSummary ? ` ${escapeHtml(candidateSummary)}.` : ""}</span></div>` : ""}
      <dl class="attendance-feedback-grid">
        <div><dt>Atendimento realizado por</dt><dd>${escapeHtml(feedback.professionalName || "Não informado")}</dd></div>
        <div><dt>Origem detectada</dt><dd class="attendance-origin-list">${origins.map((origin) => `<span>${escapeHtml(origin)}</span>`).join("")}</dd></div>
        <div><dt>Profissional creditado da prospecção</dt><dd>${escapeHtml(feedback.prospectionProfessionalName || "Nenhum profissional creditado")}</dd></div>
        <div><dt>Bônus da prospecção</dt><dd><span class="attendance-bonus-status ${bonusClass}">${escapeHtml(bonusLabel)}</span>${feedback.bonusReason ? `<small>${escapeHtml(feedback.bonusReason)}</small>` : ""}</dd></div>
      </dl>
    </aside>`;
  }

  function renderForm() {
    const professionalRecords = registeredProfessionalRecords();
    const professionals = professionalRecords.map((professional) => professional.name);
    const draft = state.drafts.get(state.selectedStoreId) || { tag: "budget" };
    const dateLimits = attendanceDateLimits();
    const retroactiveDatesGranted = attendanceRetroactiveDatesGranted();
    const attendedOn = isValidAttendanceDate(draft.attendedOn, dateLimits) ? draft.attendedOn : dateLimits.today;
    const draftedProfessional = professionals.find((name) => normalizeText(name) === normalizeText(draft.professionalName));
    const selectedProfessional = draftedProfessional || (professionals.length === 1 ? professionals[0] : "");
    const hasProfessionals = professionals.length > 0;
    return `<article class="attendance-panel attendance-form-panel">
      <header class="attendance-panel-header">
        <div><p class="attendance-eyebrow">Novo registro</p><h2>Registrar atendimento</h2><span>O sistema cruza telefone ou CPF com Leads e Prospecções ao salvar.</span></div>
        <span class="attendance-header-badge"><i class="fa-solid fa-wand-magic-sparkles" aria-hidden="true"></i>Vínculo automático</span>
      </header>
      <form class="attendance-form" data-attendance-form data-professionals-ready="${hasProfessionals ? "true" : "false"}" novalidate aria-busy="${state.saving ? "true" : "false"}">
        <div class="attendance-form-grid">
          <label class="attendance-field attendance-field--wide">
            <span>Atendimento realizado por <b>*</b></span>
            <span class="attendance-input-wrap attendance-input-wrap--select"><i class="fa-solid fa-user-tie" aria-hidden="true"></i><select name="professional_name" required ${hasProfessionals ? "" : "disabled"}>
              <option value="">${hasProfessionals ? "Selecione o profissional" : "Nenhum profissional cadastrado"}</option>
              ${professionalRecords.map((professional) => `<option value="${escapeHtml(professional.name)}" ${professional.name === selectedProfessional ? "selected" : ""}>${escapeHtml(professional.name)}${professional.active ? "" : " · inativo na equipe"}</option>`).join("")}
            </select></span>
            <small class="attendance-professional-source ${hasProfessionals ? "" : "is-empty"}"><i class="fa-solid ${hasProfessionals ? "fa-circle-check" : "fa-circle-exclamation"}" aria-hidden="true"></i>${hasProfessionals ? "Equipe do cliente sincronizada; profissionais inativos continuam disponíveis no histórico." : "Cadastre ao menos um profissional na equipe deste cliente para registrar atendimentos."}</small>
          </label>
          <label class="attendance-field">
            <span>Cliente <b>*</b></span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-user" aria-hidden="true"></i><input name="customer_name" autocomplete="name" placeholder="Nome do cliente" value="${escapeHtml(draft.customerName || "")}" required /></span>
          </label>
          <label class="attendance-field">
            <span>Data do atendimento <b>*</b></span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-calendar-day" aria-hidden="true"></i><input name="attended_on" type="date" min="${escapeHtml(dateLimits.min)}" max="${escapeHtml(dateLimits.today)}" value="${escapeHtml(attendedOn)}" required /></span>
            <small>${retroactiveDatesGranted ? "Hoje ou uma data dos últimos 2 anos." : "Somente hoje. Datas retroativas requerem a atualização do sistema."}</small>
          </label>
          <label class="attendance-field">
            <span>Telefone</span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-phone" aria-hidden="true"></i><input name="phone" inputmode="tel" autocomplete="tel" placeholder="(00) 00000-0000" value="${escapeHtml(draft.phone || "")}" /></span>
            <small>Informe telefone ou CPF para localizar o cliente.</small>
          </label>
          <label class="attendance-field">
            <span>CPF</span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-id-card" aria-hidden="true"></i><input name="cpf" inputmode="numeric" autocomplete="off" maxlength="14" placeholder="000.000.000-00" value="${escapeHtml(draft.cpf || "")}" /></span>
            <small>O CPF também cruza Leads e Prospecções.</small>
          </label>
          <label class="attendance-field attendance-field--wide">
            <span>Descrição do atendimento <b>*</b></span>
            <span class="attendance-input-wrap attendance-input-wrap--textarea"><i class="fa-solid fa-align-left" aria-hidden="true"></i><textarea name="description" rows="4" placeholder="Conte o que foi realizado, necessidade do cliente e próximo passo" required>${escapeHtml(draft.description || "")}</textarea></span>
          </label>
          <label class="attendance-field attendance-field--wide">
            <span>Valor do atendimento</span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-brazilian-real-sign" aria-hidden="true"></i><input name="service_value" inputmode="decimal" placeholder="0,00" value="${escapeHtml(draft.serviceValue || "")}" /></span>
          </label>
        </div>

        <fieldset class="attendance-tag-fieldset">
          <legend>Como classificar este atendimento? <b>*</b></legend>
          <div class="attendance-tag-options">
            ${Object.entries(TAGS).map(([value, config]) => `<label class="attendance-tag-option attendance-tag-option--${config.tone}">
              <input type="radio" name="tag" value="${value}" ${value === normalizeTag(draft.tag) ? "checked" : ""} />
              <span><i class="fa-solid ${config.icon}" aria-hidden="true"></i><strong>${config.label}</strong><i class="fa-solid fa-circle-check attendance-tag-check" aria-hidden="true"></i></span>
            </label>`).join("")}
          </div>
        </fieldset>

        <section class="attendance-purchase-fields" data-attendance-purchase-fields hidden>
          <div class="attendance-purchase-heading"><span><i class="fa-solid fa-bag-shopping" aria-hidden="true"></i></span><div><strong>Dados da compra</strong><small>Obrigatórios somente quando a etiqueta for Compra.</small></div></div>
          <div class="attendance-form-grid">
            <label class="attendance-field"><span>Valor da compra <b>*</b></span><span class="attendance-input-wrap"><i class="fa-solid fa-sack-dollar" aria-hidden="true"></i><input name="purchase_value" inputmode="decimal" placeholder="0,00" value="${escapeHtml(draft.purchaseValue || "")}" disabled /></span></label>
            <label class="attendance-field"><span>Ordem de serviço (OS) <b>*</b></span><span class="attendance-input-wrap"><i class="fa-solid fa-receipt" aria-hidden="true"></i><input name="service_order" autocomplete="off" placeholder="Ex.: OS-1048" value="${escapeHtml(draft.serviceOrder || "")}" disabled /></span></label>
          </div>
        </section>

        <div class="attendance-form-error" data-attendance-form-error role="alert" hidden></div>
        <button class="attendance-primary-button" type="submit" data-attendance-save ${state.saving || !hasProfessionals ? "disabled" : ""}>
          <span class="attendance-button-idle"><i class="fa-solid fa-check" aria-hidden="true"></i>Salvar atendimento</span>
          <span class="attendance-button-loading"><span class="attendance-mini-spinner" aria-hidden="true"></span>Salvando com segurança</span>
        </button>
      </form>
      ${renderFeedback()}
    </article>`;
  }

  function filteredRecords() {
    const query = normalizeText(state.filters.search);
    const range = embeddedAttendanceRange(state.filters.period);
    const startAt = range.startDate ? new Date(`${range.startDate}T00:00:00`) : null;
    const endAt = range.endDate ? new Date(`${range.endDate}T23:59:59.999`) : null;
    return state.listRecords.filter((record) => {
      if (state.filters.tag !== "all" && record.tag !== state.filters.tag) return false;
      if (state.filters.professional !== "all" && normalizeText(record.professionalName) !== normalizeText(state.filters.professional)) return false;
      if (state.filters.link === "linked" && !record.linkedLead?.linked && !record.linkedProspection?.linked) return false;
      if (state.filters.link === "standalone" && (record.linkedLead?.linked || record.linkedProspection?.linked || record.ambiguous)) return false;
      if (state.filters.link === "review" && !record.ambiguous) return false;
      if (startAt || endAt) {
        const attendedAt = new Date(record.createdAt || 0);
        if (Number.isNaN(attendedAt.getTime())) return false;
        if (startAt && attendedAt < startAt) return false;
        if (endAt && attendedAt > endAt) return false;
      }
      if (!query) return true;
      return normalizeText([
        record.customerName,
        record.phone,
        record.cpf,
        record.professionalName,
        record.description,
        record.serviceOrder,
        TAGS[record.tag]?.label,
      ].join(" ")).includes(query);
    }).sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));
  }

  function operationalListCoverage() {
    const visible = filteredRecords().length;
    const loaded = state.listRecords.length;
    if (state.listSource !== "paged") {
      return `${visible} nos ${loaded} registros recentes disponíveis enquanto a lista completa carrega`;
    }
    if (state.filters.link === "review") {
      return `${visible} para revisar entre ${loaded} carregados${state.listHasMore ? " · carregue mais para continuar" : ""}`;
    }
    return `${loaded} de ${Math.max(state.listTotal, loaded)} carregados`;
  }

  function renderOperationalPagination() {
    if (state.listLoading) {
      return `<div class="attendance-list-pagination is-loading" role="status"><span class="attendance-mini-spinner" aria-hidden="true"></span><span>${state.listRecords.length ? "Carregando mais atendimentos" : "Carregando lista completa"}</span></div>`;
    }
    if (state.listError) {
      return `<div class="attendance-list-pagination is-error"><span><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>${escapeHtml(state.listError)}</span><button type="button" data-attendance-action="retry-list"><i class="fa-solid fa-rotate-right" aria-hidden="true"></i>Tentar novamente</button></div>`;
    }
    if (state.listHasMore) {
      return `<div class="attendance-list-pagination"><span>${escapeHtml(operationalListCoverage())}</span><button type="button" data-attendance-action="load-more"><i class="fa-solid fa-chevron-down" aria-hidden="true"></i>Carregar mais 30</button></div>`;
    }
    if (state.listLoaded) {
      return `<div class="attendance-list-pagination is-complete"><i class="fa-solid fa-circle-check" aria-hidden="true"></i><span>${escapeHtml(state.filters.link === "review" ? `${filteredRecords().length} registros para revisar na lista carregada` : `Todos os ${state.listTotal} registros deste filtro foram carregados`)}</span></div>`;
    }
    return "";
  }

  function attendanceFilterCount(filters = state.filters) {
    return Number(filters.tag !== "all")
      + Number(filters.professional !== "all")
      + Number(filters.period !== "30d")
      + Number(filters.link !== "all");
  }

  function renderRecordOrigins(record) {
    const origins = [];
    if (record.linkedLead?.linked) origins.push(`<span class="attendance-link-badge attendance-link-badge--lead"><i class="fa-solid fa-user-group" aria-hidden="true"></i>Lead</span>`);
    if (record.linkedProspection?.linked) origins.push(`<span class="attendance-link-badge attendance-link-badge--prospection"><i class="fa-solid fa-phone" aria-hidden="true"></i>Prospecção</span>`);
    if (record.ambiguous) origins.push(`<span class="attendance-link-badge attendance-link-badge--review"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>Revisar vínculo</span>`);
    if (!origins.length) origins.push(`<span class="attendance-link-badge attendance-link-badge--standalone"><i class="fa-solid fa-circle-dot" aria-hidden="true"></i>Avulso</span>`);
    return origins.join("");
  }

  function renderRecord(record, { compact = false } = {}) {
    const tag = TAGS[record.tag] || TAGS.other;
    const phone = onlyDigits(record.phone);
    const bonusApplies = record.tag === "purchase" && record.linkedProspection?.linked;
    const bonus = bonusApplies && record.bonusEligible === true
      ? `<span class="attendance-record-bonus is-positive"><i class="fa-solid fa-award" aria-hidden="true"></i>Bônus elegível${record.bonusAmount != null ? ` · ${escapeHtml(formatCurrency(record.bonusAmount))}` : ""}</span>`
      : bonusApplies && record.bonusEligible === false
        ? `<span class="attendance-record-bonus is-negative"><i class="fa-solid fa-circle-minus" aria-hidden="true"></i>Não elegível</span>`
        : "";
    return `<article class="attendance-record${compact ? " is-compact" : ""}">
      <div class="attendance-record-accent attendance-record-accent--${tag.tone}" aria-hidden="true"></div>
      <header>
        <div class="attendance-record-person"><span>${escapeHtml(initials(record.customerName))}</span><div><strong>${escapeHtml(record.customerName)}</strong><small>${escapeHtml([record.phone, record.cpf].filter(Boolean).join(" · ") || "Documento não informado")}</small></div></div>
        <span class="attendance-record-tag attendance-record-tag--${tag.tone}"><i class="fa-solid ${tag.icon}" aria-hidden="true"></i>${tag.label}</span>
      </header>
      <div class="attendance-record-context"><small>Contexto do atendimento</small><p class="attendance-record-description">${escapeHtml(record.description || "Nenhuma descrição informada.")}</p></div>
      <div class="attendance-record-meta">
        <span><i class="fa-solid fa-user-tie" aria-hidden="true"></i><small>Atendido por</small><b>${escapeHtml(record.professionalName)}</b></span>
        <span><i class="fa-regular fa-calendar" aria-hidden="true"></i><small>Data</small><b>${escapeHtml(formatDateTime(record.createdAt))}</b></span>
        ${record.serviceOrder ? `<span><i class="fa-solid fa-receipt" aria-hidden="true"></i><small>Ordem de serviço</small><b>${escapeHtml(record.serviceOrder)}</b></span>` : ""}
      </div>
      <footer>
        <div class="attendance-record-summary"><div class="attendance-record-links">${renderRecordOrigins(record)}${record.prospectionProfessionalName ? `<span class="attendance-credit-badge"><i class="fa-solid fa-medal" aria-hidden="true"></i>Crédito: ${escapeHtml(record.prospectionProfessionalName)}</span>` : ""}${bonus}</div><div class="attendance-record-values">${record.serviceValue ? `<span><small>Atendimento</small><b>${escapeHtml(formatCurrency(record.serviceValue))}</b></span>` : ""}${record.tag === "purchase" ? `<span><small>Compra</small><b>${escapeHtml(formatCurrency(record.purchaseValue))}</b></span>` : ""}</div></div>
        <div class="attendance-record-actions">${phone ? `<a class="attendance-card-action is-primary" href="tel:${escapeHtml(phone)}"><i class="fa-solid fa-phone" aria-hidden="true"></i>Ligar</a><button class="attendance-card-action" type="button" data-attendance-copy-phone="${escapeHtml(phone)}"><i class="fa-regular fa-copy" aria-hidden="true"></i>Copiar telefone</button>` : `<span class="attendance-card-action is-disabled"><i class="fa-solid fa-phone-slash" aria-hidden="true"></i>Sem telefone</span>`}</div>
      </footer>
    </article>`;
  }

  function renderRecordListContent() {
    const records = filteredRecords();
    if (!records.length && state.listLoading) {
      return `<div class="attendance-list-empty" role="status"><span><i class="fa-solid fa-circle-notch fa-spin" aria-hidden="true"></i></span><strong>Carregando atendimentos</strong><p>A consulta está limitada a esta loja e traz 30 registros por vez.</p></div>`;
    }
    if (!records.length) {
      return `<div class="attendance-list-empty"><span><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i></span><strong>Nenhum atendimento encontrado</strong><p>Ajuste os filtros ou registre o primeiro atendimento deste cliente.</p></div>`;
    }
    return records.map(renderRecord).join("");
  }

  function renderOverview() {
    const professionals = professionalOptions();
    const filterCount = attendanceFilterCount();
    const resultCount = filteredRecords().length;
    return `<section class="attendance-overview">
      <article class="attendance-panel attendance-list-panel">
        <header class="attendance-list-header">
          <div class="attendance-list-heading"><p class="attendance-eyebrow">Consulta rápida</p><h2>Buscar atendimentos</h2><span data-attendance-result-count>${resultCount} registro${resultCount === 1 ? "" : "s"} exibido${resultCount === 1 ? "" : "s"}</span></div>
          <div class="attendance-list-tools">
            <label class="attendance-search"><span class="attendance-sr-only">Buscar nos atendimentos</span><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i><input type="search" data-attendance-filter="search" value="${escapeHtml(state.filters.search)}" placeholder="Nome, telefone, CPF, descrição ou OS" aria-label="Buscar atendimentos" /></label>
            <button class="attendance-filter-button${state.filtersOpen || filterCount ? " is-active" : ""}" type="button" data-attendance-action="toggle-filters" aria-expanded="${String(state.filtersOpen)}" aria-controls="attendanceFilters"><i class="fa-solid fa-sliders" aria-hidden="true"></i><span>Filtros</span><b data-attendance-filter-count ${filterCount ? "" : "hidden"}>${filterCount}</b></button>
          </div>
        </header>
        <div id="attendanceFilters" class="attendance-filter-panel" ${state.filtersOpen ? "" : "hidden"}>
          <label><span><i class="fa-solid fa-tags" aria-hidden="true"></i>Tipo</span><select data-attendance-filter="tag"><option value="all" ${state.filters.tag === "all" ? "selected" : ""}>Todos os tipos</option>${Object.entries(TAGS).map(([value, tag]) => `<option value="${value}" ${state.filters.tag === value ? "selected" : ""}>${tag.label}</option>`).join("")}</select></label>
          <label><span><i class="fa-solid fa-user-tie" aria-hidden="true"></i>Profissional</span><select data-attendance-filter="professional"><option value="all">Todos os profissionais</option>${professionals.map((name) => `<option value="${escapeHtml(name)}" ${state.filters.professional === name ? "selected" : ""}>${escapeHtml(name)}</option>`).join("")}</select></label>
          <label><span><i class="fa-solid fa-link" aria-hidden="true"></i>Vínculo</span><select data-attendance-filter="link"><option value="all" ${state.filters.link === "all" ? "selected" : ""}>Todos os vínculos</option><option value="linked" ${state.filters.link === "linked" ? "selected" : ""}>Lead ou Prospecção</option><option value="standalone" ${state.filters.link === "standalone" ? "selected" : ""}>Atendimento avulso</option><option value="review" ${state.filters.link === "review" ? "selected" : ""}>Precisa revisar</option></select></label>
          <label><span><i class="fa-solid fa-calendar-days" aria-hidden="true"></i>Período</span><select data-attendance-filter="period"><option value="today" ${state.filters.period === "today" ? "selected" : ""}>Hoje</option><option value="currentWeek" ${state.filters.period === "currentWeek" ? "selected" : ""}>Esta semana</option><option value="lastWeek" ${state.filters.period === "lastWeek" ? "selected" : ""}>Semana passada</option><option value="7d" ${state.filters.period === "7d" ? "selected" : ""}>Últimos 7 dias</option><option value="30d" ${state.filters.period === "30d" ? "selected" : ""}>Últimos 30 dias</option><option value="all" ${state.filters.period === "all" ? "selected" : ""}>Todo o período</option></select></label>
          <button class="attendance-clear-filters" type="button" data-attendance-action="clear-filters"><i class="fa-solid fa-rotate-left" aria-hidden="true"></i>Limpar filtros</button>
        </div>
        <div class="attendance-list-status"><span><i class="fa-solid fa-layer-group" aria-hidden="true"></i><b>${resultCount}</b> exibidos</span><small>${escapeHtml(operationalListCoverage())} · mais recentes primeiro</small></div>
        <div class="attendance-record-list" data-attendance-record-list>${renderRecordListContent()}</div>
        <div data-attendance-list-pagination>${renderOperationalPagination()}</div>
      </article>
    </section>`;
  }

  function renderWorkspace() {
    if (!state.root) return;
    const mountedAnalysis = state.root.querySelector("[data-attendance-own-analysis]");
    if (mountedAnalysis) destroyEmbeddedAnalysis(mountedAnalysis);
    state.root.innerHTML = `<div class="attendance-shell">${renderStoreHeader()}<main class="attendance-module-main">
      ${!state.selectedStoreId ? renderNoStore() : state.loading ? renderLoading() : state.loadError ? renderLoadError() : state.view === "analysis" ? `<div class="attendance-own-analysis" data-attendance-own-analysis></div>` : `${renderGoodMorningSeller()}<div class="attendance-layout">${renderForm()}${renderOverview()}</div>`}
    </main></div>`;
    syncPurchaseFields();
    if (state.view === "analysis" && state.selectedStoreId && !state.loading && !state.loadError) {
      const analysisRoot = state.root.querySelector("[data-attendance-own-analysis]");
      if (analysisRoot) {
        queueMicrotask(() => {
          if (!analysisRoot.isConnected || state.view !== "analysis") return;
          renderEmbeddedAnalysis({ root: analysisRoot, bridge: state.bridge, storeId: state.selectedStoreId }).catch((error) => {
            renderEmbeddedAttendanceState({ root: analysisRoot, destroyed: false }, "error", readableError(error));
          });
        });
      }
    }
  }

  function renderFilteredRegions() {
    if (!state.root || state.loading || state.loadError || !state.selectedStoreId) return;
    const list = state.root.querySelector("[data-attendance-record-list]");
    const count = state.root.querySelector("[data-attendance-result-count]");
    const status = state.root.querySelector(".attendance-list-status");
    const pagination = state.root.querySelector("[data-attendance-list-pagination]");
    const filterButton = state.root.querySelector('[data-attendance-action="toggle-filters"]');
    const filterBadge = state.root.querySelector("[data-attendance-filter-count]");
    if (list) list.innerHTML = renderRecordListContent();
    if (count) {
      const total = filteredRecords().length;
      count.textContent = `${total} registro${total === 1 ? "" : "s"} exibido${total === 1 ? "" : "s"}`;
    }
    if (status) {
      const total = filteredRecords().length;
      status.innerHTML = `<span><i class="fa-solid fa-layer-group" aria-hidden="true"></i><b>${total}</b> exibidos</span><small>${escapeHtml(operationalListCoverage())} · mais recentes primeiro</small>`;
    }
    if (pagination) pagination.innerHTML = renderOperationalPagination();
    const filterCount = attendanceFilterCount();
    if (filterButton) {
      filterButton.classList.toggle("is-active", state.filtersOpen || filterCount > 0);
      filterButton.setAttribute("aria-expanded", String(state.filtersOpen));
    }
    if (filterBadge) {
      filterBadge.hidden = filterCount === 0;
      filterBadge.textContent = String(filterCount);
    }
  }

  function resolveEmbeddedAnalysisRoot(target) {
    if (target instanceof Element) return target;
    if (typeof target === "string") return document.querySelector(target);
    return null;
  }

  function embeddedAttendanceStore(embeddedBridge, requestedStoreId) {
    const profile = embeddedBridge?.profile || {};
    const role = normalizeText(profile.role);
    const storeRoles = ["store", "client", "cliente", "loja"];
    const agencyRoles = ["technician", "agency", "agencia", "tecnico"];
    const storeId = String(requestedStoreId || "");
    const storesInBridge = (Array.isArray(embeddedBridge?.stores) ? embeddedBridge.stores : []).map(normalizeStore);
    const store = storesInBridge.find((item) => item.id === storeId) || null;
    if (!store) return { store: null, reason: "Cliente não encontrado neste escopo." };
    if (!["admin", ...storeRoles, ...agencyRoles].includes(role)) {
      return { store: null, reason: "Este perfil não tem permissão para analisar Atendimentos." };
    }

    const profileStoreId = String(firstDefined(profile.storeId, profile.store_id, storeRoles.includes(role) ? profile.id : "", ""));
    const profileId = String(firstDefined(profile.id, profile.user_id, profile.technicianId, profile.technician_id, ""));
    const initialAgencyId = String(embeddedBridge?.initialAgencyId || "");
    if (storeRoles.includes(role) && store.id !== profileStoreId) {
      return { store: null, reason: "Esta conta não pode analisar atendimentos de outro cliente." };
    }
    if (agencyRoles.includes(role) && !storeHasAgencyAccess(store, profileId)) {
      return { store: null, reason: "Este cliente não pertence à carteira desta agência." };
    }
    if (role === "admin" && initialAgencyId && !storeHasAgencyAccess(store, initialAgencyId)) {
      return { store: null, reason: "Este cliente não pertence à agência selecionada." };
    }
    if (!bridgeAttendanceAccessGranted(embeddedBridge) || store.attendanceEnabled !== true) {
      return { store, reason: "Atendimentos não está liberado para este cliente.", locked: true };
    }
    return { store, reason: "", locked: false };
  }

  function embeddedDateInput(value) {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Sao_Paulo",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(new Date(value));
    const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    return `${values.year}-${values.month}-${values.day}`;
  }

  function embeddedAttendanceRange(analysisState) {
    const period = String(analysisState?.period || analysisState || "30d");
    if (period === "all") return { startDate: null, endDate: null, label: "Todo o período" };
    const todayInput = embeddedDateInput(new Date());
    const today = new Date(`${todayInput}T12:00:00Z`);
    const start = new Date(today);
    if (period === "today") return { startDate: embeddedDateInput(today), endDate: embeddedDateInput(today), label: "Hoje" };
    if (period === "yesterday") {
      start.setUTCDate(start.getUTCDate() - 1);
      return { startDate: embeddedDateInput(start), endDate: embeddedDateInput(start), label: "Ontem" };
    }
    if (period === "currentWeek" || period === "lastWeek") {
      const weekday = today.getUTCDay() || 7;
      const currentWeekStart = new Date(today);
      currentWeekStart.setUTCDate(today.getUTCDate() - weekday + 1);
      if (period === "currentWeek") {
        return { startDate: embeddedDateInput(currentWeekStart), endDate: embeddedDateInput(today), label: "Esta semana" };
      }
      const previousWeekStart = new Date(currentWeekStart);
      previousWeekStart.setUTCDate(currentWeekStart.getUTCDate() - 7);
      const previousWeekEnd = new Date(currentWeekStart);
      previousWeekEnd.setUTCDate(currentWeekStart.getUTCDate() - 1);
      return { startDate: embeddedDateInput(previousWeekStart), endDate: embeddedDateInput(previousWeekEnd), label: "Semana passada" };
    }
    if (period === "currentMonth") {
      start.setUTCDate(1);
      return { startDate: embeddedDateInput(start), endDate: embeddedDateInput(today), label: "Mês atual" };
    }
    if (period === "previousMonth") {
      const previousEnd = new Date(today);
      previousEnd.setUTCDate(0);
      const previousStart = new Date(previousEnd);
      previousStart.setUTCDate(1);
      return { startDate: embeddedDateInput(previousStart), endDate: embeddedDateInput(previousEnd), label: "Mês anterior" };
    }
    if (period === "custom") {
      const startDate = String(analysisState?.customStart || "");
      const endDate = String(analysisState?.customEnd || "");
      return {
        startDate: startDate || null,
        endDate: endDate || null,
        label: startDate && endDate ? `${formatShortDate(startDate)} a ${formatShortDate(endDate)}` : "Período personalizado",
      };
    }
    const days = period === "7d" ? 7 : period === "15d" ? 15 : 30;
    start.setUTCDate(start.getUTCDate() - (days - 1));
    return {
      startDate: embeddedDateInput(start),
      endDate: embeddedDateInput(today),
      label: `Últimos ${days} dias`,
    };
  }

  function formatShortDate(value) {
    if (!value) return "";
    const date = new Date(`${value}T12:00:00Z`);
    if (Number.isNaN(date.getTime())) return value;
    return new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit", year: "numeric", timeZone: "UTC" }).format(date);
  }

  function embeddedAttendanceMetricData(records = []) {
    const purchases = records.filter((record) => record.tag === "purchase");
    const budgets = records.filter((record) => record.tag === "budget");
    const linkedLead = records.filter((record) => record.linkedLead?.linked).length;
    const linkedProspection = records.filter((record) => record.linkedProspection?.linked).length;
    const linked = records.filter((record) => record.linkedLead?.linked || record.linkedProspection?.linked).length;
    const revenue = purchases.reduce((sum, record) => sum + record.purchaseValue, 0);
    const serviceValue = records.reduce((sum, record) => sum + record.serviceValue, 0);
    return {
      total: records.length,
      budgets: budgets.length,
      purchases: purchases.length,
      other: records.length - budgets.length - purchases.length,
      conversion: records.length ? Math.round((purchases.length / records.length) * 1000) / 10 : 0,
      attendanceConversion: records.length ? Math.round((purchases.length / records.length) * 1000) / 10 : 0,
      revenue,
      ticket: purchases.length ? revenue / purchases.length : 0,
      serviceValue,
      averageServiceValue: records.length ? serviceValue / records.length : 0,
      linked,
      linkedLead,
      linkedProspection,
      both: records.filter((record) => record.linkedLead?.linked && record.linkedProspection?.linked).length,
      unmatched: records.length - linked,
      ambiguous: records.filter((record) => record.ambiguous).length,
      uniqueCustomers: new Set(records.map((record) => onlyDigits(record.phone) || onlyDigits(record.cpf)).filter(Boolean)).size,
      uniqueBuyers: new Set(purchases.map((record) => onlyDigits(record.phone) || onlyDigits(record.cpf)).filter(Boolean)).size,
    };
  }

  function normalizeEmbeddedAnalysis(raw, records = []) {
    const fallback = embeddedAttendanceMetricData(records);
    const payload = unwrapPayload(raw);
    const source = payload.metrics && typeof payload.metrics === "object" ? payload.metrics : {};
    const number = (...keys) => normalizeMoney(firstDefined(...keys.map((key) => source[key]), 0));
    const metrics = {
      total: number("total"),
      budgets: number("budgets"),
      purchases: number("purchases"),
      other: number("other"),
      uniqueCustomers: number("unique_customers", "uniqueCustomers") || fallback.uniqueCustomers,
      uniqueBuyers: number("unique_buyers", "uniqueBuyers"),
      conversion: number("conversion"),
      attendanceConversion: number("attendance_conversion", "attendanceConversion"),
      revenue: number("revenue"),
      ticket: number("ticket"),
      serviceValue: number("service_value", "serviceValue"),
      averageServiceValue: number("average_service_value", "averageServiceValue"),
      linked: number("linked"),
      linkedLead: number("linked_lead", "linkedLead"),
      linkedProspection: number("linked_prospection", "linkedProspection"),
      both: number("both"),
      unmatched: number("unmatched"),
      ambiguous: number("ambiguous"),
    };
    const professionalRows = Array.isArray(payload.professionals) ? payload.professionals : [];
    const professionals = professionalRows.map((item) => ({
      id: String(firstDefined(item.professional_id, item.professionalId, "")),
      name: String(firstDefined(item.name, item.professional_name, item.professionalName, "Não informado")),
      total: normalizeMoney(item.total),
      budgets: normalizeMoney(item.budgets),
      purchases: normalizeMoney(item.purchases),
      other: normalizeMoney(item.other),
      uniqueCustomers: normalizeMoney(firstDefined(item.unique_customers, item.uniqueCustomers, 0)),
      uniqueBuyers: normalizeMoney(firstDefined(item.unique_buyers, item.uniqueBuyers, 0)),
      conversion: normalizeMoney(item.conversion),
      attendanceConversion: normalizeMoney(firstDefined(item.attendance_conversion, item.attendanceConversion, 0)),
      revenue: normalizeMoney(item.revenue),
      ticket: normalizeMoney(item.ticket),
      serviceValue: normalizeMoney(firstDefined(item.service_value, item.serviceValue, 0)),
    }));
    return { metrics, professionals };
  }

  function formatAnalysisPercent(value) {
    return `${new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 1 }).format(Number(value || 0))}%`;
  }

  function embeddedAttendanceMetricCards(metrics) {
    const cards = [
      { label: "Clientes atendidos", value: metrics.total, icon: "fa-users", tone: "forest" },
      { label: "Compraram", value: metrics.purchases, icon: "fa-bag-shopping", tone: "lime" },
      { label: "Taxa de conversão", value: formatAnalysisPercent(metrics.attendanceConversion), icon: "fa-arrow-trend-up", tone: "mint" },
      { label: "Orçamentos", value: metrics.budgets, icon: "fa-file-invoice-dollar", tone: "sage" },
      { label: "Outros", value: metrics.other, icon: "fa-ellipsis", tone: "teal" },
      { label: "Faturamento", value: formatCurrency(metrics.revenue), icon: "fa-chart-line", tone: "emerald" },
    ];
    return `<section class="attendance-analysis-kpis" data-attendance-analysis-kpis aria-label="Indicadores da análise">${cards.map((card) => `<article class="attendance-analysis-kpi is-${card.tone}"><span><i class="fa-solid ${card.icon}" aria-hidden="true"></i></span><div><small>${card.label}</small><strong>${escapeHtml(card.value)}</strong></div></article>`).join("")}</section>`;
  }

  function embeddedAttendanceOutcomeMarkup(metrics) {
    const stages = [
      { label: "Atendimentos", value: metrics.total, icon: "fa-clipboard-check", tone: "forest" },
      { label: "Orçamentos", value: metrics.budgets, icon: "fa-file-invoice-dollar", tone: "emerald" },
      { label: "Compras", value: metrics.purchases, icon: "fa-bag-shopping", tone: "lime" },
      { label: "Outros", value: metrics.other, icon: "fa-ellipsis", tone: "sage" },
    ];
    return `<article class="attendance-analysis-card" data-attendance-analysis-outcomes><header><div><p class="attendance-eyebrow">Resultado</p><h3>Destino dos atendimentos</h3></div><span>${formatAnalysisPercent(metrics.attendanceConversion)} em compra</span></header><div class="attendance-analysis-funnel">${stages.map((stage) => { const width = stage.label === "Atendimentos" ? 100 : metrics.total ? Math.round((stage.value / metrics.total) * 100) : 0; return `<div class="attendance-funnel-row is-${stage.tone}"><span><i class="fa-solid ${stage.icon}" aria-hidden="true"></i>${stage.label}</span><div><i style="width:${Math.max(width, stage.value ? 5 : 0)}%"></i></div><strong>${stage.value}<small>${stage.label === "Atendimentos" ? "base" : `${width}%`}</small></strong></div>`; }).join("")}</div></article>`;
  }

  function embeddedAttendanceFinanceMarkup(metrics) {
    const rows = [
      ["Faturamento em compras", formatCurrency(metrics.revenue), "fa-sack-dollar"],
      ["Ticket médio", formatCurrency(metrics.ticket), "fa-receipt"],
      ["Valor dos atendimentos", formatCurrency(metrics.serviceValue), "fa-wallet"],
      ["Média por atendimento", formatCurrency(metrics.averageServiceValue), "fa-chart-simple"],
    ];
    return `<article class="attendance-analysis-card attendance-analysis-finance" data-attendance-analysis-finance><header><div><p class="attendance-eyebrow">Financeiro</p><h3>Receita e valor gerado</h3></div><span>Valores informados</span></header><div class="attendance-finance-grid">${rows.map(([label, value, icon], index) => `<div class="${index === 0 ? "is-featured" : ""}"><span><i class="fa-solid ${icon}" aria-hidden="true"></i>${label}</span><strong>${escapeHtml(value)}</strong></div>`).join("")}</div></article>`;
  }

  function renderEmbeddedAttendanceProfessionals(rows) {
    if (!rows.length) return `<div class="attendance-analysis-empty"><i class="fa-solid fa-user-tie" aria-hidden="true"></i><strong>Sem profissionais neste recorte</strong><span>Ajuste os filtros para ampliar a leitura.</span></div>`;
    const maxTotal = Math.max(...rows.map((item) => item.total), 1);
    return rows.map((item, index) => `<div class="attendance-professional-row"><b>${index + 1}</b><span class="attendance-professional-avatar">${escapeHtml(initials(item.name))}</span><div class="attendance-professional-copy"><strong>${escapeHtml(item.name)}</strong><span>${item.total} atendimento${item.total === 1 ? "" : "s"} · ${item.purchases} compra${item.purchases === 1 ? "" : "s"} · ${item.budgets} orçamento${item.budgets === 1 ? "" : "s"} · ${item.other} outro${item.other === 1 ? "" : "s"}</span><i><b style="width:${Math.max(Math.round((item.total / maxTotal) * 100), 5)}%"></b></i></div><div class="attendance-professional-result"><strong>${formatAnalysisPercent(item.attendanceConversion)}</strong><small>conversão</small><span>${escapeHtml(formatCurrency(item.revenue))}</span></div></div>`).join("");
  }

  function embeddedAttendanceProfessionalPanel(rows) {
    return `<article class="attendance-analysis-card" data-attendance-analysis-professionals><header><div><p class="attendance-eyebrow">Equipe</p><h3>Conversão individual por vendedor</h3></div><span>${rows.length} vendedor${rows.length === 1 ? "" : "es"}</span></header><div class="attendance-professional-list">${renderEmbeddedAttendanceProfessionals(rows)}</div></article>`;
  }

  function embeddedAttendanceDimensionsMarkup(metrics) {
    const items = [
      ["Clientes únicos", metrics.uniqueCustomers, "fa-users", "forest"],
      ["Com Lead", metrics.linkedLead, "fa-user-group", "emerald"],
      ["Com Prospecção", metrics.linkedProspection, "fa-phone", "mint"],
      ["Nos dois módulos", metrics.both, "fa-link", "lime"],
      ["Avulsos", metrics.unmatched, "fa-circle-dot", "sage"],
      ["Revisar vínculo", metrics.ambiguous, "fa-triangle-exclamation", "warning"],
    ];
    return `<article class="attendance-analysis-card" data-attendance-analysis-dimensions><header><div><p class="attendance-eyebrow">Etiquetas e vínculos</p><h3>Qualidade da base</h3></div><span>${metrics.linked} vinculados</span></header><div class="attendance-dimension-list">${items.map(([label, value, icon, tone]) => `<div class="is-${tone}"><span><i class="fa-solid ${icon}" aria-hidden="true"></i>${label}</span><strong>${value}</strong></div>`).join("")}</div></article>`;
  }

  function embeddedAttendanceFilterCount(analysisState) {
    return Number(analysisState.period !== "30d") + Number(analysisState.filters.tag !== "all") + Number(analysisState.filters.professional !== "all") + Number(analysisState.filters.link !== "all");
  }

  function embeddedAttendanceFilterPanel(analysisState) {
    const professionals = [...new Set([
      ...analysisState.professionalNames,
      ...analysisState.availableProfessionals.map((professional) => professional.name),
      ...analysisState.records.map((record) => record.professionalName),
    ].filter(Boolean))].sort((a, b) => a.localeCompare(b, "pt-BR"));
    return `<div id="attendanceAnalysisFilters" class="attendance-filter-panel attendance-analysis-filter-panel" ${analysisState.filtersOpen ? "" : "hidden"}>
      <label><span><i class="fa-solid fa-calendar-days" aria-hidden="true"></i>Dias analisados</span><select data-attendance-embedded-period aria-label="Período da análise"><option value="today" ${analysisState.period === "today" ? "selected" : ""}>Hoje</option><option value="yesterday" ${analysisState.period === "yesterday" ? "selected" : ""}>Ontem</option><option value="currentWeek" ${analysisState.period === "currentWeek" ? "selected" : ""}>Esta semana</option><option value="lastWeek" ${analysisState.period === "lastWeek" ? "selected" : ""}>Semana passada</option><option value="7d" ${analysisState.period === "7d" ? "selected" : ""}>Últimos 7 dias</option><option value="15d" ${analysisState.period === "15d" ? "selected" : ""}>Últimos 15 dias</option><option value="30d" ${analysisState.period === "30d" ? "selected" : ""}>Últimos 30 dias</option><option value="currentMonth" ${analysisState.period === "currentMonth" ? "selected" : ""}>Mês atual</option><option value="previousMonth" ${analysisState.period === "previousMonth" ? "selected" : ""}>Mês anterior</option><option value="custom" ${analysisState.period === "custom" ? "selected" : ""}>Escolher datas</option><option value="all" ${analysisState.period === "all" ? "selected" : ""}>Todo o período</option></select></label>
      <label class="attendance-analysis-date-input ${analysisState.period === "custom" ? "is-visible" : ""}"><span><i class="fa-solid fa-calendar-plus" aria-hidden="true"></i>Data inicial</span><input type="date" data-attendance-analysis-date="start" value="${escapeHtml(analysisState.customStart)}" ${analysisState.period === "custom" ? "" : "disabled"} /></label>
      <label class="attendance-analysis-date-input ${analysisState.period === "custom" ? "is-visible" : ""}"><span><i class="fa-solid fa-calendar-check" aria-hidden="true"></i>Data final</span><input type="date" data-attendance-analysis-date="end" value="${escapeHtml(analysisState.customEnd)}" ${analysisState.period === "custom" ? "" : "disabled"} /></label>
      <label><span><i class="fa-solid fa-tags" aria-hidden="true"></i>Tipo de atendimento</span><select data-attendance-analysis-filter="tag"><option value="all">Todos os tipos</option>${Object.entries(TAGS).map(([value, tag]) => `<option value="${value}" ${analysisState.filters.tag === value ? "selected" : ""}>${tag.label}</option>`).join("")}</select></label>
      <label><span><i class="fa-solid fa-user-tie" aria-hidden="true"></i>Profissional</span><select data-attendance-analysis-filter="professional"><option value="all">Todos os profissionais</option>${professionals.map((name) => `<option value="${escapeHtml(name)}" ${analysisState.filters.professional === name ? "selected" : ""}>${escapeHtml(name)}</option>`).join("")}</select></label>
      <label><span><i class="fa-solid fa-link" aria-hidden="true"></i>Origem vinculada</span><select data-attendance-analysis-filter="link"><option value="all">Todos os vínculos</option><option value="linked" ${analysisState.filters.link === "linked" ? "selected" : ""}>Lead ou Prospecção</option><option value="lead" ${analysisState.filters.link === "lead" ? "selected" : ""}>Somente Lead</option><option value="prospection" ${analysisState.filters.link === "prospection" ? "selected" : ""}>Somente Prospecção</option><option value="both" ${analysisState.filters.link === "both" ? "selected" : ""}>Lead e Prospecção</option><option value="standalone" ${analysisState.filters.link === "standalone" ? "selected" : ""}>Atendimento avulso</option><option value="review" ${analysisState.filters.link === "review" ? "selected" : ""}>Precisa revisar</option></select></label>
      <button class="attendance-clear-filters" type="button" data-attendance-analysis-clear><i class="fa-solid fa-rotate-left" aria-hidden="true"></i>Limpar filtros</button>
    </div>`;
  }

  function embeddedAttendanceRecordList(analysisState, records) {
    const recent = records.slice(0, 20);
    if (!recent.length) return `<div class="attendance-list-empty"><span><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i></span><strong>Nenhum atendimento encontrado</strong><p>Altere a busca ou os filtros para consultar outro recorte.</p></div>`;
    return recent.map((record) => renderRecord(record, { compact: true })).join("");
  }

  function renderEmbeddedAttendanceContent(analysisState) {
    if (analysisState.destroyed || !analysisState.root.isConnected) return;
    const records = analysisState.records;
    const metrics = analysisState.metrics || embeddedAttendanceMetricData(records);
    const range = embeddedAttendanceRange(analysisState);
    const filterCount = embeddedAttendanceFilterCount(analysisState);
    const sourceLabel = `${analysisState.detailTotal} atendimento${analysisState.detailTotal === 1 ? "" : "s"} no recorte`;
    analysisState.root.removeAttribute("aria-busy");
    analysisState.root.innerHTML = `<section class="attendance-analysis">
      <header class="attendance-analysis-header"><div class="attendance-analysis-title"><span class="attendance-analysis-title-icon"><i class="fa-solid fa-chart-line" aria-hidden="true"></i></span><div><p class="attendance-eyebrow">Análise de Atendimentos</p><h2>${escapeHtml(analysisState.store.name)}</h2><span>${escapeHtml(range.label)} · ${escapeHtml(sourceLabel)}</span></div></div><div class="attendance-analysis-header-actions"><button class="attendance-export-button" type="button" data-attendance-analysis-export ${analysisState.exporting ? "disabled" : ""}><i class="fa-solid ${analysisState.exporting ? "fa-circle-notch fa-spin" : "fa-file-arrow-down"}" aria-hidden="true"></i><span>${analysisState.exporting ? "Preparando" : "Exportar relatório"}</span></button><button class="attendance-icon-button" type="button" data-attendance-embedded-refresh aria-label="Atualizar análise" title="Atualizar"><i class="fa-solid fa-arrow-rotate-right" aria-hidden="true"></i></button><span class="attendance-scope-badge"><i class="fa-solid fa-shield-halved" aria-hidden="true"></i>Dados desta loja</span></div></header>
      ${embeddedAttendanceMetricCards(metrics)}
      <div class="attendance-analysis-grid attendance-analysis-grid--summary">${embeddedAttendanceOutcomeMarkup(metrics)}${embeddedAttendanceFinanceMarkup(metrics)}</div>
      <div class="attendance-analysis-grid attendance-analysis-grid--detail">${embeddedAttendanceProfessionalPanel(analysisState.professionals)}${embeddedAttendanceDimensionsMarkup(metrics)}</div>
      <article class="attendance-panel attendance-list-panel attendance-analysis-list-panel"><header class="attendance-list-header"><div class="attendance-list-heading"><p class="attendance-eyebrow">Detalhamento</p><h2>Atendimentos do período</h2><span data-attendance-analysis-count>${analysisState.detailTotal} resultado${analysisState.detailTotal === 1 ? "" : "s"} · exibindo até 20</span></div><div class="attendance-list-tools"><label class="attendance-search"><span class="attendance-sr-only">Buscar na análise</span><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i><input type="search" data-attendance-analysis-search value="${escapeHtml(analysisState.filters.search)}" placeholder="Nome, telefone, CPF, descrição ou OS" aria-label="Buscar na análise de atendimentos" /></label><button class="attendance-filter-button${analysisState.filtersOpen || filterCount ? " is-active" : ""}" type="button" data-attendance-analysis-toggle aria-expanded="${String(analysisState.filtersOpen)}" aria-controls="attendanceAnalysisFilters"><i class="fa-solid fa-sliders" aria-hidden="true"></i><span>Filtros completos</span><b data-attendance-analysis-filter-count ${filterCount ? "" : "hidden"}>${filterCount}</b></button></div></header>${embeddedAttendanceFilterPanel(analysisState)}<div class="attendance-list-status" data-attendance-analysis-summary><span><i class="fa-solid fa-layer-group" aria-hidden="true"></i><b>${Math.min(records.length, 20)}</b> exibidos</span><small>${analysisState.detailTotal} no recorte · mais recentes primeiro</small></div><div class="attendance-record-list" data-attendance-analysis-list>${embeddedAttendanceRecordList(analysisState, records)}</div></article>
    </section>`;
  }

  function renderEmbeddedAttendanceState(state, kind, message) {
    if (state.destroyed || !state.root.isConnected) return;
    state.root.removeAttribute("aria-busy");
    if (kind === "locked") {
      state.root.innerHTML = `<section class="attendance-context-empty" aria-live="polite"><span class="attendance-context-empty-icon"><i class="fa-solid fa-lock" aria-hidden="true"></i></span><p class="attendance-eyebrow">Recurso não liberado</p><h2>Atendimentos não liberado</h2><p>${escapeHtml(message)}</p></section>`;
      return;
    }
    state.root.innerHTML = `<section class="attendance-context-empty attendance-context-empty--error" role="alert"><span class="attendance-context-empty-icon"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span><p class="attendance-eyebrow">Análise indisponível</p><h2>Não foi possível carregar Atendimentos</h2><p>${escapeHtml(message)}</p><button class="attendance-secondary-button" type="button" data-attendance-embedded-retry><i class="fa-solid fa-arrow-rotate-right" aria-hidden="true"></i>Tentar novamente</button></section>`;
  }

  function embeddedAnalysisRequestArgs(state) {
    const range = embeddedAttendanceRange(state);
    if (range.startDate && range.endDate && range.startDate > range.endDate) {
      throw new Error("A data inicial não pode ser posterior à data final.");
    }
    return {
      p_store_id: state.storeId,
      p_search: String(state.filters.search || "").trim() || null,
      p_tag: state.filters.tag === "all" ? null : state.filters.tag,
      p_professional_id: null,
      p_professional_name: state.filters.professional === "all" ? null : state.filters.professional,
      p_link_status: state.filters.link === "all" ? null : state.filters.link === "linked" ? "matched" : state.filters.link,
      p_start_date: range.startDate,
      p_end_date: range.endDate,
    };
  }

  async function fetchEmbeddedAttendanceRecords(state, requestGeneration, { maxRecords = EMBEDDED_ANALYSIS_PAGE_SIZE } = {}) {
    const requestArgs = embeddedAnalysisRequestArgs(state);
    const records = [];
    let offset = 0;
    let total = 0;
    let hasMore = true;
    while (hasMore && records.length < maxRecords) {
      const raw = await state.bridge.rpc(DEFAULT_RPC.list, {
        ...requestArgs,
        p_limit: Math.min(EMBEDDED_ANALYSIS_PAGE_SIZE, maxRecords - records.length),
        p_offset: offset,
      });
      if (state.destroyed || requestGeneration !== state.generation) return null;
      const page = unwrapPayload(raw);
      const responseStoreId = String(firstDefined(page.store_id, page.storeId, state.storeId));
      if (responseStoreId !== state.storeId) throw new Error("A consulta retornou dados de outro cliente e foi bloqueada por segurança.");
      const items = firstDefined(page.items, page.attendances, page.records, []);
      const itemRows = Array.isArray(items) ? items : [];
      if (itemRows.some((item) => String(firstDefined(item?.store_id, item?.storeId, state.storeId)) !== state.storeId)) {
        throw new Error("A consulta retornou dados de outro cliente e foi bloqueada por segurança.");
      }
      const pageRows = itemRows
        .map((item, index) => normalizeRecord({ ...item, store_id: firstDefined(item?.store_id, item?.storeId, state.storeId) }, offset + index))
        .filter((record) => record.storeId === state.storeId);
      records.push(...pageRows);
      total = Number(firstDefined(page.total, records.length)) || records.length;
      hasMore = Boolean(firstDefined(page.has_more, page.hasMore, offset + pageRows.length < total));
      if (!pageRows.length) break;
      offset += pageRows.length;
    }
    return {
      records: records.slice(0, maxRecords),
      total,
      truncated: hasMore || total > maxRecords,
    };
  }

  async function loadEmbeddedAttendanceAnalysis(state) {
    if (state.searchTimer) {
      global.clearTimeout(state.searchTimer);
      state.searchTimer = 0;
    }
    const requestGeneration = ++state.generation;
    state.root.setAttribute("aria-busy", "true");
    if (!state.hasLoaded) {
      state.root.innerHTML = `<section class="attendance-workspace-loading" role="status" aria-live="polite"><span class="attendance-spinner" aria-hidden="true"></span><div><strong>Carregando análise de Atendimentos</strong><span>Calculando conversões e resultados de ${escapeHtml(state.store.name)}.</span></div></section>`;
    } else {
      state.root.querySelector(".attendance-analysis")?.classList.add("is-refreshing");
    }
    try {
      if (!state.accessVerified) {
        const workspaceRaw = await state.bridge.rpc(DEFAULT_RPC.workspace, { p_store_id: state.storeId });
        if (state.destroyed || requestGeneration !== state.generation) return;
        const workspacePayload = unwrapPayload(workspaceRaw);
        const returnedStoreId = String(firstDefined(workspacePayload.store?.id, workspacePayload.store_id, workspacePayload.storeId, state.storeId));
        if (returnedStoreId !== state.storeId) throw new Error("A consulta retornou dados de outro cliente e foi bloqueada por segurança.");
        const workspace = normalizeWorkspace(workspaceRaw);
        state.availableProfessionals = workspace.professionals;
        state.professionalNames = workspace.professionals.map((professional) => professional.name);
        state.accessVerified = true;
      }
      const [page, analysisRaw] = await Promise.all([
        fetchEmbeddedAttendanceRecords(state, requestGeneration),
        state.bridge.rpc(DEFAULT_RPC.analysis, embeddedAnalysisRequestArgs(state)),
      ]);
      if (!page || state.destroyed || requestGeneration !== state.generation) return;
      const analysisPayload = unwrapPayload(analysisRaw);
      const analysisStoreId = String(firstDefined(analysisPayload.store_id, analysisPayload.storeId, state.storeId));
      if (analysisStoreId !== state.storeId) throw new Error("A análise retornou dados de outro cliente e foi bloqueada por segurança.");
      const analysis = normalizeEmbeddedAnalysis(analysisRaw, page.records);
      state.records = page.records;
      state.detailTotal = page.total;
      state.truncated = page.truncated;
      state.metrics = analysis.metrics;
      state.professionals = analysis.professionals;
      state.professionalNames = [...new Set([
        ...state.professionalNames,
        ...analysis.professionals.map((professional) => professional.name),
      ].filter(Boolean))].sort((a, b) => a.localeCompare(b, "pt-BR"));
      state.hasLoaded = true;
      renderEmbeddedAttendanceContent(state);
    } catch (error) {
      if (state.destroyed || requestGeneration !== state.generation) return;
      renderEmbeddedAttendanceState(state, isEntitlementError(error) ? "locked" : "error", readableError(error));
    }
  }

  function embeddedCsvCell(value) {
    let text = String(value ?? "");
    if (/^[=+\-@]/.test(text.trim())) text = `'${text}`;
    return `"${text.replace(/"/g, '""')}"`;
  }

  function embeddedReportDateTime(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return new Intl.DateTimeFormat("pt-BR", {
      day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit",
    }).format(date);
  }

  function embeddedReportFilterLabel(state) {
    const filters = [];
    if (state.filters.tag !== "all") filters.push(`Tipo: ${TAGS[state.filters.tag]?.label || state.filters.tag}`);
    if (state.filters.professional !== "all") filters.push(`Vendedor: ${state.filters.professional}`);
    if (state.filters.link !== "all") filters.push(`Vínculo: ${state.filters.link}`);
    if (state.filters.search.trim()) filters.push(`Busca: ${state.filters.search.trim()}`);
    return filters.join(" | ") || "Sem filtros adicionais";
  }

  function buildEmbeddedAttendanceCsv(state, records) {
    const metrics = state.metrics || embeddedAttendanceMetricData(records);
    const range = embeddedAttendanceRange(state);
    const rows = [
      ["RELATÓRIO DE ATENDIMENTOS"],
      ["Loja", state.store.name],
      ["Período", range.label],
      ["Filtros", embeddedReportFilterLabel(state)],
      ["Gerado em", embeddedReportDateTime(new Date())],
      [],
      ["RESUMO"],
      ["Clientes atendidos", metrics.total],
      ["Compraram", metrics.purchases],
      ["Taxa de conversão", formatAnalysisPercent(metrics.attendanceConversion)],
      ["Clientes únicos", metrics.uniqueCustomers],
      ["Orçamentos", metrics.budgets],
      ["Outros", metrics.other],
      ["Faturamento", formatCurrency(metrics.revenue)],
      ["Ticket médio", formatCurrency(metrics.ticket)],
      [],
      ["DESEMPENHO POR VENDEDOR"],
      ["Vendedor", "Atendimentos", "Compras", "Conversão", "Orçamentos", "Outros", "Clientes únicos", "Faturamento", "Ticket médio"],
      ...state.professionals.map((item) => [item.name, item.total, item.purchases, formatAnalysisPercent(item.attendanceConversion), item.budgets, item.other, item.uniqueCustomers, formatCurrency(item.revenue), formatCurrency(item.ticket)]),
      [],
      ["DETALHAMENTO"],
      ["Data", "Cliente", "Telefone", "CPF", "Vendedor", "Tipo", "Valor do atendimento", "Valor da compra", "OS", "Vínculo", "Descrição"],
      ...records.map((record) => [
        embeddedReportDateTime(record.createdAt),
        record.customerName,
        record.phone,
        record.cpf,
        record.professionalName,
        TAGS[record.tag]?.label || "Outro",
        formatCurrency(record.serviceValue),
        record.tag === "purchase" ? formatCurrency(record.purchaseValue) : "",
        record.serviceOrder,
        record.linkedLead?.linked && record.linkedProspection?.linked ? "Lead e Prospecção" : record.linkedLead?.linked ? "Lead" : record.linkedProspection?.linked ? "Prospecção" : record.ambiguous ? "Revisar" : "Avulso",
        record.description,
      ]),
    ];
    return `\uFEFF${rows.map((row) => row.map(embeddedCsvCell).join(";")).join("\r\n")}`;
  }

  async function exportEmbeddedAttendanceReport(state) {
    if (state.exporting) return;
    state.exporting = true;
    const button = state.root.querySelector("[data-attendance-analysis-export]");
    if (button) {
      button.disabled = true;
      button.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin" aria-hidden="true"></i><span>Preparando</span>';
    }
    try {
      const page = await fetchEmbeddedAttendanceRecords(state, state.generation, { maxRecords: EMBEDDED_EXPORT_MAX_RECORDS });
      if (!page) return;
      const csv = buildEmbeddedAttendanceCsv(state, page.records);
      const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      const safeStore = normalizeText(state.store.name).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "loja";
      link.href = url;
      link.download = `relatorio-atendimentos-${safeStore}-${embeddedDateInput(new Date())}.csv`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      global.setTimeout(() => URL.revokeObjectURL(url), 1000);
      state.bridge?.notify?.(page.truncated ? `Relatório exportado com os ${EMBEDDED_EXPORT_MAX_RECORDS} registros mais recentes.` : "Relatório de Atendimentos exportado.", page.truncated ? "warning" : "success");
    } catch (error) {
      state.bridge?.notify?.(readableError(error), "error");
    } finally {
      state.exporting = false;
      const currentButton = state.root.querySelector("[data-attendance-analysis-export]");
      if (currentButton) {
        currentButton.disabled = false;
        currentButton.innerHTML = '<i class="fa-solid fa-file-arrow-down" aria-hidden="true"></i><span>Exportar relatório</span>';
      }
    }
  }

  async function renderEmbeddedAnalysis({ root: target, bridge: embeddedBridge, storeId } = {}) {
    const mount = resolveEmbeddedAnalysisRoot(target);
    if (!mount) throw new Error("Área de análise embutida de Atendimentos não encontrada.");
    destroyEmbeddedAnalysis(mount);
    if (!embeddedBridge || typeof embeddedBridge.rpc !== "function") {
      throw new Error("Integração RPC de Atendimentos não configurada.");
    }

    const access = embeddedAttendanceStore(embeddedBridge, storeId);
    const defaultRange = embeddedAttendanceRange({ period: "30d" });
    const embeddedState = {
      root: mount,
      bridge: embeddedBridge,
      storeId: String(storeId || ""),
      store: access.store,
      period: "30d",
      customStart: defaultRange.startDate,
      customEnd: defaultRange.endDate,
      records: [],
      metrics: null,
      professionals: [],
      availableProfessionals: [],
      professionalNames: [],
      detailTotal: 0,
      truncated: false,
      filtersOpen: false,
      filters: { search: "", tag: "all", professional: "all", link: "all" },
      accessVerified: false,
      hasLoaded: false,
      exporting: false,
      searchTimer: 0,
      generation: 0,
      destroyed: false,
      onClick: null,
      onInput: null,
      onChange: null,
    };
    embeddedAnalysisStates.set(mount, embeddedState);
    mount.classList.add("attendance-embedded-analysis");
    embeddedState.onClick = async (event) => {
      const copyButton = event.target.closest("[data-attendance-copy-phone]");
      if (copyButton) {
        const phone = String(copyButton.dataset.attendanceCopyPhone || "");
        if (!phone) return;
        try {
          await global.navigator.clipboard.writeText(phone);
          embeddedState.bridge?.notify?.("Telefone copiado.", "success");
        } catch {
          embeddedState.bridge?.notify?.("Não foi possível copiar o telefone neste navegador.", "warning");
        }
        return;
      }
      if (event.target.closest("[data-attendance-embedded-retry], [data-attendance-embedded-refresh]")) {
        loadEmbeddedAttendanceAnalysis(embeddedState);
        return;
      }
      if (event.target.closest("[data-attendance-analysis-export]")) {
        await exportEmbeddedAttendanceReport(embeddedState);
        return;
      }
      const toggle = event.target.closest("[data-attendance-analysis-toggle]");
      if (toggle) {
        embeddedState.filtersOpen = !embeddedState.filtersOpen;
        const panel = mount.querySelector("#attendanceAnalysisFilters");
        if (panel) panel.hidden = !embeddedState.filtersOpen;
        toggle.classList.toggle("is-active", embeddedState.filtersOpen || embeddedAttendanceFilterCount(embeddedState) > 0);
        toggle.setAttribute("aria-expanded", String(embeddedState.filtersOpen));
        return;
      }
      if (event.target.closest("[data-attendance-analysis-clear]")) {
        embeddedState.filters = { search: "", tag: "all", professional: "all", link: "all" };
        embeddedState.period = "30d";
        const range = embeddedAttendanceRange(embeddedState);
        embeddedState.customStart = range.startDate;
        embeddedState.customEnd = range.endDate;
        embeddedState.filtersOpen = true;
        await loadEmbeddedAttendanceAnalysis(embeddedState);
      }
    };
    embeddedState.onInput = (event) => {
      const input = event.target.closest("[data-attendance-analysis-search]");
      if (!input || !mount.contains(input)) return;
      embeddedState.filters.search = input.value;
      if (embeddedState.searchTimer) global.clearTimeout(embeddedState.searchTimer);
      embeddedState.searchTimer = global.setTimeout(() => {
        embeddedState.searchTimer = 0;
        loadEmbeddedAttendanceAnalysis(embeddedState);
      }, 420);
    };
    embeddedState.onChange = (event) => {
      const selector = event.target.closest("[data-attendance-embedded-period]");
      if (selector && mount.contains(selector)) {
        const period = selector.value;
        if (!["today", "yesterday", "currentWeek", "lastWeek", "7d", "15d", "30d", "currentMonth", "previousMonth", "custom", "all"].includes(period)) return;
        embeddedState.period = period;
        embeddedState.filtersOpen = true;
        if (period === "custom") {
          renderEmbeddedAttendanceContent(embeddedState);
          mount.querySelector('[data-attendance-analysis-date="start"]')?.focus();
        }
        loadEmbeddedAttendanceAnalysis(embeddedState);
        return;
      }
      const dateInput = event.target.closest("[data-attendance-analysis-date]");
      if (dateInput && mount.contains(dateInput)) {
        if (dateInput.dataset.attendanceAnalysisDate === "start") embeddedState.customStart = dateInput.value;
        if (dateInput.dataset.attendanceAnalysisDate === "end") embeddedState.customEnd = dateInput.value;
        embeddedState.period = "custom";
        if (embeddedState.customStart && embeddedState.customEnd) loadEmbeddedAttendanceAnalysis(embeddedState);
        return;
      }
      const filter = event.target.closest("[data-attendance-analysis-filter]");
      if (!filter || !mount.contains(filter)) return;
      const key = filter.dataset.attendanceAnalysisFilter;
      if (!key || !(key in embeddedState.filters)) return;
      embeddedState.filters[key] = filter.value;
      loadEmbeddedAttendanceAnalysis(embeddedState);
    };
    mount.addEventListener("click", embeddedState.onClick);
    mount.addEventListener("input", embeddedState.onInput);
    mount.addEventListener("change", embeddedState.onChange);

    if (!access.store || access.reason) {
      renderEmbeddedAttendanceState(embeddedState, access.locked ? "locked" : "error", access.reason || "Cliente indisponível.");
      return { storeId: embeddedState.storeId, destroy: () => embeddedAnalysisStates.get(mount) === embeddedState && destroyEmbeddedAnalysis(mount) };
    }
    await loadEmbeddedAttendanceAnalysis(embeddedState);
    return { storeId: embeddedState.storeId, destroy: () => embeddedAnalysisStates.get(mount) === embeddedState && destroyEmbeddedAnalysis(mount) };
  }

  function destroyEmbeddedAnalysis(target) {
    const mount = resolveEmbeddedAnalysisRoot(target);
    if (!mount) return false;
    const embeddedState = embeddedAnalysisStates.get(mount);
    if (embeddedState) {
      embeddedState.destroyed = true;
      embeddedState.generation += 1;
      if (embeddedState.searchTimer) global.clearTimeout(embeddedState.searchTimer);
      if (embeddedState.onClick) mount.removeEventListener("click", embeddedState.onClick);
      if (embeddedState.onInput) mount.removeEventListener("input", embeddedState.onInput);
      if (embeddedState.onChange) mount.removeEventListener("change", embeddedState.onChange);
      embeddedAnalysisStates.delete(mount);
    }
    mount.classList.remove("attendance-embedded-analysis");
    mount.removeAttribute("aria-busy");
    mount.replaceChildren();
    return Boolean(embeddedState);
  }

  function syncPurchaseFields() {
    if (!state.root) return;
    const form = state.root.querySelector("[data-attendance-form]");
    if (!form) return;
    const selected = form.querySelector('input[name="tag"]:checked')?.value || "budget";
    const purchaseArea = form.querySelector("[data-attendance-purchase-fields]");
    const purchaseValue = form.elements.purchase_value;
    const serviceOrder = form.elements.service_order;
    const isPurchase = selected === "purchase";
    if (purchaseArea) purchaseArea.hidden = !isPurchase;
    [purchaseValue, serviceOrder].forEach((field) => {
      if (!field) return;
      field.disabled = !isPurchase;
      field.required = isPurchase;
      if (!isPurchase) field.value = "";
    });
  }

  function setFormError(message = "") {
    const element = state.root?.querySelector("[data-attendance-form-error]");
    if (!element) return;
    element.hidden = !message;
    element.innerHTML = message ? `<i class="fa-solid fa-circle-exclamation" aria-hidden="true"></i><span>${escapeHtml(message)}</span>` : "";
  }

  function setFormBusy(busy) {
    const form = state.root?.querySelector("[data-attendance-form]");
    const button = state.root?.querySelector("[data-attendance-save]");
    if (form) form.setAttribute("aria-busy", String(Boolean(busy)));
    if (button) button.disabled = Boolean(busy) || registeredProfessionalOptions().length === 0;
  }

  function createIdempotencyKey() {
    if (global.crypto?.randomUUID) return global.crypto.randomUUID();
    return `attendance-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }

  function validateForm(form) {
    const values = Object.fromEntries(new FormData(form).entries());
    const submittedProfessionalName = String(values.professional_name || "").trim();
    const professionalName = registeredProfessionalOptions().find(
      (name) => normalizeText(name) === normalizeText(submittedProfessionalName),
    ) || "";
    const attendedOn = String(values.attended_on || "").trim();
    const dateLimits = attendanceDateLimits();
    const customerName = String(values.customer_name || "").trim();
    const phone = onlyDigits(values.phone).replace(/^55(?=\d{10,11}$)/, "");
    const cpf = formatCpf(values.cpf);
    const description = String(values.description || "").trim();
    const tag = normalizeTag(values.tag);
    const serviceValue = normalizeMoney(values.service_value);
    const purchaseValue = normalizeMoney(values.purchase_value);
    const serviceOrder = String(values.service_order || "").trim();

    if (!professionalName) throw new Error("Selecione um profissional cadastrado para esta empresa.");
    if (!isValidAttendanceDate(attendedOn, dateLimits)) {
      if (!attendanceRetroactiveDatesGranted()) {
        throw new Error("Registre apenas atendimentos de hoje. Datas retroativas requerem a atualização do sistema.");
      }
      throw new Error(`Informe uma data de atendimento entre ${formatShortDate(dateLimits.min)} e hoje.`);
    }
    if (!customerName) throw new Error("Informe o nome do cliente.");
    if (!phone && !cpf) throw new Error("Informe o telefone ou o CPF do cliente.");
    if (phone && ![10, 11].includes(phone.length)) throw new Error("Informe um telefone válido com DDD.");
    if (cpf && !isValidCpf(cpf)) throw new Error("Informe um CPF válido.");
    if (!description) throw new Error("Descreva o atendimento realizado.");
    if (serviceValue < 0) throw new Error("O valor do atendimento não pode ser negativo.");
    if (tag === "purchase" && purchaseValue <= 0) throw new Error("Informe o valor da compra.");
    if (tag === "purchase" && !serviceOrder) throw new Error("Informe a ordem de serviço da compra.");

    return { attendedOn, professionalName, customerName, phone, cpf, description, tag, serviceValue, purchaseValue, serviceOrder };
  }

  function normalizeSaveFeedback(raw, submitted) {
    const payload = unwrapPayload(raw);
    const attendanceSource = payload.attendance || payload.record || payload.saved_attendance || payload;
    const links = payload.links && typeof payload.links === "object" ? payload.links : {};
    const linkedLead = normalizeLink({ ...attendanceSource, ...payload, links }, "lead");
    const linkedProspection = normalizeLink({ ...attendanceSource, ...payload, links }, "prospection");
    const attendance = normalizeRecord({
      ...attendanceSource,
      links,
      professional_name: firstDefined(attendanceSource.professional_name, submitted.professionalName),
    });
    attendance.linkedLead = linkedLead;
    attendance.linkedProspection = linkedProspection;
    const bonusRaw = firstDefined(payload.bonus_eligible, payload.bonusEligible, attendanceSource.bonus_eligible, attendanceSource.bonusEligible);
    const bonusAmountRaw = firstDefined(
      payload.bonus_awarded_amount,
      payload.bonusAwardedAmount,
      payload.bonus_amount,
      payload.bonusAmount,
      attendanceSource.bonus_awarded_amount,
      attendanceSource.bonusAwardedAmount,
      attendanceSource.bonus_amount,
      attendanceSource.bonusAmount,
    );
    const ambiguousValue = links.ambiguous;
    const ambiguous = normalizeBoolean(ambiguousValue) === true
      || (ambiguousValue && typeof ambiguousValue === "object" && Object.values(ambiguousValue).some((value) => normalizeBoolean(value) === true))
      || linkedLead.ambiguous
      || linkedProspection.ambiguous;
    const arrayCount = (value) => Array.isArray(value) ? value.length : undefined;
    const candidateCounts = {
      lead: Number(firstDefined(
        links.lead_candidate_count,
        links.lead_candidates_count,
        links.lead_match_count,
        links.candidate_counts?.lead,
        arrayCount(links.lead_candidates),
        linkedLead.candidateCount || undefined,
        0,
      )) || 0,
      prospection: Number(firstDefined(
        links.prospection_candidate_count,
        links.prospection_candidates_count,
        links.prospection_match_count,
        links.candidate_counts?.prospection,
        arrayCount(links.prospection_candidates),
        linkedProspection.candidateCount || undefined,
        0,
      )) || 0,
    };
    return {
      attendance,
      professionalName: String(firstDefined(payload.performed_by, payload.professional_name, attendanceSource.professional_name, submitted.professionalName)),
      linkedLead,
      linkedProspection,
      prospectionProfessionalName: String(firstDefined(
        payload.prospection_professional_name,
        payload.credited_professional_name,
        payload.prospection_professional?.name,
        attendanceSource.prospection_professional_name,
        attendanceSource.credited_professional_name,
        attendanceSource.creditedProfessionalName,
        "",
      )),
      bonusEligible: normalizeBoolean(bonusRaw),
      bonusAmount: bonusAmountRaw == null ? null : normalizeMoney(bonusAmountRaw),
      bonusReason: String(firstDefined(payload.bonus_reason, payload.bonus_message, attendanceSource.bonus_reason, "")),
      ambiguous,
      candidateCounts,
      message: String(firstDefined(payload.message, "")),
      idempotentReplay: normalizeBoolean(firstDefined(payload.idempotent_replay, payload.idempotentReplay)) === true,
    };
  }

  function isMissingRpcError(error, functionName) {
    const expectedName = String(functionName || "").trim().toLowerCase();
    const message = [error?.message, error?.details, error?.hint]
      .filter((value) => value !== undefined && value !== null)
      .map(String)
      .join(" ")
      .toLowerCase();
    if (!expectedName || !message.includes(expectedName)) return false;

    const code = String(error?.code || "").trim().toUpperCase();
    return code === "PGRST202"
      || code === "42883"
      || message.includes("could not find the function")
      || (message.includes("function") && message.includes("does not exist"));
  }

  function legacySaveArgs(args) {
    const attendedOn = String(args?.p_attended_on || "").trim();
    if (attendedOn !== embeddedDateInput(new Date())) {
      throw new Error("Datas retroativas requerem a atualização do sistema. Por enquanto, registre apenas atendimentos de hoje.");
    }
    const legacyArgs = { ...args };
    delete legacyArgs.p_attended_on;
    return legacyArgs;
  }

  function rememberLegacyAttendanceSave(legacyName) {
    state.legacyAttendanceSaveRequired = true;
    state.bridge.attendanceRetroactiveDatesGranted = false;
    state.bridge.attendanceRpcNames = {
      ...(state.bridge.attendanceRpcNames || {}),
      save: legacyName || DEFAULT_RPC.saveLegacy,
    };
  }

  async function rpc(operation, args) {
    const custom = state.bridge?.attendances;
    if (operation === "workspace" && typeof custom?.load === "function") return custom.load(args);
    if (operation === "save" && typeof custom?.save === "function") return custom.save(args);
    if (operation === "list" && typeof custom?.list === "function") return custom.list(args);
    if (typeof state.bridge?.rpc !== "function") throw new Error("Integração RPC de Atendimentos não configurada.");
    const names = { ...DEFAULT_RPC, ...(state.bridge?.attendanceRpcNames || state.bridge?.rpcNames?.attendances || {}) };
    const legacyName = names.saveLegacy || DEFAULT_RPC.saveLegacy;
    const rpcName = operation === "save" && state.legacyAttendanceSaveRequired
      ? legacyName
      : names[operation];
    if (operation !== "save") return state.bridge.rpc(rpcName, args);

    if (rpcName === legacyName || rpcName === DEFAULT_RPC.saveLegacy) {
      rememberLegacyAttendanceSave(legacyName);
      return state.bridge.rpc(rpcName, legacySaveArgs(args));
    }

    try {
      return await state.bridge.rpc(rpcName, args);
    } catch (error) {
      if (rpcName !== DEFAULT_RPC.save || !isMissingRpcError(error, rpcName)) throw error;
      rememberLegacyAttendanceSave(legacyName);
      return state.bridge.rpc(legacyName, legacySaveArgs(args));
    }
  }

  function attendanceProfessionalId(name) {
    if (!name || name === "all") return null;
    const professional = registeredProfessionalRecords().find((item) => normalizeText(item.name) === normalizeText(name));
    const id = String(professional?.id || "");
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id) ? id : null;
  }

  function normalizeOperationalPage(raw, storeId, offset = 0) {
    const page = unwrapPayload(raw);
    const responseStoreId = String(firstDefined(page.store_id, page.storeId, storeId));
    if (responseStoreId !== storeId) throw new Error("A consulta retornou dados de outro cliente e foi bloqueada por segurança.");
    const items = firstDefined(page.items, page.attendances, page.records, []);
    const rows = Array.isArray(items) ? items : [];
    if (rows.some((item) => String(firstDefined(item?.store_id, item?.storeId, storeId)) !== storeId)) {
      throw new Error("A consulta retornou dados de outro cliente e foi bloqueada por segurança.");
    }
    const records = rows
      .map((item, index) => normalizeRecord({ ...item, store_id: firstDefined(item?.store_id, item?.storeId, storeId) }, offset + index))
      .filter((record) => record.storeId === storeId);
    const total = Number(firstDefined(page.total, records.length)) || records.length;
    return {
      records,
      total,
      hasMore: Boolean(firstDefined(page.has_more, page.hasMore, offset + records.length < total)),
    };
  }

  async function loadOperationalList({ append = false } = {}) {
    if (!state.active || !state.selectedStoreId) return;
    if (append && (state.listLoading || !state.listHasMore)) return;
    const storeId = state.selectedStoreId;
    const requestGeneration = ++state.listGeneration;
    const offset = append ? state.listRecords.length : 0;
    const range = embeddedAttendanceRange(state.filters.period);
    const linkStatus = state.filters.link === "linked"
      ? "matched"
      : ["standalone", "review"].includes(state.filters.link) ? state.filters.link : null;
    const professionalId = attendanceProfessionalId(state.filters.professional);
    state.listLoading = true;
    state.listError = "";
    renderFilteredRegions();
    try {
      const raw = await rpc("list", {
        p_store_id: storeId,
        p_search: state.filters.search.trim() || null,
        p_tag: state.filters.tag === "all" ? null : state.filters.tag,
        p_professional_id: professionalId,
        p_professional_name: state.filters.professional === "all" || professionalId ? null : state.filters.professional,
        p_link_status: linkStatus,
        p_start_date: range.startDate,
        p_end_date: range.endDate,
        p_limit: 30,
        p_offset: offset,
      });
      if (!state.active || requestGeneration !== state.listGeneration || storeId !== state.selectedStoreId) return;
      const page = normalizeOperationalPage(raw, storeId, offset);
      if (append) {
        const known = new Set(state.listRecords.map((record) => record.id));
        state.listRecords = [...state.listRecords, ...page.records.filter((record) => !known.has(record.id))];
      } else {
        state.listRecords = page.records;
      }
      state.listTotal = page.total;
      state.listHasMore = page.hasMore;
      state.listLoaded = true;
      state.listSource = "paged";
      state.listError = "";
    } catch (error) {
      if (!state.active || requestGeneration !== state.listGeneration || storeId !== state.selectedStoreId) return;
      if (handleEntitlementLoss(error, storeId)) return;
      state.listError = readableError(error);
    } finally {
      if (state.active && requestGeneration === state.listGeneration && storeId === state.selectedStoreId) {
        state.listLoading = false;
        renderFilteredRegions();
      }
    }
  }

  function scheduleOperationalListLoad() {
    if (state.listSearchTimer) global.clearTimeout(state.listSearchTimer);
    state.listSearchTimer = global.setTimeout(() => {
      state.listSearchTimer = 0;
      loadOperationalList();
    }, 260);
  }

  async function loadMorningWorkspace({ quiet = false } = {}) {
    const store = selectedStore();
    if (!state.active || !store?.id || !store.goodMorningSellerEnabled) {
      clearMorningState();
      if (!quiet) refreshMorningRegion();
      return;
    }

    if (state.morningSaving || state.morningParticipationSaving) return;

    const storeId = store.id;
    const contextGeneration = state.contextGeneration;
    const requestGeneration = ++state.morningGeneration;
    state.morningLoading = true;
    state.morningError = "";
    if (!quiet) refreshMorningRegion();
    try {
      const raw = await rpc("morningWorkspace", { p_store_id: storeId });
      if (!state.active
        || contextGeneration !== state.contextGeneration
        || requestGeneration !== state.morningGeneration
        || storeId !== state.selectedStoreId) return;
      const nextMorning = normalizeMorningWorkspace(raw);
      const previousTeamSignature = state.morningConfigOpen && state.morningDraft
        ? state.morningDraft.professionals.map((professional) => `${professional.id}:${professional.enabled !== false}`).sort().join("|")
        : "";
      const nextTeamSignature = nextMorning.professionals.map((professional) => `${professional.id}:${professional.enabled !== false}`).sort().join("|");
      const releasedTeamChanged = Boolean(state.morningConfigOpen && previousTeamSignature !== nextTeamSignature);
      state.morning = nextMorning;
      state.morningLoading = false;
      state.morningError = "";
      if (releasedTeamChanged || !canOpenMorningConfig()) {
        state.morningConfigOpen = false;
        state.morningConfigGeneration += 1;
        state.morningDraft = null;
        if (releasedTeamChanged) {
          notify("A participação da equipe mudou em outra sessão. Abra novamente para revisar os dados atuais.", "warning");
        }
      }
    } catch (error) {
      if (!state.active
        || contextGeneration !== state.contextGeneration
        || requestGeneration !== state.morningGeneration
        || storeId !== state.selectedStoreId) return;
      state.morningLoading = false;
      state.morning = null;
      state.morningConfigOpen = false;
      state.morningConfigGeneration += 1;
      state.morningDraft = null;
      state.morningError = readableError(error);
    }
    refreshMorningRegion();
  }

  async function loadWorkspace({ quiet = false } = {}) {
    if (!state.active) return;
    if (!state.selectedStoreId) {
      state.listGeneration += 1;
      state.records = [];
      state.listRecords = [];
      state.listTotal = 0;
      state.listHasMore = false;
      state.listLoading = false;
      state.listLoaded = false;
      state.listError = "";
      state.listSource = "workspace";
      state.professionals = [];
      clearMorningState();
      state.serverMetrics = {};
      state.loading = false;
      state.loadError = "";
      renderWorkspace();
      return;
    }

    const storeId = state.selectedStoreId;
    const requestGeneration = ++state.generation;
    state.loading = !quiet;
    state.morningLoading = Boolean(selectedStore()?.goodMorningSellerEnabled && !state.morning);
    state.loadError = "";
    if (!quiet) renderWorkspace();
    try {
      const raw = await rpc("workspace", { p_store_id: storeId });
      if (!state.active || requestGeneration !== state.generation || storeId !== state.selectedStoreId) return;
      const workspace = normalizeWorkspace(raw);
      state.records = workspace.records.filter((record) => !record.storeId || record.storeId === storeId);
      state.listGeneration += 1;
      state.listRecords = state.records.slice();
      state.listTotal = state.listRecords.length;
      state.listHasMore = state.listRecords.length >= 100;
      state.listLoading = false;
      state.listLoaded = false;
      state.listError = "";
      state.listSource = "workspace";
      state.professionals = workspace.professionals;
      state.serverMetrics = workspace.metrics;
      state.loading = false;
      state.loadError = "";
      renderWorkspace();
      await Promise.all([loadOperationalList(), loadMorningWorkspace()]);
    } catch (error) {
      if (!state.active || requestGeneration !== state.generation) return;
      if (handleEntitlementLoss(error, storeId)) return;
      state.loading = false;
      if (quiet) {
        notify(`Atendimento salvo, mas a lista não pôde ser atualizada agora: ${readableError(error)}`, "warning");
        renderWorkspace();
        return;
      }
      state.loadError = readableError(error);
      renderWorkspace();
    }
  }

  async function submitAttendance(form) {
    if (state.saving || !state.selectedStoreId) return;
    setFormError("");
    let submitted;
    try {
      submitted = validateForm(form);
    } catch (error) {
      setFormError(readableError(error));
      form.querySelector(":invalid")?.focus();
      return;
    }

    const submissionFingerprint = JSON.stringify([
      state.selectedStoreId,
      submitted.professionalName,
      submitted.attendedOn,
      submitted.customerName,
      submitted.phone,
      submitted.cpf,
      submitted.description,
      submitted.tag,
      submitted.serviceValue,
      submitted.purchaseValue,
      submitted.serviceOrder,
    ]);
    if (!state.idempotencyKey || state.idempotencyFingerprint !== submissionFingerprint) {
      state.idempotencyKey = createIdempotencyKey();
      state.idempotencyFingerprint = submissionFingerprint;
    }
    const saveContext = {
      storeId: state.selectedStoreId,
      key: state.idempotencyKey,
      generation: state.contextGeneration,
    };
    state.saving = true;
    state.pendingSave = saveContext;
    setFormBusy(true);
    let raw;
    try {
      const args = {
        p_store_id: saveContext.storeId,
        p_professional_name: submitted.professionalName,
        p_attended_on: submitted.attendedOn,
        p_customer_name: submitted.customerName,
        p_phone: submitted.phone,
        p_cpf: submitted.cpf || null,
        p_description: submitted.description,
        p_tag: submitted.tag,
        p_service_value: submitted.serviceValue,
        p_purchase_value: submitted.tag === "purchase" ? submitted.purchaseValue : null,
        p_service_order: submitted.tag === "purchase" ? submitted.serviceOrder : null,
        p_idempotency_key: saveContext.key,
      };
      raw = await rpc("save", args);
    } catch (error) {
      state.saving = false;
      state.pendingSave = null;
      const stillCurrent = state.active
        && state.selectedStoreId === saveContext.storeId
        && state.contextGeneration === saveContext.generation;
      setFormBusy(false);
      if (handleEntitlementLoss(error, saveContext.storeId)) return;
      if (stillCurrent) setFormError(readableError(error));
      notify(readableError(error), "error");
      return;
    }

    const feedback = normalizeSaveFeedback(raw, submitted);
    state.saving = false;
    state.pendingSave = null;
    state.drafts.delete(saveContext.storeId);
    if (state.idempotencyKey === saveContext.key) {
      state.idempotencyKey = "";
      state.idempotencyFingerprint = "";
    }
    const stillCurrent = state.active
      && state.selectedStoreId === saveContext.storeId
      && state.contextGeneration === saveContext.generation;
    if (stillCurrent) {
      state.feedback = feedback;
      form.reset();
      syncPurchaseFields();
      renderWorkspace();
    } else {
      setFormBusy(false);
    }
    notify(feedback.idempotentReplay ? "Este atendimento já estava salvo; nenhum registro foi duplicado." : "Atendimento salvo e vínculos verificados.", "success");

    if (stillCurrent) {
      try {
        if (typeof state.bridge?.onAttendanceSaved === "function") await state.bridge.onAttendanceSaved(feedback, raw);
        if (typeof state.bridge?.afterSave === "function") await state.bridge.afterSave(feedback, raw);
      } catch (error) {
        notify(`Atendimento salvo. Uma atualização secundária falhou: ${readableError(error)}`, "warning");
      }
    }

    const remainsCurrent = state.active
      && state.selectedStoreId === saveContext.storeId
      && state.contextGeneration === saveContext.generation;
    if (remainsCurrent) await loadWorkspace({ quiet: true });
  }

  function captureMorningDraftInputs({ captureParticipation = true } = {}) {
    if (!state.morningDraft) return;
    const form = state.root?.querySelector("[data-morning-config-form]");
    if (!form) return;
    const canConfigure = canManageMorningSettings();
    if (canConfigure) {
      state.morningDraft.monthlyGoal = normalizeMoney(form.elements.monthly_goal?.value);
      state.morningDraft.mode = form.querySelector('input[name="allocation_mode"]:checked')?.value === "custom" ? "custom" : "equal";
    }
    state.morningDraft.professionals.forEach((professional) => {
      const enabledInput = form.querySelector(`[data-morning-seller-enabled="${professional.id}"]`);
      if (captureParticipation && enabledInput) professional.enabled = enabledInput.checked;
      const input = form.querySelector(`[data-morning-seller-goal="${professional.id}"]`);
      if (canConfigure && professional.enabled !== false && input && !input.disabled) professional.goalAmount = normalizeMoney(input.value);
    });
    if (canConfigure && state.morningDraft.mode === "equal") applyEqualMorningGoals(state.morningDraft);
  }

  function syncMorningConfigPreview() {
    const form = state.root?.querySelector("[data-morning-config-form]");
    if (!form || !state.morningDraft || !canManageMorningSettings()) return;
    captureMorningDraftInputs();
    state.morningDraft.professionals.forEach((professional) => {
      const input = form.querySelector(`[data-morning-seller-goal="${professional.id}"]`);
      if (input) {
        input.disabled = state.morningDraft.mode === "equal" || professional.enabled === false;
        if (state.morningDraft.mode === "equal" || professional.enabled === false) {
          input.value = String((professional.enabled === false ? 0 : professional.goalAmount).toFixed(2));
        }
      }
    });
    const participants = morningParticipants(state.morningDraft.professionals);
    const total = morningDraftTotal();
    const difference = Math.round((normalizeMoney(state.morningDraft.monthlyGoal) - total) * 100) / 100;
    const balanced = participants.length > 0 && Math.abs(difference) < 0.01;
    const totalElement = form.querySelector("[data-morning-distributed-total]");
    const status = form.querySelector("[data-morning-allocation-status]");
    const submit = form.querySelector('button[type="submit"]');
    if (totalElement) totalElement.textContent = formatCurrency(total);
    if (status) {
      status.classList.toggle("is-balanced", balanced);
      status.classList.toggle("is-warning", !balanced);
      status.textContent = participants.length === 0
        ? "Ative ao menos 1 vendedor"
        : balanced
          ? "Distribuição completa"
          : `${difference > 0 ? "Faltam" : "Excedeu"} ${formatCurrency(Math.abs(difference))}`;
    }
    if (submit) submit.disabled = state.morningSaving || Boolean(state.morningParticipationSaving) || !participants.length || !balanced;
  }

  async function updateMorningParticipation(professionalId, enabled) {
    if (!professionalId || state.morningParticipationSaving || state.morningSaving || !state.selectedStoreId) return;
    if (!canManageMorningParticipation()) {
      notify("A participação só pode ser alterada pelo Admin ou pela própria loja após a atualização do banco.", "warning");
      return;
    }

    const dialogScrollTop = state.root?.querySelector("[data-morning-dialog]")?.scrollTop ?? 0;
    captureMorningDraftInputs({ captureParticipation: false });
    const originalDraft = cloneMorningDraft(state.morningDraft);
    const professionalName = originalDraft?.professionals.find((professional) => professional.id === professionalId)?.name
      || state.morning?.professionals.find((professional) => professional.id === professionalId)?.name
      || "Profissional";
    const changedProfessional = state.morningDraft?.professionals.find((professional) => professional.id === professionalId);
    if (!changedProfessional) return;
    changedProfessional.enabled = enabled === true;
    if (canManageMorningSettings() && state.morningDraft.mode === "equal") applyEqualMorningGoals(state.morningDraft);
    const pendingDraft = cloneMorningDraft(state.morningDraft);
    const updateContext = {
      storeId: state.selectedStoreId,
      generation: state.contextGeneration,
      configGeneration: state.morningConfigGeneration,
      professionalId,
    };
    const isCurrent = () => state.active
      && state.selectedStoreId === updateContext.storeId
      && state.contextGeneration === updateContext.generation;

    invalidateMorningRequests();
    state.morningParticipationSaving = professionalId;
    state.morningError = "";
    refreshMorningRegion({
      dialogScrollTop,
      focusSelector: '[data-attendance-action="close-morning-config"]',
    });
    try {
      const raw = await rpc("morningParticipation", {
        p_store_id: updateContext.storeId,
        p_professional_id: professionalId,
        p_enabled: enabled === true,
      });
      if (!isCurrent()) return;
      const nextMorning = normalizeMorningWorkspace(raw);
      state.morning = nextMorning;
      if (state.morningConfigOpen
        && state.morningConfigGeneration === updateContext.configGeneration
        && canOpenMorningConfig()) {
        state.morningDraft = canManageMorningSettings()
          ? mergeMorningDraftWithWorkspace(pendingDraft, nextMorning)
          : createMorningDraft();
      }
      const stateLabel = enabled ? "ativada" : "desativada";
      notify(
        isStoreRole()
          ? `Participação de ${professionalName} ${stateLabel}. Revise e salve a meta e a fila.`
          : `Participação de ${professionalName} ${stateLabel}. A loja poderá revisar a meta e a fila.`,
        "success"
      );
    } catch (error) {
      if (!isCurrent()) return;
      if (handleEntitlementLoss(error, updateContext.storeId)) return;
      state.morningDraft = originalDraft;
      const rpcName = DEFAULT_RPC.morningParticipation;
      if (isMissingRpcError(error, rpcName)) {
        if (state.morning) state.morning.participationUpdateAvailable = false;
        state.morningError = "A atualização do banco que libera estes switches ainda não está disponível. Nada foi alterado.";
      } else {
        state.morningError = readableError(error);
      }
      notify(state.morningError, "error");
    } finally {
      if (isCurrent()) {
        state.morningParticipationSaving = "";
        refreshMorningRegion({
          dialogScrollTop,
          focusSelector: `[data-morning-seller-enabled="${professionalId}"]`,
        });
      }
    }
  }

  async function saveMorningSettings(form) {
    if (state.morningSaving || state.morningParticipationSaving || !state.morningDraft || !state.selectedStoreId) return;
    if (!canManageMorningSettings()) {
      notify("Somente a loja pode configurar metas, divisão e ordem do Bom Dia Vendedor.", "warning");
      return;
    }
    captureMorningDraftInputs();
    const monthlyGoal = normalizeMoney(state.morningDraft.monthlyGoal);
    const participants = morningParticipants(state.morningDraft.professionals);
    const total = morningDraftTotal();
    if (monthlyGoal <= 0) {
      state.morningError = "Informe uma meta mensal maior que zero.";
      refreshMorningRegion();
      return;
    }
    if (!state.morningDraft.professionals.length) {
      state.morningError = "Cadastre ao menos um vendedor ativo na equipe deste cliente.";
      refreshMorningRegion();
      return;
    }
    if (!participants.length) {
      state.morningError = "Ative ao menos um vendedor para participar da fila e do rateio.";
      refreshMorningRegion();
      return;
    }
    if (Math.abs(monthlyGoal - total) >= 0.01) {
      state.morningError = "A soma das metas individuais precisa ser igual à meta mensal.";
      refreshMorningRegion();
      return;
    }

    invalidateMorningRequests();
    state.morningSaving = true;
    state.morningError = "";
    refreshMorningRegion();
    const saveContext = {
      storeId: state.selectedStoreId,
      generation: state.contextGeneration,
    };
    const isCurrent = () => state.active
      && state.selectedStoreId === saveContext.storeId
      && state.contextGeneration === saveContext.generation;
    try {
      const participantPositions = new Map(participants.map((professional, index) => [professional.id, index + 1]));
      const raw = await rpc("morningSave", {
        p_store_id: saveContext.storeId,
        p_monthly_goal: monthlyGoal,
        p_allocation_mode: state.morningDraft.mode,
        p_allocations: state.morningDraft.professionals.map((professional) => ({
          professional_id: professional.id,
          enabled: professional.enabled !== false,
          goal_amount: professional.enabled === false ? "0.00" : normalizeMoney(professional.goalAmount).toFixed(2),
          queue_position: professional.enabled === false
            ? null
            : participantPositions.get(professional.id),
        })),
      });
      if (!isCurrent()) return;
      state.morning = normalizeMorningWorkspace(raw);
      state.morningConfigOpen = false;
      state.morningConfigGeneration += 1;
      state.morningDraft = null;
      notify("Meta e fila do Bom Dia Vendedor atualizadas.", "success");
    } catch (error) {
      if (isCurrent()) state.morningError = readableError(error);
    } finally {
      if (isCurrent()) {
        state.morningSaving = false;
        refreshMorningRegion();
      }
    }
  }

  async function advanceMorningTurn() {
    if (state.morningSaving || state.morningParticipationSaving || !state.selectedStoreId) return;
    if (!canManageMorningSettings()) {
      notify("Somente a loja pode avançar a rotação do Bom Dia Vendedor.", "warning");
      return;
    }
    const advanceContext = {
      storeId: state.selectedStoreId,
      generation: state.contextGeneration,
    };
    const isCurrent = () => state.active
      && state.selectedStoreId === advanceContext.storeId
      && state.contextGeneration === advanceContext.generation;
    invalidateMorningRequests();
    state.morningSaving = true;
    state.morningError = "";
    refreshMorningRegion();
    try {
      const raw = await rpc("morningAdvance", { p_store_id: advanceContext.storeId });
      if (!isCurrent()) return;
      state.morning = normalizeMorningWorkspace(raw);
      const current = morningQueue()[0];
      notify(current ? `${current.name} está na vez agora.` : "Fila atualizada.", "success");
    } catch (error) {
      if (isCurrent()) {
        state.morningError = readableError(error);
        notify(state.morningError, "error");
      }
    } finally {
      if (isCurrent()) {
        state.morningSaving = false;
        refreshMorningRegion();
      }
    }
  }

  function onInput(event) {
    const target = event.target;
    if (target.closest("[data-attendance-own-analysis]")) return;
    if (target.matches('input[name="phone"]')) {
      target.value = formatPhone(target.value);
      return;
    }
    if (target.matches('input[name="cpf"]')) {
      target.value = formatCpf(target.value);
      return;
    }
    if (target.matches('[data-attendance-filter="search"]')) {
      state.filters.search = target.value;
      renderFilteredRegions();
      scheduleOperationalListLoad();
      return;
    }
    if (target.matches('[data-morning-config-form] input[name="monthly_goal"], [data-morning-seller-goal]') && canManageMorningSettings()) {
      syncMorningConfigPreview();
    }
  }

  async function onChange(event) {
    const target = event.target;
    if (target.closest("[data-attendance-own-analysis]")) return;
    if (target.matches("[data-attendance-store]")) {
      const nextId = String(target.value || "");
      if (nextId && !state.stores.some((store) => store.id === nextId)) return;
      captureDraft();
      const previousId = state.selectedStoreId;
      state.selectedStoreId = nextId;
      state.contextGeneration += 1;
      state.feedback = null;
      if (state.listSearchTimer) global.clearTimeout(state.listSearchTimer);
      state.listSearchTimer = 0;
      state.records = [];
      state.listGeneration += 1;
      state.listRecords = [];
      state.listTotal = 0;
      state.listHasMore = false;
      state.listLoading = false;
      state.listLoaded = false;
      state.listError = "";
      state.listSource = "workspace";
      state.professionals = [];
      clearMorningState({ loading: Boolean(selectedStore()?.goodMorningSellerEnabled) });
      state.idempotencyKey = "";
      state.idempotencyFingerprint = "";
      state.filtersOpen = false;
      state.filters = { search: "", tag: "all", professional: "all", period: "30d", link: "all" };
      if (typeof state.bridge?.onStoreSelected === "function") {
        try {
          await state.bridge.onStoreSelected(nextId, selectedStore());
        } catch (error) {
          state.selectedStoreId = previousId;
          state.contextGeneration += 1;
          notify(readableError(error), "error");
        }
      }
      await loadWorkspace();
      return;
    }
    if (target.matches('input[name="tag"]')) {
      syncPurchaseFields();
      return;
    }
    if (target.matches("[data-morning-seller-enabled]")) {
      const professionalId = String(target.dataset.morningSellerEnabled || "");
      if (!canManageMorningParticipation()) {
        target.checked = !target.checked;
        notify("A participação só pode ser alterada pelo Admin ou pela própria loja após a atualização do banco.", "warning");
        return;
      }
      await updateMorningParticipation(professionalId, target.checked);
      return;
    }
    if (target.matches('[data-morning-config-form] input[name="allocation_mode"]')) {
      if (!canManageMorningSettings()) return;
      const selectedMode = target.value === "custom" ? "custom" : "equal";
      captureMorningDraftInputs();
      state.morningDraft.mode = selectedMode;
      if (state.morningDraft.mode === "equal") applyEqualMorningGoals(state.morningDraft);
      refreshMorningRegion();
      queueMicrotask(() => {
        state.root?.querySelector(`[data-morning-config-form] input[name="allocation_mode"][value="${selectedMode}"]`)?.focus();
      });
      return;
    }
    if (target.matches("[data-attendance-filter]")) {
      const key = target.dataset.attendanceFilter;
      if (key && key in state.filters) state.filters[key] = target.value;
      renderFilteredRegions();
      await loadOperationalList();
    }
  }

  async function onClick(event) {
    if (event.target.closest("[data-attendance-own-analysis]")) return;
    if (event.target.matches("[data-morning-backdrop]")) {
      closeMorningConfig();
      return;
    }
    const copyButton = event.target.closest("[data-attendance-copy-phone]");
    if (copyButton) {
      const phone = String(copyButton.dataset.attendanceCopyPhone || "");
      if (!phone) return;
      try {
        await global.navigator.clipboard.writeText(phone);
        notify("Telefone copiado.", "success");
      } catch {
        notify("Não foi possível copiar o telefone neste navegador.", "warning");
      }
      return;
    }
    const button = event.target.closest("[data-attendance-action]");
    if (!button) return;
    const action = button.dataset.attendanceAction;
    if (action === "view-analysis" || action === "view-operations") {
      const nextView = action === "view-analysis" ? "analysis" : "operations";
      if (state.view === nextView) return;
      captureDraft();
      state.view = nextView;
      renderWorkspace();
      return;
    }
    if (action === "retry-morning") {
      await loadMorningWorkspace();
      return;
    }
    if (action === "open-morning-config") {
      if (!canOpenMorningConfig()) {
        notify("Somente o Admin dentro do cliente ou a própria loja podem gerenciar o Bom Dia Vendedor.", "warning");
        return;
      }
      captureDraft();
      state.morningError = "";
      state.morningDraft = createMorningDraft();
      state.morningConfigOpen = true;
      state.morningConfigGeneration += 1;
      refreshMorningRegion();
      const initialFocus = canManageMorningSettings()
        ? state.root?.querySelector('[data-morning-config-form] input[name="monthly_goal"]')
        : state.root?.querySelector('[data-morning-seller-enabled]:not(:disabled)');
      (initialFocus || state.root?.querySelector('[data-attendance-action="close-morning-config"]'))?.focus();
      return;
    }
    if (action === "close-morning-config") {
      closeMorningConfig();
      return;
    }
    if (action === "move-morning-seller-up" || action === "move-morning-seller-down") {
      if (!canManageMorningSettings() || state.morningParticipationSaving || state.morningSaving) return;
      captureMorningDraftInputs();
      const professionalId = String(button.dataset.professionalId || "");
      const participants = morningParticipants(state.morningDraft?.professionals || []);
      const participantIndex = participants.findIndex((professional) => professional.id === professionalId);
      const nextParticipantIndex = action === "move-morning-seller-up" ? participantIndex - 1 : participantIndex + 1;
      if (participantIndex >= 0 && nextParticipantIndex >= 0 && nextParticipantIndex < participants.length) {
        const currentIndex = state.morningDraft.professionals.indexOf(participants[participantIndex]);
        const nextIndex = state.morningDraft.professionals.indexOf(participants[nextParticipantIndex]);
        [state.morningDraft.professionals[currentIndex], state.morningDraft.professionals[nextIndex]] = [state.morningDraft.professionals[nextIndex], state.morningDraft.professionals[currentIndex]];
        refreshMorningRegion();
        queueMicrotask(() => {
          const row = state.root?.querySelector(`[data-morning-professional="${professionalId}"]`);
          const preferred = row?.querySelector(`[data-attendance-action="${action}"]:not(:disabled)`);
          (preferred || row?.querySelector("button:not(:disabled), input:not(:disabled)"))?.focus();
        });
      }
      return;
    }
    if (action === "advance-morning-turn") {
      if (!canManageMorningSettings()) {
        notify("Somente a loja pode avançar a rotação do Bom Dia Vendedor.", "warning");
        return;
      }
      await advanceMorningTurn();
      return;
    }
    if (action === "refresh") await loadWorkspace();
    if (action === "load-more") await loadOperationalList({ append: true });
    if (action === "retry-list") await loadOperationalList();
    if (action === "toggle-filters") {
      state.filtersOpen = !state.filtersOpen;
      const panel = state.root?.querySelector("#attendanceFilters");
      if (panel) panel.hidden = !state.filtersOpen;
      button.classList.toggle("is-active", state.filtersOpen || attendanceFilterCount() > 0);
      button.setAttribute("aria-expanded", String(state.filtersOpen));
    }
    if (action === "clear-filters") {
      state.filters = { search: "", tag: "all", professional: "all", period: "30d", link: "all" };
      state.filtersOpen = true;
      const overview = state.root?.querySelector(".attendance-overview");
      if (overview) overview.outerHTML = renderOverview();
      await loadOperationalList();
    }
    if (action === "dismiss-feedback") {
      state.feedback = null;
      button.closest(".attendance-save-feedback")?.remove();
    }
  }

  function onSubmit(event) {
    if (event.target.closest("[data-attendance-own-analysis]")) return;
    const morningForm = event.target.closest("[data-morning-config-form]");
    if (morningForm) {
      event.preventDefault();
      if (!canManageMorningSettings()) return;
      saveMorningSettings(morningForm);
      return;
    }
    const form = event.target.closest("[data-attendance-form]");
    if (!form) return;
    event.preventDefault();
    submitAttendance(form);
  }

  function onKeydown(event) {
    if (!state.morningConfigOpen) return;
    const dialog = state.root?.querySelector("[data-morning-dialog]");
    if (!dialog) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeMorningConfig();
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = [...dialog.querySelectorAll('button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])')]
      .filter((element) => element.getClientRects().length > 0);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function bindRoot(root) {
    if (root.__attendanceHandlersBound) return;
    root.addEventListener("input", onInput);
    root.addEventListener("change", onChange);
    root.addEventListener("click", onClick);
    root.addEventListener("submit", onSubmit);
    root.addEventListener("keydown", onKeydown);
    root.__attendanceHandlersBound = true;
  }

  function mount(target) {
    const root = resolveRoot(target);
    if (!root) return false;
    state.root = root;
    root.classList.add("attendance-view");
    root.setAttribute("data-attendances-root", "");
    bindRoot(root);
    renderWorkspace();
    return true;
  }

  async function activate(nextBridge = {}) {
    state.bridge = { ...state.bridge, ...nextBridge };
    state.active = true;
    state.view = "operations";
    state.loading = true;
    state.contextGeneration += 1;
    clearMorningState();
    state.feedback = null;
    syncContext({ preserveSelection: false });
    if (!mount(nextBridge.root || nextBridge.mountTarget)) {
      throw new Error("Área visual de Atendimentos não encontrada.");
    }
    await loadWorkspace();
  }

  function deactivate() {
    captureDraft();
    const ownAnalysis = state.root?.querySelector("[data-attendance-own-analysis]");
    if (ownAnalysis) destroyEmbeddedAnalysis(ownAnalysis);
    state.active = false;
    state.loading = false;
    state.generation += 1;
    state.listGeneration += 1;
    state.contextGeneration += 1;
    clearMorningState();
    if (state.listSearchTimer) global.clearTimeout(state.listSearchTimer);
    state.listSearchTimer = 0;
  }

  function resetSession() {
    state.active = false;
    state.loading = false;
    state.saving = false;
    state.view = "operations";
    state.generation += 1;
    state.listGeneration += 1;
    state.contextGeneration += 1;
    state.selectedStoreId = "";
    state.stores = [];
    state.records = [];
    state.listRecords = [];
    state.listTotal = 0;
    state.listHasMore = false;
    state.listLoading = false;
    state.listLoaded = false;
    state.listError = "";
    state.listSource = "workspace";
    if (state.listSearchTimer) global.clearTimeout(state.listSearchTimer);
    state.listSearchTimer = 0;
    state.professionals = [];
    clearMorningState();
    state.legacyAttendanceSaveRequired = false;
    state.serverMetrics = {};
    state.feedback = null;
    state.loadError = "";
    state.idempotencyKey = "";
    state.idempotencyFingerprint = "";
    state.pendingSave = null;
    state.filtersOpen = false;
    state.filters = { search: "", tag: "all", professional: "all", period: "30d", link: "all" };
    state.drafts.clear();
    state.bridge = {};
    if (state.root) state.root.replaceChildren();
  }

  async function refreshContext(nextContext = {}) {
    captureDraft();
    state.bridge = { ...state.bridge, ...nextContext };
    state.contextGeneration += 1;
    clearMorningState();
    syncContext({ preserveSelection: true });
    if (state.active) {
      state.loading = true;
      mount(nextContext.root || nextContext.mountTarget);
      await loadWorkspace();
    }
  }

  async function refresh() {
    if (!state.active) return;
    await loadWorkspace();
  }

  function renderFatalError(message) {
    if (!state.root) mount();
    if (!state.root) return;
    state.loading = false;
    state.loadError = readableError(message);
    renderWorkspace();
  }

  function getIntegrationContract() {
    return {
      version: 3,
      mount: "<section id=\"attendanceView\" class=\"attendance-view\" hidden></section>",
      bridge: {
        required: ["profile", "stores", "rpc"],
        optional: ["initialStoreId", "initialAgencyId", "attendanceAccessGranted", "attendanceRetroactiveDatesGranted", "prospectionAccessGranted", "notify", "afterSave", "onAttendanceSaved", "onStoreSelected", "onAccessRevoked", "attendanceRpcNames", "attendances.load", "attendances.save", "attendances.list"],
      },
      rpc: {
        workspace: {
          name: DEFAULT_RPC.workspace,
          args: { p_store_id: "uuid" },
          returns: { attendances: "array", professionals: "array", metrics: "object (optional)" },
        },
        save: {
          name: DEFAULT_RPC.save,
          args: {
            p_store_id: "uuid",
            p_professional_name: "text",
            p_attended_on: "date (America/Sao_Paulo; últimos 2 anos até hoje)",
            p_customer_name: "text",
            p_phone: "text (digits)",
            p_cpf: "text | null",
            p_description: "text",
            p_tag: "budget | purchase | other",
            p_service_value: "numeric",
            p_purchase_value: "numeric | null",
            p_service_order: "text | null",
            p_idempotency_key: "uuid/text",
          },
          returns: {
            attendance: "object",
            linked_lead: "boolean/object",
            linked_prospection: "boolean/object",
            prospection_professional_name: "text | null",
            bonus_eligible: "boolean | null (calculated by backend only)",
            bonus_amount: "numeric | null (returned by backend only)",
            bonus_reason: "text | null",
          },
        },
        saveLegacy: {
          name: DEFAULT_RPC.saveLegacy,
          compatibility: "Somente a data atual; p_attended_on é removido antes da chamada.",
        },
        list: {
          name: DEFAULT_RPC.list,
          args: {
            p_store_id: "uuid",
            p_search: "text | null",
            p_tag: "budget | purchase | other | null",
            p_professional_id: "uuid | null",
            p_professional_name: "text | null",
            p_link_status: "matched | standalone | review | null",
            p_start_date: "date | null",
            p_end_date: "date | null",
            p_limit: 30,
            p_offset: "integer",
          },
          returns: { items: "array", total: "integer", has_more: "boolean" },
        },
        analysis: {
          name: DEFAULT_RPC.analysis,
          args: {
            p_store_id: "uuid",
            p_search: "text | null",
            p_tag: "budget | purchase | other | null",
            p_professional_id: "uuid | null",
            p_professional_name: "text | null",
            p_link_status: "matched | standalone | review | lead | prospection | both | null",
            p_start_date: "date | null",
            p_end_date: "date | null",
          },
          returns: { metrics: "object", professionals: "array" },
        },
        morningWorkspace: {
          name: DEFAULT_RPC.morningWorkspace,
          args: { p_store_id: "uuid" },
          returns: {
            licensed: "boolean",
            configured: "boolean",
            can_manage_settings: "boolean (true only for the store account)",
            participation_control_available: "boolean (the participation field exists)",
            participation_update_available: "boolean (the dedicated update RPC exists)",
            eligible_professional_count: "integer (people currently participating)",
            goals: "object",
            professionals: "array",
            queue: "array",
          },
        },
        morningSave: {
          name: DEFAULT_RPC.morningSave,
          args: {
            p_store_id: "uuid",
            p_monthly_goal: "numeric",
            p_allocation_mode: "equal | custom",
            p_allocations: "jsonb array with every active professional: { professional_id, enabled, goal_amount, queue_position }",
          },
          returns: "same workspace contract",
        },
        morningAdvance: {
          name: DEFAULT_RPC.morningAdvance,
          args: { p_store_id: "uuid" },
          returns: "same workspace contract with the next professional highlighted",
        },
        morningParticipation: {
          name: DEFAULT_RPC.morningParticipation,
          args: {
            p_store_id: "uuid",
            p_professional_id: "uuid",
            p_enabled: "boolean",
          },
          returns: "same workspace contract with participation persisted immediately",
        },
      },
      rules: [
        "A tela nunca consulta mais de um p_store_id por vez.",
        "Lead e Prospecção podem estar vinculados simultaneamente.",
        "attendanceAccessGranted autoriza Atendimentos; prospectionAccessGranted é apenas fallback para bridges antigos.",
        "Elegibilidade e valor de bônus nunca são calculados no navegador.",
        "Bom Dia Vendedor exige a licença adicional da loja e nunca ignora essa autorização.",
        "Admin e a própria loja podem ativar ou pausar participantes; a Agência permanece somente leitura.",
        "Somente a loja configura metas, divisão, ordem e avanço da rotação.",
        "A fila só avança por uma ação explícita do usuário.",
      ],
    };
  }

  global.AttendancesModule = Object.freeze({
    activate,
    deactivate,
    resetSession,
    refreshContext,
    refresh,
    renderFatalError,
    mount,
    getIntegrationContract,
    renderEmbeddedAnalysis,
    destroyEmbeddedAnalysis,
  });
})(window);
