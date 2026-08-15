(() => {
  "use strict";

  const root = document.querySelector("#prospectionView");
  if (!root) return;

  const PROBABILITIES = {
    red: { label: "Improvável", color: "#c43d59" },
    yellow: { label: "Pouco provável", color: "#d48616" },
    blue: { label: "Provável", color: "#2f80ed" },
    green: { label: "Muito provável", color: "#16855f" },
  };
  const STORE_COLORS = ["#16855f", "#2f80ed", "#7c5ce7", "#d48616", "#c43d59", "#168a91", "#55585f"];
  const DEFAULT_SETTINGS = Object.freeze({
    dailyGoal: 15,
    bonusMinimum: 300,
    bonusAmount: 20,
    accentColor: "#16855f",
    logoBackgroundColor: "#ffffff",
  });
  const ATTENDANCE_TYPES = Object.freeze({
    all: { label: "Todos os tipos", icon: "fa-layer-group" },
    budget: { label: "Orçamentos", singular: "Orçamento", icon: "fa-file-invoice-dollar" },
    purchase: { label: "Compras", singular: "Compra", icon: "fa-bag-shopping" },
    other: { label: "Outros", singular: "Outro", icon: "fa-ellipsis" },
  });

  let bridge = null;
  let active = false;
  let loading = false;
  let upgradePreview = false;
  let archiveProspects = [];
  let prospects = [];
  let settings = [];
  let professionals = [];
  let tagCategories = [];
  let tags = [];
  let selectedStoreId = "";
  let selectedAgencyId = "";
  let editingId = "";
  let dashboardPeriod = "today";
  let listSearch = "";
  let listStatus = "all";
  let filtersOpen = false;
  let listMode = "records";
  let attendanceListState = null;
  let attendanceListRequest = 0;
  let prospectPrefill = null;
  let calendarDate = new Date();
  let analysisStoreId = "";
  let analysisStartDate = "";
  let analysisEndDate = "";
  let analysisPeriod = "monthly";
  let analysisProfessionalId = "all";
  let analysisDetailProfessionalId = "";
  let bonusStoreId = "";
  let bonusStartDate = "";
  let bonusEndDate = "";
  let bonusProfessionalId = "all";
  let pendingPurchaseId = "";
  let importDraft = null;
  let configurationSession = null;
  let pendingConfigurationTransition = null;
  let configurationNeedsRefresh = false;
  let workspaceResizeObserver = null;
  let workspaceResizeFrame = 0;

  const escapeHtml = (value) => String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");

  const normalize = (value) => String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();

  const onlyDigits = (value) => String(value || "").replace(/\D/g, "");

  function canonicalPhoneDigits(value) {
    const raw = String(value || "").trim();
    const hasInternationalPrefix = /^(\+|00)/.test(raw);
    let digits = onlyDigits(raw);
    if (digits.startsWith("00")) digits = digits.slice(2);
    if (hasInternationalPrefix) return digits.length >= 8 && digits.length <= 15 ? digits : "";
    if (digits.startsWith("0") && [11, 12].includes(digits.length)) digits = digits.slice(1);
    if ([10, 11].includes(digits.length)) digits = `55${digits}`;
    const isBrazilianCanonical = digits.startsWith("55") && [12, 13].includes(digits.length);
    const isInternational = digits.length > 11 && digits.length <= 15;
    return isBrazilianCanonical || isInternational ? digits : "";
  }

  function formatBrazilianPhone(value) {
    const digits = onlyDigits(value).slice(0, 11);
    if (digits.length <= 2) return digits;
    if (digits.length <= 6) return `(${digits.slice(0, 2)}) ${digits.slice(2)}`;
    if (digits.length <= 10) return `(${digits.slice(0, 2)}) ${digits.slice(2, 6)}-${digits.slice(6)}`;
    return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7)}`;
  }

  function formatPhone(value) {
    const raw = String(value || "").trim();
    if (raw === "+") return raw;
    const digits = onlyDigits(raw).slice(0, 15);
    if (!digits) return "";
    const withoutInternationalPrefix = digits.startsWith("00") ? digits.slice(2) : digits;
    if (withoutInternationalPrefix.startsWith("55") && [12, 13].includes(withoutInternationalPrefix.length)) {
      return formatBrazilianPhone(withoutInternationalPrefix.slice(2));
    }
    if (/^(\+|00)/.test(raw) || withoutInternationalPrefix.length > 11) return `+${withoutInternationalPrefix}`;
    return formatBrazilianPhone(withoutInternationalPrefix);
  }

  function formatCpf(value) {
    const digits = onlyDigits(value).slice(0, 11);
    if (digits.length <= 3) return digits;
    if (digits.length <= 6) return `${digits.slice(0, 3)}.${digits.slice(3)}`;
    if (digits.length <= 9) return `${digits.slice(0, 3)}.${digits.slice(3, 6)}.${digits.slice(6)}`;
    return `${digits.slice(0, 3)}.${digits.slice(3, 6)}.${digits.slice(6, 9)}-${digits.slice(9)}`;
  }

  function parseMoney(value) {
    let normalized = String(value || "").replace(/[^\d,.-]/g, "").trim();
    if (normalized.includes(",") && normalized.includes(".")) normalized = normalized.replace(/\./g, "").replace(",", ".");
    else if (normalized.includes(",")) normalized = normalized.replace(",", ".");
    const amount = Number(normalized);
    return Number.isFinite(amount) ? Math.round(amount * 100) / 100 : 0;
  }

  const formatCurrency = (value) => new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(Number(value || 0));

  const formatDateTime = (value) => value
    ? new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short" }).format(new Date(value))
    : "—";

  const formatDate = (value) => value
    ? new Intl.DateTimeFormat("pt-BR", { dateStyle: "short" }).format(new Date(value))
    : "—";

  const formatInputDateDisplay = (value) => value
    ? new Intl.DateTimeFormat("pt-BR", { dateStyle: "short" }).format(new Date(`${value}T12:00:00`))
    : "—";

  const formatDateTimeWithWeekday = (value) => value
    ? `${new Intl.DateTimeFormat("pt-BR", { weekday: "short" }).format(new Date(value)).replace(".", "")}, ${formatDateTime(value)}`
    : "—";

  function startOfDay(value = new Date()) {
    const date = new Date(value);
    date.setHours(0, 0, 0, 0);
    return date;
  }

  function addDays(value, amount) {
    const date = new Date(value);
    date.setDate(date.getDate() + amount);
    return date;
  }

  function startOfWeek(value = new Date()) {
    const date = startOfDay(value);
    const day = date.getDay();
    date.setDate(date.getDate() - (day === 0 ? 6 : day - 1));
    return date;
  }

  function startOfMonth(value = new Date()) {
    const date = new Date(value);
    return new Date(date.getFullYear(), date.getMonth(), 1);
  }

  function addMonths(value, amount) {
    const date = new Date(value);
    return new Date(date.getFullYear(), date.getMonth() + amount, 1);
  }

  function formatDateInput(value) {
    const date = new Date(value);
    const offset = date.getTimezoneOffset();
    return new Date(date.getTime() - offset * 60000).toISOString().slice(0, 10);
  }

  function dateRange(startValue, endValue) {
    const start = startValue ? startOfDay(new Date(`${startValue}T12:00:00`)) : null;
    const end = endValue ? addDays(startOfDay(new Date(`${endValue}T12:00:00`)), 1) : null;
    return { start, end };
  }

  function createAttendanceListState(storeId = "") {
    const today = startOfDay(new Date());
    return {
      storeId: String(storeId || ""),
      search: "",
      tag: "budget",
      startDate: formatDateInput(startOfMonth(today)),
      endDate: formatDateInput(today),
      rows: [],
      total: 0,
      hasMore: false,
      loading: false,
      loaded: false,
      error: "",
    };
  }

  function ensureAttendanceListState(storeId = selectedStoreId) {
    const safeStoreId = String(storeId || "");
    if (!attendanceListState || attendanceListState.storeId !== safeStoreId) {
      attendanceListRequest += 1;
      attendanceListState = createAttendanceListState(safeStoreId);
    }
    return attendanceListState;
  }

  function normalizePhoneKey(value) {
    return canonicalPhoneDigits(value);
  }

  function phoneDigits(value) {
    return canonicalPhoneDigits(value);
  }

  function attendanceType(value) {
    const normalized = normalize(value);
    if (["purchase", "compra", "comprou", "venda", "sale"].includes(normalized)) return "purchase";
    if (["budget", "orcamento", "cotacao", "quote"].includes(normalized)) return "budget";
    return "other";
  }

  function mapAttendanceOpportunity(row = {}, index = 0) {
    const rawPhoneSource = String(row.phone || row.customer_phone || "").trim();
    const phoneSource = /^(\+|00)/.test(rawPhoneSource)
      ? rawPhoneSource
      : row.phone_normalized || rawPhoneSource;
    const tag = attendanceType(row.tag || row.tag_label || row.type);
    const links = row.links && typeof row.links === "object" ? row.links : {};
    const linkedProspection = links.prospection && typeof links.prospection === "object" ? links.prospection : {};
    const prospectionMatchCount = Number(
      links.prospection_match_count
      ?? links.prospection_candidates_count
      ?? row.prospection_match_count
      ?? 0,
    ) || 0;
    return {
      id: String(row.id || row.attendance_id || `${row.attended_at || row.created_at || "attendance"}-${index}`),
      storeId: String(row.store_id || row.storeId || ""),
      customerName: String(row.customer_name || row.customerName || row.name || "Cliente sem nome"),
      phone: formatPhone(phoneSource),
      phoneNormalized: canonicalPhoneDigits(phoneSource) || onlyDigits(phoneSource),
      description: String(row.description || row.notes || row.observations || ""),
      tag,
      tagLabel: String(row.tag_label || ATTENDANCE_TYPES[tag]?.singular || "Atendimento"),
      professionalId: String(row.professional_id || row.professionalId || ""),
      professionalName: String(row.professional_name || row.professional_name_snapshot || row.professionalName || "Não informado"),
      serviceValue: Number(row.service_value || row.serviceValue || 0),
      purchaseValue: Number(row.purchase_value || row.purchaseValue || 0),
      serviceOrder: String(row.service_order || row.serviceOrder || row.os || ""),
      attendedAt: row.attended_at || row.attendedAt || row.created_at || row.createdAt || "",
      linkedProspectId: String(linkedProspection.id || row.prospection_id || row.prospectionId || ""),
      prospectionMatchCount,
      prospectionAmbiguous: Boolean(
        prospectionMatchCount > 1
        || row.bonus_credit_status === "ambiguous_prospection",
      ),
    };
  }

  function unwrapAttendancePage(raw, requestedStoreId) {
    let payload = raw;
    if (Array.isArray(payload)) {
      payload = payload.length === 1 && payload[0] && typeof payload[0] === "object" && !Array.isArray(payload[0])
        ? payload[0]
        : { items: payload };
    }
    if (payload?.data && typeof payload.data === "object" && !payload.items && !payload.attendances) payload = payload.data;
    payload = payload && typeof payload === "object" ? payload : {};
    const responseStoreId = String(payload.store_id || payload.storeId || requestedStoreId || "");
    if (responseStoreId && responseStoreId !== requestedStoreId) throw new Error("A consulta retornou dados de outro cliente e foi bloqueada por segurança.");
    const items = Array.isArray(payload.items) ? payload.items : Array.isArray(payload.attendances) ? payload.attendances : [];
    const rows = items
      .filter((row) => String(row?.store_id || row?.storeId || requestedStoreId) === requestedStoreId)
      .map((row, index) => mapAttendanceOpportunity({ ...row, store_id: row?.store_id || row?.storeId || requestedStoreId }, index));
    return {
      rows,
      total: Number(payload.total ?? rows.length) || 0,
      hasMore: Boolean(payload.has_more ?? payload.hasMore ?? (rows.length >= 50)),
    };
  }

  function prospectResolutionForAttendance(attendance) {
    const key = normalizePhoneKey(attendance?.phone || attendance?.phoneNormalized);
    const storeProspects = prospects.filter((row) => row.storeId === attendance?.storeId);
    const phoneMatches = key
      ? storeProspects.filter((row) => normalizePhoneKey(row.phone) === key)
      : [];
    const linkedProspect = attendance.linkedProspectId
      ? storeProspects.find((row) => row.id === attendance.linkedProspectId) || null
      : null;
    const matchCount = Math.max(Number(attendance.prospectionMatchCount || 0), phoneMatches.length);
    if (attendance.prospectionAmbiguous || matchCount > 1) {
      return { prospect: null, ambiguous: true, count: matchCount };
    }
    return {
      prospect: linkedProspect || (phoneMatches.length === 1 ? phoneMatches[0] : null),
      ambiguous: false,
      count: linkedProspect || phoneMatches.length === 1 ? 1 : 0,
    };
  }

  function isInOptionalRange(value, startValue, endValue) {
    if (!value) return false;
    const range = dateRange(startValue, endValue);
    const date = new Date(value);
    return (!range.start || date >= range.start) && (!range.end || date < range.end);
  }

  function initializeInsightDates() {
    const now = new Date();
    if (!analysisStartDate) analysisStartDate = formatDateInput(startOfMonth(now));
    if (!analysisEndDate) analysisEndDate = formatDateInput(now);
    if (!bonusStartDate) bonusStartDate = formatDateInput(startOfWeek(now));
    if (!bonusEndDate) bonusEndDate = formatDateInput(now);
  }

  function periodWindow(period = dashboardPeriod) {
    const now = new Date();
    if (period === "today") return { start: startOfDay(now), end: addDays(startOfDay(now), 1), label: "Hoje" };
    if (period === "week") {
      const start = startOfWeek(now);
      return { start, end: addDays(start, 7), label: "Esta semana" };
    }
    if (period === "year") return { start: new Date(now.getFullYear(), 0, 1), end: new Date(now.getFullYear() + 1, 0, 1), label: "Este ano" };
    if (period === "all") return { start: null, end: null, label: "Todo o período" };
    const start = startOfMonth(now);
    return { start, end: addMonths(start, 1), label: "Este mês" };
  }

  function isInWindow(value, window) {
    if (!value) return false;
    if (!window.start || !window.end) return true;
    const date = new Date(value);
    return date >= window.start && date < window.end;
  }

  function percentage(value, total) {
    return total ? Math.round((Number(value || 0) / total) * 100) : 0;
  }

  function readableError(error) {
    const message = String(error?.message || error || "Não foi possível concluir a ação.");
    if (/lc_list_attendances/i.test(message)) {
      return "A consulta de Atendimentos ainda não está disponível no banco deste ambiente.";
    }
    if (/lc_(list|get|upsert|set|save|add|update|delete|reorder|import)_(prospection|prospec)/i.test(message) || /function .* does not exist/i.test(message)) {
      return "A estrutura do módulo de Prospecções ainda não foi instalada no banco principal.";
    }
    return message
      .replace(/^.*?raise exception\s*/i, "")
      .replace(/invalid input syntax.*$/i, "Dados inválidos.");
  }

  function normalizeRpcObject(raw) {
    if (Array.isArray(raw)) return raw[0] || {};
    return raw && typeof raw === "object" ? raw : {};
  }

  function mapProspect(row) {
    return {
      id: row.id,
      storeId: row.store_id,
      storeName: row.store_name || "Cliente",
      agencyId: row.technician_id || "",
      name: row.name || "",
      phone: row.phone || "",
      cpf: row.cpf || "",
      notes: row.notes || "",
      probability: PROBABILITIES[row.probability] ? row.probability : "blue",
      tagValues: Array.isArray(row.tags) ? row.tags : [],
      professionalId: row.professional_id || "",
      professionalName: row.professional_name || row.professional_name_snapshot || "",
      returnedAt: row.returned_at || null,
      purchasedAt: row.purchased_at || null,
      purchaseAmount: Number(row.purchase_amount || 0),
      purchaseOrder: row.purchase_order || "",
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  function mapSettings(row) {
    return {
      storeId: row.store_id,
      revision: row.revision || "",
      dailyGoal: Number(row.daily_goal ?? DEFAULT_SETTINGS.dailyGoal),
      bonusMinimum: Number(row.bonus_minimum ?? DEFAULT_SETTINGS.bonusMinimum),
      bonusAmount: Number(row.bonus_amount ?? DEFAULT_SETTINGS.bonusAmount),
      accentColor: row.accent_color || DEFAULT_SETTINGS.accentColor,
      logoBackgroundColor: row.logo_background_color || DEFAULT_SETTINGS.logoBackgroundColor,
    };
  }

  function mapProfessional(row) {
    return {
      id: row.id,
      storeId: row.store_id,
      name: row.name || "Profissional",
      active: row.is_active !== false,
    };
  }

  function mapTagCategory(row) {
    return {
      id: row.id,
      storeId: row.store_id,
      name: row.name || "Categoria",
      sortOrder: Number(row.sort_order || 0),
    };
  }

  function mapTag(row) {
    return {
      id: row.id,
      storeId: row.store_id,
      categoryId: row.category_id || "",
      label: row.label || "Etiqueta",
      sortOrder: Number(row.sort_order || 0),
    };
  }

  function scopedStores() {
    const allStores = bridge?.stores || [];
    if (bridge?.profile?.role === "store") return allStores.filter((store) => store.id === bridge.profile.storeId);
    if (bridge?.profile?.role === "technician") return allStores.filter((store) => store.technicianId === bridge.profile.id);
    if (selectedAgencyId) return allStores.filter((store) => store.technicianId === selectedAgencyId);
    return allStores;
  }

  function licensedScopedStores() {
    return scopedStores().filter((store) => store.prospectionEnabled !== false);
  }

  function isLicensedStore(storeId) {
    return Boolean(storeById(storeId)?.prospectionEnabled !== false && storeById(storeId));
  }

  function storeById(storeId) {
    return (bridge?.stores || []).find((store) => store.id === storeId) || null;
  }

  function settingsFor(storeId) {
    return settings.find((row) => row.storeId === storeId) || { storeId, ...DEFAULT_SETTINGS };
  }

  function professionalsFor(storeId, includeInactive = false) {
    return professionals
      .filter((row) => row.storeId === storeId && (includeInactive || row.active))
      .sort((a, b) => a.name.localeCompare(b.name, "pt-BR"));
  }

  function tagsFor(storeId) {
    return tags.filter((row) => row.storeId === storeId).sort((a, b) => a.sortOrder - b.sortOrder || a.label.localeCompare(b.label, "pt-BR"));
  }

  function categoriesFor(storeId) {
    return tagCategories.filter((row) => row.storeId === storeId).sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name, "pt-BR"));
  }

  function prospectsFor(storeIds, period = dashboardPeriod) {
    const idSet = new Set(Array.isArray(storeIds) ? storeIds : [storeIds]);
    const window = periodWindow(period);
    return prospects.filter((row) => idSet.has(row.storeId) && isInWindow(row.createdAt, window));
  }

  function isBonusEligible(prospect) {
    return Boolean(prospect.purchasedAt) && prospect.purchaseAmount >= settingsFor(prospect.storeId).bonusMinimum;
  }

  function bonusFor(rows) {
    return rows.reduce((sum, row) => sum + (isBonusEligible(row) ? settingsFor(row.storeId).bonusAmount : 0), 0);
  }

  function metricsFor(rows) {
    const returned = rows.filter((row) => row.returnedAt).length;
    const purchased = rows.filter((row) => row.purchasedAt).length;
    return {
      total: rows.length,
      returned,
      purchased,
      returnRate: percentage(returned, rows.length),
      conversion: percentage(purchased, rows.length),
      bonus: bonusFor(rows),
    };
  }

  function periodOptions(selected = dashboardPeriod) {
    return [
      ["today", "Hoje"],
      ["week", "Semana"],
      ["month", "Mês"],
      ["year", "Ano"],
      ["all", "Todo período"],
    ].map(([value, label]) => `<option value="${value}"${selected === value ? " selected" : ""}>${label}</option>`).join("");
  }

  function metricCards(rows, storeId = "") {
    const metrics = metricsFor(rows);
    const goal = storeId ? settingsFor(storeId).dailyGoal : null;
    const todayRows = rows.filter((row) => isInWindow(row.createdAt, periodWindow("today")));
    return `
      <section class="prospection-metrics" aria-label="Resumo das prospecções">
        ${metricCard("fa-bullseye", "Prospecções", metrics.total, periodWindow().label, "#16855f")}
        ${metricCard("fa-store", "Vieram à loja", metrics.returned, `${metrics.returnRate}% das prospecções`, "#2f80ed")}
        ${metricCard("fa-bag-shopping", "Compraram", metrics.purchased, `${metrics.conversion}% de conversão`, "#d48616")}
        ${metricCard("fa-chart-line", "Conversão", `${metrics.conversion}%`, "Compra sobre prospecções", "#7c5ce7")}
        ${metricCard("fa-gift", "Bonificação", formatCurrency(metrics.bonus), "Compras válidas no período", "#c43d59")}
        ${metricCard("fa-calendar-check", goal ? "Meta hoje" : "Atividade hoje", goal ? `${todayRows.length}/${goal}` : todayRows.length, goal ? `${percentage(todayRows.length, goal)}% da meta` : "Registros de hoje", "#168a91")}
      </section>`;
  }

  function metricCard(icon, label, value, helper, color) {
    return `<article class="prospection-metric" style="--metric-color:${color}">
      <i class="fa-solid ${icon}" aria-hidden="true"></i>
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value)}</strong>
      <small>${escapeHtml(helper)}</small>
    </article>`;
  }

  function loadingMarkup() {
    return `<div class="prospection-loading-card" role="status">
      <span class="prospection-loading-icon"><i class="fa-solid fa-circle-notch fa-spin" aria-hidden="true"></i></span>
      <div><p class="eyebrow">Prospecções</p><h2>Sincronizando dados</h2><span>Aplicando seu escopo de acesso com segurança.</span></div>
    </div>`;
  }

  function renderFatalError(message) {
    root.innerHTML = `<div class="prospection-error-card" role="alert">
      <span class="prospection-loading-icon"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span>
      <div><p class="eyebrow">Módulo indisponível</p><h2>Não foi possível carregar Prospecções</h2><span>${escapeHtml(message)}</span></div>
    </div>`;
  }

  async function loadData() {
    const [prospectRows, configurationRows] = await Promise.all([
      bridge.rpc("lc_list_prospections"),
      bridge.rpc("lc_get_prospection_configuration"),
    ]);
    prospects = (Array.isArray(prospectRows) ? prospectRows : []).map(mapProspect);
    const configuration = normalizeRpcObject(configurationRows);
    settings = (configuration.settings || []).map(mapSettings);
    professionals = (configuration.professionals || []).map(mapProfessional);
    tagCategories = (configuration.categories || []).map(mapTagCategory);
    tags = (configuration.tags || []).map(mapTag);
    configurationNeedsRefresh = false;
  }

  async function reload({ configuration = false } = {}) {
    if (configuration) {
      await loadData();
      return;
    }
    const rows = await bridge.rpc("lc_list_prospections");
    prospects = (Array.isArray(rows) ? rows : []).map(mapProspect);
  }

  async function activate(nextBridge) {
    bridge = nextBridge;
    active = true;
    loading = true;
    upgradePreview = bridge.profile.role === "store" && bridge.prospectionAccessGranted === false;
    selectedAgencyId = bridge.profile.role === "admin" ? bridge.initialAgencyId || "" : "";
    selectedStoreId = bridge.profile.role === "store" ? bridge.profile.storeId : bridge.initialStoreId || "";
    editingId = "";
    listSearch = "";
    listStatus = "all";
    filtersOpen = false;
    listMode = "records";
    attendanceListRequest += 1;
    attendanceListState = createAttendanceListState(selectedStoreId);
    prospectPrefill = null;
    calendarDate = new Date();
    analysisStoreId = "";
    analysisStartDate = "";
    analysisEndDate = "";
    analysisPeriod = "monthly";
    analysisProfessionalId = "all";
    analysisDetailProfessionalId = "";
    bonusStoreId = "";
    bonusStartDate = "";
    bonusEndDate = "";
    bonusProfessionalId = "all";
    initializeInsightDates();
    pendingPurchaseId = "";
    root.innerHTML = loadingMarkup();
    if (upgradePreview) {
      try {
        const archivedRows = await bridge.rpc("lc_export_prospections", { p_store_id: bridge.profile.storeId });
        archiveProspects = (Array.isArray(archivedRows) ? archivedRows : []).map(mapProspect);
      } catch (error) {
        archiveProspects = [];
        if (!/does not exist|could not find the function/i.test(String(error?.message || error))) throw error;
      }
      prospects = [...archiveProspects];
      settings = [];
      professionals = [];
      tagCategories = [];
      tags = [];
    } else {
      await loadData();
    }
    loading = false;
    if (!active) return;
    if (selectedStoreId && (!storeById(selectedStoreId) || !isLicensedStore(selectedStoreId))) selectedStoreId = "";
    render();
  }

  function deactivate() {
    active = false;
    upgradePreview = false;
    archiveProspects = [];
    attendanceListRequest += 1;
    attendanceListState = null;
    prospectPrefill = null;
    stopWorkspaceSizing();
    forceCloseDialogs();
  }

  async function refreshContext(nextContext = {}) {
    if (!bridge) return;
    bridge = { ...bridge, ...nextContext };
    if (!active || upgradePreview) return;
    const keepConfigurationOpen = Boolean(configurationSession && root.querySelector("[data-prospection-configuration-dialog]"));
    await loadData();
    if (selectedStoreId && !isLicensedStore(selectedStoreId)) selectedStoreId = "";
    render();
    if (keepConfigurationOpen) renderConfigurationDialog({ preserveSession: true });
  }

  function render() {
    if (!active || loading) return;
    stopWorkspaceSizing();
    if (upgradePreview) {
      bridge.setOperationMode?.(false);
      renderUpgradeExperience();
      return;
    }
    const isOperation = bridge.profile.role === "store" || Boolean(selectedStoreId);
    bridge.setOperationMode?.(isOperation);
    if (isOperation) renderStoreWorkspace();
    else renderManagementDashboard();
  }

  function renderUpgradeExperience() {
    const store = storeById(bridge.profile.storeId) || { id: bridge.profile.storeId, name: bridge.profile.storeName || "Sua empresa" };
    const agencyName = store.technicianName || "sua agência";
    root.innerHTML = `<section class="prospection-upgrade-shell" aria-labelledby="prospection-upgrade-title">
      <div class="prospection-upgrade-glow is-one"></div><div class="prospection-upgrade-glow is-two"></div>
      <div class="prospection-upgrade-hero">
        <span class="prospection-upgrade-icon"><i class="fa-solid fa-phone-volume" aria-hidden="true"></i><b><i class="fa-solid fa-arrow-trend-up"></i></b></span>
        <p class="eyebrow">Recurso premium</p>
        <h2 id="prospection-upgrade-title">Transforme contatos que seriam perdidos em novas oportunidades.</h2>
        <p>Prospecções ajuda sua empresa a controlar abordagens, acompanhar retornos e incentivar cada funcionário a trazer mais clientes para a loja.</p>
        <div class="prospection-upgrade-actions">
          ${archiveProspects.length ? `<button class="prospection-button is-archive" type="button" data-prospection-action="export-archive"><i class="fa-solid fa-file-arrow-down"></i>Baixar meus dados (${archiveProspects.length})</button>` : ""}
          <button class="prospection-button is-secondary" type="button" data-prospection-action="open-leads" data-store-id="${escapeHtml(store.id || "")}"><i class="fa-solid fa-arrow-left"></i>Voltar para Leads</button>
        </div>
        <small>Peça a liberação para <strong>${escapeHtml(agencyName)}</strong>. ${archiveProspects.length ? `Seus ${archiveProspects.length} registros ainda podem ser exportados, mas não editados.` : "A operação permanece bloqueada enquanto o recurso não estiver ativo."}</small>
        ${archiveProspects.length ? `<div class="prospection-archive-notice"><i class="fa-solid fa-clock-rotate-left"></i><span>O histórico é mantido por até dois anos desde a criação de cada registro. Exporte agora se precisar conservar uma cópia permanente.</span></div>` : ""}
      </div>
      <div class="prospection-upgrade-features" aria-label="Benefícios de Prospecções">
        <article><i class="fa-solid fa-user-group"></i><div><strong>Desempenho individual</strong><span>Veja quantas prospecções, retornos e compras cada funcionário gerou.</span></div></article>
        <article><i class="fa-solid fa-gift"></i><div><strong>Metas e bonificações</strong><span>Crie incentivo real para a equipe recuperar oportunidades esquecidas.</span></div></article>
        <article><i class="fa-solid fa-chart-line"></i><div><strong>Faturamento rastreável</strong><span>Acompanhe conversão, valores, OS e resultado por período.</span></div></article>
        <article><i class="fa-solid fa-rotate"></i><div><strong>Clientes recuperados</strong><span>Organize retornos e mantenha cada contato no radar até a decisão.</span></div></article>
      </div>
    </section>`;
  }

  function heroMarkup({ eyebrow, title, subtitle, backAction = "", actions = "" }) {
    return `<section class="prospection-hero">
      <span class="prospection-hero-icon"><i class="fa-solid fa-bullseye" aria-hidden="true"></i></span>
      <div class="prospection-hero-copy">
        <p class="eyebrow">${escapeHtml(eyebrow)}</p>
        <h2>${escapeHtml(title)}</h2>
        <span>${escapeHtml(subtitle)}</span>
      </div>
      <div class="prospection-hero-actions">
        ${backAction ? `<button class="prospection-button is-secondary" type="button" data-prospection-action="${backAction}"><i class="fa-solid fa-arrow-left"></i> Voltar</button>` : ""}
        ${actions}
      </div>
    </section>`;
  }

  function periodField() {
    return `<label class="prospection-period-field">Período<select data-prospection-period>${periodOptions()}</select></label>`;
  }

  function accountVisual(avatarUrl, name, icon = "fa-store", backgroundColor = "#ffffff") {
    return `<span class="prospection-account-icon${avatarUrl ? " has-image" : ""}" style="--logo-background:${escapeHtml(backgroundColor)}" aria-hidden="true">
      ${avatarUrl ? `<img src="${escapeHtml(avatarUrl)}" alt="" />` : `<i class="fa-solid ${icon}"></i>`}
    </span>`;
  }

  function periodOverviewMarkup(storeIds) {
    const definitions = [
      ["today", "Hoje"],
      ["week", "Esta semana"],
      ["month", "Este mês"],
      ["year", "Este ano"],
    ];
    return `<section class="prospection-overview-grid" aria-label="Resumo por período">
      ${definitions.map(([period, label]) => {
        const periodRows = prospectsFor(storeIds, period);
        const metric = metricsFor(periodRows);
        return `<article class="prospection-overview-card">
          <span>${metric.total}</span>
          <small>Prospecções · ${label}</small>
          <strong>${metric.returned} vieram <i></i> ${metric.purchased} compraram</strong>
        </article>`;
      }).join("")}
    </section>`;
  }

  function renderManagementDashboard() {
    const storesInScope = scopedStores();
    const isAdmin = bridge.profile.role === "admin";
    const agency = selectedAgencyId
      ? (bridge.agencies || []).find((item) => item.id === selectedAgencyId)
      : bridge.profile.role === "technician"
        ? (bridge.agencies || []).find((item) => item.id === bridge.profile.id) || bridge.profile
        : null;
    const storeIds = storesInScope.map((store) => store.id);
    const rows = prospectsFor(storeIds);
    const identityName = agency ? agency.fullName || agency.username : "Visão geral das agências";
    const licensedCount = storesInScope.filter((store) => store.prospectionEnabled !== false).length;
    const identitySubtitle = agency ? `${licensedCount} de ${storesInScope.length} clientes com Prospecções` : "Desempenho comercial da rede";
    root.innerHTML = `<section class="prospection-management-shell" aria-labelledby="prospection-admin-title">
      <header class="prospection-section-header prospection-management-header">
        <div class="prospection-section-heading">
          ${accountVisual(agency?.avatarUrl || "", identityName, agency ? "fa-building" : "fa-chart-pie", "#ffffff")}
          <div><p class="eyebrow">${isAdmin && !agency ? "Administração" : "Agência"}</p><h2 id="prospection-admin-title">${escapeHtml(identityName)}</h2><span>${escapeHtml(identitySubtitle)}</span></div>
        </div>
        <div class="prospection-section-actions">
          ${agency && isAdmin ? `<button class="prospection-button is-secondary" type="button" data-prospection-action="clear-agency"><i class="fa-solid fa-arrow-left"></i>Voltar</button>` : ""}
          ${periodField()}
          <button class="prospection-button is-secondary" type="button" data-prospection-action="open-analysis"><i class="fa-solid fa-chart-line"></i>Analisar cliente</button>
          <button class="prospection-button is-secondary" type="button" data-prospection-action="open-bonus"><i class="fa-solid fa-gift"></i>Bonificações</button>
          <button class="prospection-button" type="button" data-prospection-action="open-configuration"><i class="fa-solid fa-sliders"></i>Configurar clientes</button>
        </div>
      </header>
      ${metricCards(rows)}
      <div class="prospection-dashboard-layout">
        <article class="prospection-panel"><div class="prospection-panel-heading"><div><p class="eyebrow">Carteira</p><h3>${isAdmin && !agency ? "Agências" : "Clientes atendidos"}</h3><span>Logos, resultados e acesso rápido por conta.</span></div></div><div class="prospection-card-list">${renderManagementCards(storesInScope, isAdmin && !agency)}</div></article>
        <aside class="prospection-management-aside"><article class="prospection-panel"><div class="prospection-panel-heading"><div><p class="eyebrow">Evolução</p><h3>Ritmo de prospecção</h3><span>${escapeHtml(periodWindow().label)}</span></div></div>${chartMarkup(rows)}</article><article class="prospection-panel"><div class="prospection-panel-heading"><div><p class="eyebrow">Destaques</p><h3>Ranking da carteira</h3><span>Conversão por cliente licenciado.</span></div></div>${rankingMarkup(storesInScope.filter((store) => store.prospectionEnabled !== false))}</article></aside>
      </div>
    </section>`;
  }

  function renderManagementCards(storesInScope, groupAgencies) {
    if (groupAgencies) {
      const agencies = (bridge.agencies || []).filter((agency) => agency.isActive !== false);
      if (!agencies.length) return emptyMarkup("Nenhuma agência cadastrada", "Crie a primeira agência no módulo Leads para começar.");
      return agencies.map((agency, index) => {
        const agencyStores = (bridge.stores || []).filter((store) => store.technicianId === agency.id);
        const licensedAgencyStores = agencyStores.filter((store) => store.prospectionEnabled !== false);
        const rows = prospectsFor(licensedAgencyStores.map((store) => store.id));
        const metrics = metricsFor(rows);
        return accountCard({ id: agency.id, name: agency.fullName || agency.username, subtitle: `${licensedAgencyStores.length} de ${agencyStores.length} clientes com Prospecções`, avatarUrl: agency.avatarUrl || "", icon: "fa-building", color: STORE_COLORS[index % STORE_COLORS.length], metrics, goalText: `${metrics.returnRate}% retornaram · ${metrics.conversion}% converteram`, progress: metrics.conversion, action: "select-agency", actionLabel: "Ver agência" });
      }).join("");
    }

    if (!storesInScope.length) return emptyMarkup("Nenhum cliente neste escopo", "Cadastre clientes no módulo Leads para acompanhar Prospecções.");
    return storesInScope.map((store, index) => {
      const rows = prospectsFor(store.id);
      const metrics = metricsFor(rows);
      const config = settingsFor(store.id);
      const todayCount = prospectsFor(store.id, "today").length;
      return accountCard({ id: store.id, name: store.name, subtitle: store.username || "Cliente", avatarUrl: store.avatarUrl || "", logoBackground: config.logoBackgroundColor, color: config.accentColor || STORE_COLORS[index % STORE_COLORS.length], metrics, goalText: `${todayCount}/${config.dailyGoal} da meta diária`, progress: percentage(todayCount, config.dailyGoal), action: "select-store", actionLabel: "Acessar", secondaryAction: "open-store-analysis", bonusAction: "open-store-bonus", configurationAction: "open-configuration", locked: store.prospectionEnabled === false });
    }).join("");
  }

  function accountCard({ id, name, subtitle, icon, avatarUrl = "", logoBackground = "#ffffff", color, metrics, goalText, progress, action, actionLabel, secondaryAction = "", bonusAction = "", configurationAction = "", locked = false }) {
    return `<article class="prospection-account-card${locked ? " is-locked" : ""}" style="--account-color:${color}">
      <div class="prospection-account-card-header">
        <div class="prospection-account-identity">${accountVisual(avatarUrl, name, icon, logoBackground)}<div><strong>${escapeHtml(name)}</strong><span>${escapeHtml(subtitle)}</span></div></div>
        <div class="prospection-access-badges">${locked ? `<span class="prospection-chip is-locked">Somente Leads</span>` : `<span class="prospection-chip is-prospec"><i class="fa-solid fa-phone"></i>PROSPEC</span><span class="prospection-chip is-purchased">${formatCurrency(metrics.bonus)}</span>`}</div>
      </div>
      <div class="prospection-account-stats">
        ${accountStat(metrics.total, "prospecções")}${accountStat(metrics.returned, "vieram")}${accountStat(metrics.purchased, "compraram")}${accountStat(`${metrics.conversion}%`, "conversão")}
      </div>
      <div class="prospection-progress"><div class="prospection-progress-copy"><span>${escapeHtml(goalText)}</span><strong>${Math.min(100, progress)}%</strong></div><div class="prospection-progress-track"><i style="--progress:${Math.min(100, progress)}%"></i></div></div>
      <div class="prospection-account-actions">
        ${locked ? `<button class="prospection-button is-secondary" type="button" data-prospection-action="manage-access" data-store-id="${escapeHtml(id)}"><i class="fa-solid fa-key"></i>Gerenciar acesso</button>` : `
          ${secondaryAction ? `<button class="prospection-button is-quiet" type="button" data-prospection-action="${secondaryAction}" data-store-id="${escapeHtml(id)}">Análise</button>` : ""}
          ${bonusAction ? `<button class="prospection-button is-quiet" type="button" data-prospection-action="${bonusAction}" data-store-id="${escapeHtml(id)}">Bonificação</button>` : ""}
          ${configurationAction ? `<button class="prospection-button is-quiet" type="button" data-prospection-action="${configurationAction}" data-store-id="${escapeHtml(id)}"><i class="fa-solid fa-sliders"></i>Campos</button>` : ""}
          <button class="prospection-button" type="button" data-prospection-action="${action}" data-account-id="${escapeHtml(id)}">${escapeHtml(actionLabel)}</button>`}
      </div>
    </article>`;
  }

  const accountStat = (value, label) => `<span class="prospection-account-stat"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></span>`;

  function rankingMarkup(storesInScope) {
    const rows = storesInScope.map((store) => {
      const metrics = metricsFor(prospectsFor(store.id));
      return { name: store.name, subtitle: `${metrics.total} prospecções`, purchased: metrics.purchased, conversion: metrics.conversion };
    }).sort((a, b) => b.purchased - a.purchased || b.conversion - a.conversion || a.name.localeCompare(b.name, "pt-BR"));
    if (!rows.length) return emptyMarkup("Ranking ainda vazio", "Os resultados aparecerão após os primeiros registros.");
    return `<div class="prospection-ranking">${rows.map((row, index) => `<div class="prospection-ranking-row"><span class="prospection-ranking-position">${index + 1}</span><div class="prospection-ranking-name"><strong>${escapeHtml(row.name)}</strong><span>${escapeHtml(row.subtitle)}</span></div><div class="prospection-ranking-value"><strong>${row.purchased}</strong><span>${row.conversion}% conversão</span></div></div>`).join("")}</div>`;
  }

  function trendBuckets(rows) {
    const window = periodWindow();
    const now = new Date();
    let count = 14;
    let start = addDays(startOfDay(now), -(count - 1));
    if (dashboardPeriod === "week") { count = 7; start = startOfWeek(now); }
    if (dashboardPeriod === "today") { count = 12; start = new Date(startOfDay(now)); }
    if (dashboardPeriod === "month") { count = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate(); start = startOfMonth(now); }
    if (dashboardPeriod === "year") { count = 12; start = new Date(now.getFullYear(), 0, 1); }
    if (dashboardPeriod === "all") { count = 12; start = addMonths(startOfMonth(now), -11); }
    return Array.from({ length: count }, (_, index) => {
      const bucketStart = dashboardPeriod === "year" || dashboardPeriod === "all" ? addMonths(start, index) : dashboardPeriod === "today" ? new Date(start.getTime() + index * 2 * 3600000) : addDays(start, index);
      const bucketEnd = dashboardPeriod === "year" || dashboardPeriod === "all" ? addMonths(bucketStart, 1) : dashboardPeriod === "today" ? new Date(bucketStart.getTime() + 2 * 3600000) : addDays(bucketStart, 1);
      const label = dashboardPeriod === "year" || dashboardPeriod === "all"
        ? new Intl.DateTimeFormat("pt-BR", { month: "short" }).format(bucketStart).replace(".", "")
        : dashboardPeriod === "today" ? `${String(bucketStart.getHours()).padStart(2, "0")}h` : String(bucketStart.getDate());
      return { label, value: rows.filter((row) => isInWindow(row.createdAt, { start: bucketStart, end: bucketEnd })).length };
    });
  }

  function chartMarkup(rows) {
    const buckets = trendBuckets(rows);
    const max = Math.max(1, ...buckets.map((bucket) => bucket.value));
    return `<div class="prospection-mini-chart" style="--chart-columns:${buckets.length}">${buckets.map((bucket) => `<div class="prospection-chart-column" title="${bucket.value} prospecções"><div class="prospection-chart-bar-wrap"><i class="prospection-chart-bar" style="--height:${Math.max(3, (bucket.value / max) * 100)}%"></i></div><span>${escapeHtml(bucket.label)}</span></div>`).join("")}</div>`;
  }

  function emptyMarkup(title, subtitle) {
    return `<div class="prospection-empty"><i class="fa-solid fa-bullseye"></i><strong>${escapeHtml(title)}</strong><span>${escapeHtml(subtitle)}</span></div>`;
  }

  function renderStoreWorkspace() {
    const storeId = bridge.profile.role === "store" ? bridge.profile.storeId : selectedStoreId;
    const store = storeById(storeId) || { id: storeId, name: bridge.profile.storeName || "Cliente", username: bridge.profile.username };
    selectedStoreId = store.id;
    ensureAttendanceListState(store.id);
    root.innerHTML = `${operationContextMarkup(store)}
      <section id="operationWorkspace" class="workspace">
        ${prospectFormMarkup(store.id)}
        ${prospectListPanelMarkup(store.id)}
      </section>`;
    initializeWorkspaceSizing();
  }

  function stopWorkspaceSizing() {
    if (workspaceResizeObserver) {
      workspaceResizeObserver.disconnect();
      workspaceResizeObserver = null;
    }
    if (workspaceResizeFrame) {
      cancelAnimationFrame(workspaceResizeFrame);
      workspaceResizeFrame = 0;
    }
  }

  function scheduleWorkspaceSizing() {
    if (!active) return;
    if (workspaceResizeFrame) cancelAnimationFrame(workspaceResizeFrame);
    workspaceResizeFrame = requestAnimationFrame(syncWorkspacePanelHeight);
  }

  function syncWorkspacePanelHeight() {
    workspaceResizeFrame = 0;
    const workspace = root.querySelector("#operationWorkspace");
    const formPanel = workspace?.querySelector(":scope > .form-panel");
    const listPanel = workspace?.querySelector(":scope > .list-panel");
    if (!workspace || !formPanel || !listPanel) return;

    listPanel.style.removeProperty("height");
    if (!window.matchMedia("(min-width: 721px)").matches) return;

    const formHeight = Math.ceil(formPanel.getBoundingClientRect().height);
    if (formHeight > 0) listPanel.style.height = `${formHeight}px`;
  }

  function initializeWorkspaceSizing() {
    const formPanel = root.querySelector("#operationWorkspace > .form-panel");
    if (!formPanel) return;
    if (typeof ResizeObserver === "function") {
      workspaceResizeObserver = new ResizeObserver(scheduleWorkspaceSizing);
      workspaceResizeObserver.observe(formPanel);
    }
    scheduleWorkspaceSizing();
  }

  function operationContextMarkup(store) {
    const config = settingsFor(store.id);
    const isManager = ["admin", "technician"].includes(bridge.profile.role);
    const metrics = metricsFor(prospectsFor(store.id, "week"));
    return `<section class="prospection-operation-context" style="--account-color:${escapeHtml(config.accentColor)}">
      <div class="prospection-account-identity">
        ${accountVisual(store.avatarUrl || "", store.name, "fa-store", config.logoBackgroundColor)}
        <div><small>Operação do cliente</small><strong>${escapeHtml(store.name)}</strong><span>${metrics.total} prospecções nesta semana · ${metrics.conversion}% de conversão</span></div>
      </div>
      <div class="prospection-operation-actions">
        <button class="analysis-button" type="button" data-prospection-action="open-analysis"><i class="fa-solid fa-chart-line"></i><span>Análise</span></button>
        <button class="secondary-button" type="button" data-prospection-action="open-bonus"><i class="fa-solid fa-gift"></i><span>Bonificações</span></button>
        ${isManager ? `<button class="secondary-button" type="button" data-prospection-action="open-configuration" data-store-id="${escapeHtml(store.id)}"><i class="fa-solid fa-sliders"></i><span>Configurar</span></button><button class="secondary-button" type="button" data-prospection-action="back-dashboard"><i class="fa-solid fa-arrow-left"></i><span>Voltar</span></button>` : ""}
      </div>
    </section>`;
  }

  function prospectFormMarkup(storeId) {
    const editing = prospects.find((row) => row.id === editingId) || null;
    const draft = editing || prospectPrefill || null;
    const isAttendancePrefill = Boolean(!editing && prospectPrefill);
    const storeProfessionals = professionalsFor(storeId);
    return `<aside class="panel form-panel" aria-labelledby="form-title">
      <div class="panel-header">
        <div><p class="eyebrow">${editing ? "Atualização" : isAttendancePrefill ? "Atendimento selecionado" : "Novo contato"}</p><h2 id="form-title">${editing ? "Editar prospecção" : isAttendancePrefill ? "Revisar e prospectar" : "Registrar prospecção"}</h2></div>
        <button class="icon-button" type="button" data-prospection-action="clear-form" title="Limpar formulário" aria-label="Limpar formulário">&#8634;</button>
      </div>
      <form id="prospectForm" autocomplete="off">
        <input type="hidden" name="prospectId" value="${escapeHtml(editing?.id || "")}" />
        <label>Nome<input name="name" type="text" maxlength="160" value="${escapeHtml(draft?.name || "")}" placeholder="Joao da Silva" required /></label>
        <label>Telefone<input name="phone" type="tel" inputmode="tel" value="${escapeHtml(draft?.phone || "")}" placeholder="(19)000000000" /></label>
        <label>CPF<input name="cpf" type="text" inputmode="numeric" value="${escapeHtml(draft?.cpf || "")}" placeholder="123.456.789-00" /></label>
        <label>Anotações<textarea name="notes" rows="5" maxlength="2000" placeholder="Interessada em óculos de grau, voltar com receita.">${escapeHtml(draft?.notes || "")}</textarea></label>
        <section class="professional-picker" aria-labelledby="professional-picker-title">
          <div class="professional-picker-header"><span id="professional-picker-title">Profissional</span></div>
          <div class="professional-options">${storeProfessionals.length ? storeProfessionals.map((professional) => `<label class="professional-option"><input type="radio" name="professionalId" value="${professional.id}"${draft?.professionalId === professional.id ? " checked" : ""} /><span>${escapeHtml(professional.name)}</span></label>`).join("") : `<span class="professional-empty">Nenhum profissional cadastrado pela agência.</span>`}</div>
        </section>
        ${tagCategoryPickerMarkup(storeId, draft)}
        <fieldset class="status-picker">
          <legend>Probabilidade</legend>
          ${Object.entries(PROBABILITIES).map(([key, item]) => `<label class="status-option"><input type="radio" name="probability" value="${key}"${(draft?.probability || "blue") === key ? " checked" : ""} /><span class="swatch swatch-${key}"></span><span>${item.label}</span></label>`).join("")}
        </fieldset>
        <p id="prospectionFormMessage" class="form-error" role="alert"></p>
        <button class="primary-button" type="submit"><span>${editing ? "Salvar alterações" : isAttendancePrefill ? "Registrar esta prospecção" : "Registrar prospecção"}</span></button>
      </form>
    </aside>`;
  }

  function tagCategoryPickerMarkup(storeId, editing) {
    const storeCategories = categoriesFor(storeId);
    return `<section class="tag-editor" aria-label="Categorias da prospecção">
      ${storeCategories.length ? storeCategories.map((category) => {
        const categoryTags = tagsFor(storeId).filter((tag) => tag.categoryId === category.id);
        return `<div class="tag-category-group"><small>${escapeHtml(category.name)}</small><div class="tag-options">${categoryTags.length ? categoryTags.map((tag) => `<label class="tag-option"><input type="checkbox" name="tags" value="${escapeHtml(tag.label)}"${editing?.tagValues.includes(tag.label) ? " checked" : ""} /><span>${escapeHtml(tag.label)}</span></label>`).join("") : `<span class="professional-empty">Nenhuma etiqueta</span>`}</div></div>`;
      }).join("") : `<span class="professional-empty">Nenhuma categoria configurada pela Agência.</span>`}
    </section>`;
  }

  function prospectListPanelMarkup(storeId) {
    const filterCount = Number(dashboardPeriod !== "today") + Number(listStatus !== "all");
    const periodTitle = dashboardPeriod === "today" ? ["Hoje", "Prospecções do dia"] : ["Acompanhamento", "Prospecções registradas"];
    const attendanceState = ensureAttendanceListState(storeId);
    const isAttendanceMode = listMode === "attendances";
    return `<section id="prospectionListPanel" class="panel list-panel${isAttendanceMode ? " is-attendance-mode" : ""}" aria-labelledby="list-title">
      <div class="list-toolbar prospection-operation-list-toolbar">
        <div class="prospection-list-heading-row">
          <div class="panel-header list-header"><div><p class="eyebrow">${isAttendanceMode ? "Carteira de atendimentos" : periodTitle[0]}</p><h2 id="list-title">${isAttendanceMode ? "Atendimentos para prospectar" : periodTitle[1]}</h2>${isAttendanceMode ? `<span class="prospection-list-helper">Consulte o contexto antes de entrar em contato.</span>` : ""}</div></div>
          <div class="prospection-list-modes" role="group" aria-label="Visualização de prospecções">
            <button type="button" aria-pressed="${String(!isAttendanceMode)}" class="${!isAttendanceMode ? "is-active" : ""}" data-prospection-action="set-list-mode" data-list-mode="records"><i class="fa-solid fa-list-check" aria-hidden="true"></i><span>Registradas</span></button>
            <button type="button" aria-pressed="${String(isAttendanceMode)}" class="${isAttendanceMode ? "is-active" : ""}" data-prospection-action="set-list-mode" data-list-mode="attendances"><i class="fa-solid fa-user-clock" aria-hidden="true"></i><span>Para prospectar</span></button>
          </div>
        </div>
        ${isAttendanceMode ? attendanceFiltersMarkup(attendanceState) : `<div class="search-row">
          <label class="search-label">Buscar nas prospecções<input data-prospection-search type="search" value="${escapeHtml(listSearch)}" placeholder="Nome, telefone, CPF ou anotação" /></label>
          <div class="filter-menu">
            <button class="filter-button" type="button" data-prospection-action="toggle-filters" aria-expanded="${String(filtersOpen)}"><i class="fa-solid fa-filter" aria-hidden="true"></i>Filtros${filterCount ? `<span class="filter-count">${filterCount}</span>` : ""}</button>
            <div class="filters-panel"${filtersOpen ? "" : " hidden"}>
              <label>Período<select data-prospection-period>${periodOptions()}</select></label>
              <label>Situação<select data-prospection-status><option value="all"${listStatus === "all" ? " selected" : ""}>Todos</option><option value="open"${listStatus === "open" ? " selected" : ""}>Não voltaram</option><option value="returned"${listStatus === "returned" ? " selected" : ""}>Voltaram</option><option value="purchased"${listStatus === "purchased" ? " selected" : ""}>Compraram</option></select></label>
            </div>
          </div>
        </div>`}
      </div>
      <div id="prospectionRecords" class="prospects-list${isAttendanceMode ? " prospection-attendance-list" : ""}" role="region" aria-label="${isAttendanceMode ? "Atendimentos disponíveis para prospecção" : "Prospecções registradas"}" aria-live="polite" aria-busy="${String(isAttendanceMode && attendanceState.loading)}" tabindex="0">${isAttendanceMode ? attendanceOpportunityListMarkup(attendanceState) : recordListMarkup(storeId)}</div>
    </section>`;
  }

  function attendanceFiltersMarkup(state) {
    const types = Object.entries(ATTENDANCE_TYPES).map(([value, item]) => `<option value="${value}"${state.tag === value ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("");
    return `<div class="prospection-attendance-query">
      ${dateShortcutsMarkup("attendance", state.startDate, state.endDate)}
      <form id="prospectionAttendanceFilters" class="prospection-attendance-filters">
        <label class="prospection-attendance-search"><span>Buscar cliente</span><div><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i><input name="search" type="search" value="${escapeHtml(state.search)}" placeholder="Nome, telefone ou descrição" /></div></label>
        <label><span>Tipo</span><select name="tag">${types}</select></label>
        <label><span>Data inicial</span><input name="startDate" type="date" value="${escapeHtml(state.startDate)}" required /></label>
        <label><span>Data final</span><input name="endDate" type="date" value="${escapeHtml(state.endDate)}" required /></label>
        <button class="filter-button prospection-attendance-submit" type="submit"${state.loading ? " disabled" : ""}><i class="fa-solid ${state.loading ? "fa-circle-notch fa-spin" : "fa-filter"}" aria-hidden="true"></i>${state.loading ? "Buscando" : "Buscar atendimentos"}</button>
      </form>
    </div>`;
  }

  function attendanceOpportunityListMarkup(state) {
    if (state.loading && !state.rows.length) {
      return `<div class="prospection-attendance-state" role="status"><span><i class="fa-solid fa-circle-notch fa-spin" aria-hidden="true"></i></span><strong>Buscando atendimentos</strong><p>Consultando apenas os registros desta empresa.</p></div>`;
    }
    if (state.error && !state.rows.length) {
      return `<div class="prospection-attendance-state is-error"><span><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span><strong>Não foi possível carregar a lista</strong><p>${escapeHtml(state.error)}</p><button class="edit-button" type="button" data-prospection-action="retry-attendances"><i class="fa-solid fa-arrow-rotate-right" aria-hidden="true"></i>Tentar novamente</button></div>`;
    }
    if (!state.loaded) {
      return `<div class="prospection-attendance-state"><span><i class="fa-solid fa-address-book" aria-hidden="true"></i></span><strong>Encontre oportunidades nos atendimentos</strong><p>Escolha o tipo e o período. Você verá a descrição e quem atendeu antes de chamar o cliente.</p><button class="edit-button" type="button" data-prospection-action="retry-attendances"><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>Buscar agora</button></div>`;
    }
    if (!state.rows.length) {
      return `<div class="prospection-attendance-state"><span><i class="fa-solid fa-user-check" aria-hidden="true"></i></span><strong>Nenhum atendimento neste filtro</strong><p>Tente outro tipo ou amplie o período da busca.</p></div>`;
    }
    const loaded = state.rows.length;
    return `<div class="prospection-attendance-results-heading"><div><strong>${state.total} atendimento${state.total === 1 ? "" : "s"}</strong><span>Contexto completo para uma abordagem melhor</span></div><span>${loaded} carregado${loaded === 1 ? "" : "s"}</span></div>
      ${state.rows.map(attendanceOpportunityCardMarkup).join("")}
      ${state.error ? `<p class="prospection-attendance-inline-error"><i class="fa-solid fa-circle-exclamation" aria-hidden="true"></i>${escapeHtml(state.error)}</p>` : ""}
      ${state.hasMore ? `<button class="prospection-attendance-more" type="button" data-prospection-action="load-more-attendances"${state.loading ? " disabled" : ""}><i class="fa-solid ${state.loading ? "fa-circle-notch fa-spin" : "fa-chevron-down"}" aria-hidden="true"></i>${state.loading ? "Carregando" : "Carregar mais atendimentos"}</button>` : `<p class="prospection-attendance-end"><i class="fa-solid fa-circle-check" aria-hidden="true"></i>Todos os resultados do período foram carregados.</p>`}`;
  }

  function attendanceOpportunityCardMarkup(row) {
    const type = ATTENDANCE_TYPES[row.tag] || ATTENDANCE_TYPES.other;
    const phone = phoneDigits(row.phone || row.phoneNormalized);
    const resolution = prospectResolutionForAttendance(row);
    const existing = resolution.prospect;
    const value = row.tag === "purchase" ? row.purchaseValue || row.serviceValue : row.serviceValue;
    return `<article class="prospection-attendance-card" data-attendance-type="${escapeHtml(row.tag)}">
      <div class="prospection-attendance-card-head">
        <div class="prospection-attendance-person"><span>${escapeHtml(row.customerName.slice(0, 1).toUpperCase() || "C")}</span><div><h3>${escapeHtml(row.customerName)}</h3><p>${escapeHtml(row.phone || "Telefone não informado")}</p></div></div>
        <div class="prospection-attendance-badges"><span class="prospection-attendance-type"><i class="fa-solid ${type.icon}" aria-hidden="true"></i>${escapeHtml(row.tagLabel)}</span>${existing ? `<span class="prospection-attendance-existing"><i class="fa-solid fa-circle-check" aria-hidden="true"></i>Já em Prospecções</span>` : resolution.ambiguous ? `<span class="prospection-attendance-ambiguous"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>${resolution.count} registros com este telefone</span>` : ""}</div>
      </div>
      <div class="prospection-attendance-context"><small>Contexto do atendimento</small><p>${escapeHtml(row.description || "Nenhuma descrição foi informada neste atendimento.")}</p></div>
      <div class="prospection-attendance-meta">
        <span><i class="fa-solid fa-user-tie" aria-hidden="true"></i><small>Atendido por</small><strong>${escapeHtml(row.professionalName)}</strong></span>
        <span><i class="fa-solid fa-calendar-day" aria-hidden="true"></i><small>Data</small><strong>${escapeHtml(formatDateTime(row.attendedAt))}</strong></span>
        ${value ? `<span><i class="fa-solid fa-brazilian-real-sign" aria-hidden="true"></i><small>Valor</small><strong>${escapeHtml(formatCurrency(value))}</strong></span>` : ""}
        ${row.serviceOrder ? `<span><i class="fa-solid fa-receipt" aria-hidden="true"></i><small>OS</small><strong>${escapeHtml(row.serviceOrder)}</strong></span>` : ""}
      </div>
      <div class="prospection-attendance-actions">
        ${phone ? `<a class="phone-button" href="tel:${escapeHtml(phone)}"><i class="fa-solid fa-phone" aria-hidden="true"></i>Ligar</a>` : `<span class="prospection-attendance-no-phone"><i class="fa-solid fa-phone-slash" aria-hidden="true"></i>Sem telefone</span>`}
        ${existing ? `<button class="edit-button" type="button" data-prospection-action="edit-prospect" data-prospect-id="${escapeHtml(existing.id)}"><i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true"></i>Abrir prospecção</button>` : resolution.ambiguous ? `<button class="edit-button" type="button" data-prospection-action="review-duplicate-prospects" data-attendance-id="${escapeHtml(row.id)}"><i class="fa-solid fa-list" aria-hidden="true"></i>Revisar registros</button>` : `<button class="mark-returned-button" type="button" data-prospection-action="prefill-attendance" data-attendance-id="${escapeHtml(row.id)}"><i class="fa-solid fa-user-plus" aria-hidden="true"></i>Usar no cadastro</button>`}
      </div>
    </article>`;
  }

  function filteredStoreRows(storeId) {
    const query = normalize(listSearch);
    const queryPhone = normalizePhoneKey(listSearch);
    return prospectsFor(storeId).filter((row) => {
      const matchesQuery = !query
        || normalize([row.name, row.phone, row.cpf, row.notes, row.professionalName, ...row.tagValues].join(" ")).includes(query)
        || Boolean(queryPhone && normalizePhoneKey(row.phone) === queryPhone);
      const matchesStatus = listStatus === "all"
        || (listStatus === "open" && !row.returnedAt)
        || (listStatus === "returned" && row.returnedAt)
        || (listStatus === "purchased" && row.purchasedAt);
      return matchesQuery && matchesStatus;
    });
  }

  function recordListMarkup(storeId) {
    const rows = filteredStoreRows(storeId);
    if (!rows.length) return `<div class="empty-state is-visible"><strong>Nenhuma prospecção encontrada</strong><span>Ajuste os filtros ou registre um novo contato.</span></div>`;
    return rows.map(recordCardMarkup).join("");
  }

  function recordCardMarkup(row) {
    const probability = PROBABILITIES[row.probability];
    const phoneNumber = phoneDigits(row.phone);
    const phoneUrl = phoneNumber ? `tel:${phoneNumber}` : "";
    const info = `${row.professionalName ? `<div class="card-professional"><i class="fa-solid fa-user-check" aria-hidden="true"></i><span>Profissional</span><strong>${escapeHtml(row.professionalName)}</strong></div>` : ""}${row.purchasedAt && (row.purchaseAmount || row.purchaseOrder) ? `<div class="card-purchase-info"><i class="fa-solid fa-receipt" aria-hidden="true"></i><span>Compra</span>${row.purchaseAmount ? `<strong>${formatCurrency(row.purchaseAmount)}</strong>` : ""}${row.purchaseOrder ? `<em>${escapeHtml(row.purchaseOrder)}</em>` : ""}</div>` : ""}`;
    return `<article class="prospect-card" data-color="${escapeHtml(row.probability)}">
      <div class="card-main">
        <div class="card-title-block"><div class="card-title-row"><h3 class="card-name">${escapeHtml(row.name)}</h3></div><div class="card-meta">${row.phone ? `<span class="meta-chip">${escapeHtml(row.phone)}</span>` : ""}${row.cpf ? `<span class="meta-chip">${escapeHtml(row.cpf)}</span>` : ""}${!row.phone && !row.cpf ? `<span class="meta-chip">Sem telefone ou CPF</span>` : ""}</div></div>
        <div class="card-badges"><span class="color-badge">${escapeHtml(probability.label)}</span>${row.tagValues.length ? `<div class="card-tags">${row.tagValues.map((tag) => `<span class="tag-chip">${escapeHtml(tag)}</span>`).join("")}</div>` : ""}</div>
      </div>
      ${row.notes ? `<p class="card-notes">${escapeHtml(row.notes)}</p>` : ""}
      ${info ? `<div class="card-info-row">${info}</div>` : ""}
      <div class="card-bottom">
        <div class="card-actions">
          ${phoneUrl ? `<a class="phone-button" href="${phoneUrl}"><i class="fa-solid fa-phone" aria-hidden="true"></i>Ligar</a>` : ""}
          ${!row.returnedAt ? `<button class="mark-returned-button" type="button" data-prospection-action="toggle-returned" data-prospect-id="${row.id}" data-next-value="true">Registrar volta</button>` : !row.purchasedAt ? `<button class="unmark-returned-button" type="button" data-prospection-action="toggle-returned" data-prospect-id="${row.id}" data-next-value="false">Tirar volta</button>` : ""}
          <button class="${row.purchasedAt ? "unmark-purchased-button" : "mark-purchased-button"}" type="button" data-prospection-action="${row.purchasedAt ? "unmark-purchased" : "open-purchase"}" data-prospect-id="${row.id}">${row.purchasedAt ? "Tirar compra" : "Registrar compra"}</button>
          <button class="edit-button" type="button" data-prospection-action="edit-prospect" data-prospect-id="${row.id}">Editar</button>
          <button class="delete-button" type="button" data-prospection-action="confirm-delete" data-prospect-id="${row.id}">Excluir</button>
        </div>
        <div class="card-footer-meta"><div class="created-date-block"><strong>Registrado</strong><em>${escapeHtml(formatDateTimeWithWeekday(row.createdAt))}</em></div><span class="return-badge${row.returnedAt ? " is-returned" : ""}">${row.returnedAt ? `<i class="fa-solid fa-check" aria-hidden="true"></i><span>Voltou</span>` : "Não voltou"}</span>${row.purchasedAt ? `<span class="purchase-badge is-purchased"><i class="fa-solid fa-bag-shopping" aria-hidden="true"></i><span>Comprou</span></span>` : ""}</div>
      </div>
    </article>`;
  }

  function renderRecordList() {
    const container = root.querySelector("#prospectionRecords");
    if (container && selectedStoreId) container.innerHTML = recordListMarkup(selectedStoreId);
  }

  function renderProspectListPanel({ focusSelector = "", scrollTop } = {}) {
    const panel = root.querySelector("#prospectionListPanel");
    if (!panel || !selectedStoreId) return;
    const previousList = panel.querySelector("#prospectionRecords");
    const nextScrollTop = Number.isFinite(scrollTop) ? scrollTop : Number(previousList?.scrollTop || 0);
    panel.outerHTML = prospectListPanelMarkup(selectedStoreId);
    scheduleWorkspaceSizing();
    const nextList = root.querySelector("#prospectionRecords");
    if (nextList) nextList.scrollTop = nextScrollTop;
    if (focusSelector) {
      requestAnimationFrame(() => root.querySelector(focusSelector)?.focus({ preventScroll: true }));
    }
  }

  async function loadAttendanceOpportunities({ append = false } = {}) {
    const requestedStoreId = bridge.profile.role === "store" ? String(bridge.profile.storeId || "") : String(selectedStoreId || "");
    if (!requestedStoreId) {
      bridge.notify("Selecione um cliente para consultar os atendimentos.", "error");
      return;
    }
    const state = ensureAttendanceListState(requestedStoreId);
    if (state.loading || (append && !state.hasMore)) return;
    if (state.startDate && state.endDate && state.startDate > state.endDate) {
      bridge.notify("A data inicial não pode ser posterior à data final.", "error");
      return;
    }

    const request = ++attendanceListRequest;
    state.loading = true;
    state.error = "";
    if (!append) {
      state.rows = [];
      state.total = 0;
      state.hasMore = false;
    }
    renderProspectListPanel({ scrollTop: append ? undefined : 0 });

    try {
      const raw = await bridge.rpc("lc_list_attendances", {
        p_store_id: requestedStoreId,
        p_search: state.search || null,
        p_tag: state.tag === "all" ? null : state.tag,
        p_professional_id: null,
        p_link_status: null,
        p_start_date: state.startDate || null,
        p_end_date: state.endDate || null,
        p_limit: 50,
        p_offset: append ? state.rows.length : 0,
      });
      if (!active || request !== attendanceListRequest || listMode !== "attendances" || selectedStoreId !== requestedStoreId || attendanceListState !== state) return;
      const page = unwrapAttendancePage(raw, requestedStoreId);
      if (append) {
        const known = new Set(state.rows.map((row) => row.id));
        state.rows = [...state.rows, ...page.rows.filter((row) => !known.has(row.id))];
      } else {
        state.rows = page.rows;
      }
      state.total = page.total;
      state.hasMore = page.hasMore;
      state.loaded = true;
    } catch (error) {
      if (!active || request !== attendanceListRequest || attendanceListState !== state) return;
      state.error = readableError(error);
      state.loaded = true;
    } finally {
      if (request === attendanceListRequest && attendanceListState === state) {
        state.loading = false;
        if (listMode === "attendances" && selectedStoreId === requestedStoreId) {
          renderProspectListPanel({ focusSelector: "#prospectionRecords" });
        }
      }
    }
  }

  function applyAttendanceFilters(form) {
    const data = new FormData(form);
    const state = ensureAttendanceListState();
    const startDate = String(data.get("startDate") || "");
    const endDate = String(data.get("endDate") || "");
    if (!startDate || !endDate) {
      bridge.notify("Informe a data inicial e a data final.", "error");
      return;
    }
    if (startDate > endDate) {
      bridge.notify("A data inicial não pode ser posterior à data final.", "error");
      return;
    }
    state.search = String(data.get("search") || "").trim();
    state.tag = ATTENDANCE_TYPES[String(data.get("tag") || "budget")] ? String(data.get("tag")) : "budget";
    state.startDate = startDate;
    state.endDate = endDate;
    state.loaded = false;
    state.error = "";
    if (state.loading) {
      attendanceListRequest += 1;
      state.loading = false;
    }
    loadAttendanceOpportunities();
  }

  function setListMode(nextMode) {
    const safeMode = nextMode === "attendances" ? "attendances" : "records";
    if (listMode === safeMode) return;
    listMode = safeMode;
    filtersOpen = false;
    attendanceListRequest += 1;
    if (attendanceListState) attendanceListState.loading = false;
    renderProspectListPanel({
      focusSelector: `[data-prospection-action="set-list-mode"][data-list-mode="${safeMode}"]`,
      scrollTop: 0,
    });
    const state = ensureAttendanceListState();
    if (safeMode === "attendances" && !state.loaded) loadAttendanceOpportunities();
  }

  function prefillProspectFromAttendance(attendanceId) {
    const state = ensureAttendanceListState();
    const attendance = state.rows.find((row) => row.id === attendanceId);
    if (!attendance || attendance.storeId !== selectedStoreId) {
      bridge.notify("Este atendimento não está mais disponível na lista.", "error");
      return;
    }
    const resolution = prospectResolutionForAttendance(attendance);
    if (resolution.ambiguous) {
      reviewDuplicateProspects(attendanceId);
      return;
    }
    if (resolution.prospect) {
      editingId = resolution.prospect.id;
      prospectPrefill = null;
    } else {
      const activeProfessional = professionalsFor(selectedStoreId).find((row) => row.id === attendance.professionalId);
      const context = [
        `Atendimento de ${formatDateTime(attendance.attendedAt)} por ${attendance.professionalName}.`,
        attendance.description,
        attendance.serviceOrder ? `OS: ${attendance.serviceOrder}.` : "",
      ].filter(Boolean).join(" ").slice(0, 2000);
      editingId = "";
      prospectPrefill = {
        name: attendance.customerName,
        phone: attendance.phone,
        cpf: "",
        notes: context,
        probability: "blue",
        professionalId: activeProfessional?.id || "",
        tagValues: [],
      };
    }
    render();
    requestAnimationFrame(() => {
      const form = root.querySelector("#prospectForm");
      form?.scrollIntoView({ behavior: "smooth", block: "start" });
      form?.querySelector('[name="name"]')?.focus({ preventScroll: true });
    });
    bridge.notify(resolution.prospect ? "A prospecção existente foi aberta." : "Atendimento carregado no cadastro. Revise e registre a prospecção.");
  }

  function reviewDuplicateProspects(attendanceId) {
    const state = ensureAttendanceListState();
    const attendance = state.rows.find((row) => row.id === attendanceId);
    if (!attendance || attendance.storeId !== selectedStoreId) {
      bridge.notify("Este atendimento não está mais disponível na lista.", "error");
      return;
    }
    listSearch = attendance.phone || attendance.phoneNormalized;
    listStatus = "all";
    dashboardPeriod = "all";
    listMode = "records";
    filtersOpen = false;
    attendanceListRequest += 1;
    state.loading = false;
    renderProspectListPanel({ focusSelector: "[data-prospection-search]", scrollTop: 0 });
    bridge.notify("Encontramos mais de uma prospecção com este telefone. Revise os registros antes de continuar.");
  }

  function forceCloseDialogs({ preserveConfiguration = false } = {}) {
    root.querySelectorAll(".prospection-dialog-backdrop").forEach((dialog) => dialog.remove());
    root.querySelectorAll(".prospection-unsaved-backdrop").forEach((dialog) => dialog.remove());
    document.body.classList.remove("is-modal-open");
    pendingPurchaseId = "";
    importDraft = null;
    pendingConfigurationTransition = null;
    if (!preserveConfiguration) configurationSession = null;
  }

  function closeDialogs() {
    forceCloseDialogs();
  }

  function openDialog(markup) {
    forceCloseDialogs();
    root.insertAdjacentHTML("beforeend", markup);
    document.body.classList.add("is-modal-open");
    requestAnimationFrame(() => root.querySelector(".prospection-dialog-close")?.focus());
  }

  function dialogShell({ eyebrow, title, body, wide = false }) {
    return `<div class="prospection-dialog-backdrop"><section class="prospection-dialog${wide ? " is-wide" : ""}" role="dialog" aria-modal="true"><header class="prospection-dialog-header"><div><p class="eyebrow">${escapeHtml(eyebrow)}</p><h2>${escapeHtml(title)}</h2></div><button class="prospection-dialog-close" type="button" data-prospection-action="close-dialog" aria-label="Fechar"><i class="fa-solid fa-xmark"></i></button></header><div class="prospection-dialog-body">${body}</div></section></div>`;
  }

  function openPurchaseDialog(prospectId) {
    const row = prospects.find((item) => item.id === prospectId);
    if (!row) return;
    openDialog(dialogShell({
      eyebrow: "Resultado comercial",
      title: `Registrar compra de ${row.name}`,
      body: `<form id="prospectionPurchaseForm" class="prospection-config-list"><div class="prospection-purchase-grid"><label class="prospection-field">Valor da compra<input name="purchaseAmount" type="text" inputmode="decimal" placeholder="R$ 0,00" required /></label><label class="prospection-field">Número da OS<input name="purchaseOrder" type="text" maxlength="80" placeholder="OS 1234" required /></label></div><p class="prospection-form-message" data-dialog-message></p><button class="prospection-button" type="submit"><i class="fa-solid fa-check"></i>Confirmar compra</button></form>`,
    }));
    pendingPurchaseId = row.id;
  }

  function openConfirmDialog({ title, message, action, id, idName = "prospect", cancelStoreId = "" }) {
    openDialog(dialogShell({
      eyebrow: "Confirmação",
      title,
      body: `<p class="prospection-record-notes">${escapeHtml(message)}</p><div class="prospection-account-actions"><button class="prospection-button is-secondary" type="button" data-prospection-action="${cancelStoreId ? "open-configuration" : "close-dialog"}"${cancelStoreId ? ` data-store-id="${escapeHtml(cancelStoreId)}"` : ""}>Cancelar</button><button class="prospection-button is-danger" type="button" data-prospection-action="${action}" data-${escapeHtml(idName)}-id="${escapeHtml(id)}">Confirmar</button></div>`,
    }));
  }

  function professionalRanking(storeIds, rows = prospectsFor(storeIds)) {
    const byProfessional = new Map();
    rows.forEach((row) => {
      const key = row.professionalId || `name:${normalize(row.professionalName || "Sem profissional")}`;
      if (!byProfessional.has(key)) byProfessional.set(key, { name: row.professionalName || "Sem profissional", total: 0, returned: 0, purchased: 0, bonus: 0 });
      const item = byProfessional.get(key);
      item.total += 1;
      if (row.returnedAt) item.returned += 1;
      if (row.purchasedAt) item.purchased += 1;
      if (isBonusEligible(row)) item.bonus += settingsFor(row.storeId).bonusAmount;
    });
    return [...byProfessional.values()].sort((a, b) => b.purchased - a.purchased || b.returned - a.returned || b.total - a.total);
  }

  function calendarMarkup(storeId) {
    const year = calendarDate.getFullYear();
    const month = calendarDate.getMonth();
    const firstDay = new Date(year, month, 1);
    const offset = (firstDay.getDay() + 6) % 7;
    const days = new Date(year, month + 1, 0).getDate();
    const goal = settingsFor(storeId).dailyGoal;
    const storeRows = prospects.filter((row) => row.storeId === storeId);
    const weekdays = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"];
    const cells = weekdays.map((weekday) => `<div class="weekday-cell">${weekday}</div>`);
    cells.push(...Array.from({ length: offset }, () => `<div class="calendar-empty"></div>`));
    for (let day = 1; day <= days; day += 1) {
      const start = new Date(year, month, day);
      const end = addDays(start, 1);
      const count = storeRows.filter((row) => isInWindow(row.createdAt, { start, end })).length;
      const returnedCount = storeRows.filter((row) => isInWindow(row.returnedAt, { start, end })).length;
      const purchasedCount = storeRows.filter((row) => isInWindow(row.purchasedAt, { start, end })).length;
      const ratio = Math.min(count / Math.max(1, goal), 1);
      const darkMode = document.body.classList.contains("is-dark");
      const hue = Math.round((darkMode ? 0 : 4) + ratio * (darkMode ? 142 : 126));
      const lightness = Math.round((darkMode ? 22 : 88) + ratio * (darkMode ? 16 : -38));
      const background = `hsl(${hue} 76% ${lightness}%)`;
      const color = darkMode || ratio > 0.58 ? "#ffffff" : "#0f172a";
      const today = new Date();
      const isToday = start.getFullYear() === today.getFullYear() && start.getMonth() === today.getMonth() && start.getDate() === today.getDate();
      cells.push(`<div class="calendar-day${isToday ? " is-today" : ""}${count > goal ? " is-over-goal" : ""}" style="background:${background};color:${color}" title="${count} prospecções feitas, ${returnedCount} viram a loja, ${purchasedCount} compraram"><span class="calendar-day-number">${day}</span><strong class="calendar-day-count">${count}</strong></div>`);
    }
    const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric" }).format(firstDay);
    return `<section class="calendar-panel" aria-labelledby="prospection-calendar-title"><div class="calendar-header"><div><h3 id="prospection-calendar-title">Calendário de meta</h3><p>Vermelho está longe da meta, verde está perto. Ao passar a meta, o dia brilha.</p></div><div class="calendar-controls"><button class="prospection-button is-quiet" type="button" data-prospection-action="calendar-prev" aria-label="Mês anterior"><i class="fa-solid fa-chevron-left"></i></button><strong>${escapeHtml(monthLabel)}</strong><button class="prospection-button is-quiet" type="button" data-prospection-action="calendar-next" aria-label="Próximo mês"><i class="fa-solid fa-chevron-right"></i></button></div></div><div class="calendar-grid" role="grid" aria-label="Metas diárias de ${escapeHtml(monthLabel)}">${cells.join("")}</div></section>`;
  }

  function insightScopeStoreId(requestedStoreId = "") {
    if (bridge.profile.role === "store") return bridge.profile.storeId;
    const candidates = [requestedStoreId, selectedStoreId, analysisStoreId, bonusStoreId].filter(Boolean);
    const allowed = new Set(licensedScopedStores().map((store) => store.id));
    return candidates.find((storeId) => allowed.has(storeId)) || licensedScopedStores()[0]?.id || "";
  }

  function insightStoreIds(requestedStoreId = "") {
    const storeId = insightScopeStoreId(requestedStoreId);
    return storeId ? [storeId] : [];
  }

  function professionalFilterOptions(storeIds, selectedValue = "all") {
    const allowed = new Set(storeIds);
    const values = new Map();
    professionals.filter((row) => allowed.has(row.storeId)).forEach((row) => values.set(row.id, row.name));
    prospects.filter((row) => allowed.has(row.storeId) && row.professionalName).forEach((row) => {
      values.set(row.professionalId || `name:${normalize(row.professionalName)}`, row.professionalName);
    });
    return `<option value="all"${selectedValue === "all" ? " selected" : ""}>Todos os responsáveis</option>${[...values.entries()].sort((a, b) => a[1].localeCompare(b[1], "pt-BR")).map(([id, name]) => `<option value="${escapeHtml(id)}"${selectedValue === id ? " selected" : ""}>${escapeHtml(name)}</option>`).join("")}`;
  }

  function matchesProfessionalFilter(row, selectedValue) {
    if (!selectedValue || selectedValue === "all") return true;
    if (selectedValue.startsWith("name:")) return `name:${normalize(row.professionalName)}` === selectedValue;
    return row.professionalId === selectedValue;
  }

  function insightStoreOptions(selectedValue = "") {
    const allowedStores = licensedScopedStores();
    if (bridge.profile.role === "store") return `<option value="${escapeHtml(bridge.profile.storeId)}">${escapeHtml(storeById(bridge.profile.storeId)?.name || "Minha empresa")}</option>`;
    return allowedStores.map((store) => `<option value="${escapeHtml(store.id)}"${selectedValue === store.id ? " selected" : ""}>${escapeHtml(store.name)}</option>`).join("");
  }

  function insightIdentityMarkup(store, helper) {
    if (!store) return "";
    const config = settingsFor(store.id);
    return `<section class="prospection-insight-identity" style="--account-color:${escapeHtml(config.accentColor)}">
      <div class="prospection-account-identity">${accountVisual(store.avatarUrl || "", store.name, "fa-store", config.logoBackgroundColor)}<div><small>Dados isolados deste cliente</small><strong>${escapeHtml(store.name)}</strong><span>${escapeHtml(helper)}</span></div></div>
      <span class="prospection-scope-lock"><i class="fa-solid fa-lock"></i>Sem mistura de contas</span>
    </section>`;
  }

  function shortcutRange(shortcut) {
    const today = startOfDay(new Date());
    if (shortcut === "this-week") return { start: startOfWeek(today), end: today };
    if (shortcut === "last-week") {
      const currentStart = startOfWeek(today);
      return { start: addDays(currentStart, -7), end: addDays(currentStart, -1) };
    }
    return { start: startOfMonth(today), end: today };
  }

  function shortcutIsActive(shortcut, startValue, endValue) {
    const range = shortcutRange(shortcut);
    return startValue === formatDateInput(range.start) && endValue === formatDateInput(range.end);
  }

  function dateShortcutsMarkup(target, startValue, endValue) {
    const definitions = [["this-week", "Esta semana"], ["last-week", "Semana passada"], ["this-month", "Este mês"]];
    return `<div class="prospection-date-shortcuts" aria-label="Atalhos de período">${definitions.map(([value, label]) => `<button class="prospection-button is-quiet${shortcutIsActive(value, startValue, endValue) ? " is-active" : ""}" type="button" data-prospection-action="apply-date-shortcut" data-shortcut-target="${target}" data-shortcut-value="${value}">${label}</button>`).join("")}</div>`;
  }

  function insightKpisMarkup(rows, { bonusRows = rows, purchaseRows = rows } = {}) {
    const metrics = metricsFor(rows);
    const purchasedRows = purchaseRows.filter((row) => row.purchasedAt);
    const revenue = purchasedRows.reduce((sum, row) => sum + row.purchaseAmount, 0);
    const ticket = purchasedRows.length ? revenue / purchasedRows.length : 0;
    const eligible = bonusRows.filter(isBonusEligible);
    const totalBonus = bonusFor(eligible);
    const definitions = [
      ["fa-phone", "Prospecções", rows.length, "Registros no período"],
      ["fa-store", "Retornaram", metrics.returned, `${metrics.returnRate}% de retorno`],
      ["fa-bag-shopping", "Compraram", purchasedRows.length, `${percentage(purchasedRows.length, rows.length)}% sobre as prospecções`],
      ["fa-sack-dollar", "Faturamento", formatCurrency(revenue), `${formatCurrency(ticket)} de ticket médio`],
      ["fa-gift", "Bonificação", formatCurrency(totalBonus), `${eligible.length} compras válidas`],
    ];
    return `<section class="prospection-insight-kpis">${definitions.map(([icon, label, value, helper]) => `<article><i class="fa-solid ${icon}"></i><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong><small>${escapeHtml(helper)}</small></article>`).join("")}</section>`;
  }

  function funnelMarkup(rows) {
    const total = rows.length;
    const returned = rows.filter((row) => row.returnedAt).length;
    const purchased = rows.filter((row) => row.purchasedAt).length;
    const stages = [["Prospecções", total, 100, "#2f80ed"], ["Retornaram", returned, percentage(returned, total), "#d48616"], ["Compraram", purchased, percentage(purchased, total), "#16855f"]];
    return `<div class="prospection-funnel">${stages.map(([label, value, percent, color]) => `<div><span><strong>${escapeHtml(label)}</strong><em>${value} · ${percent}%</em></span><i><b style="--funnel-width:${Math.max(value ? 5 : 0, percent)}%;--funnel-color:${color}"></b></i></div>`).join("")}</div>`;
  }

  function rangeTrendMarkup(rows, startValue, endValue) {
    const range = dateRange(startValue, endValue);
    const start = range.start || addDays(startOfDay(new Date()), -13);
    const end = range.end || addDays(startOfDay(new Date()), 1);
    const durationDays = Math.max(1, Math.ceil((end - start) / 86400000));
    const bucketCount = Math.min(14, durationDays);
    const bucketSize = Math.max(1, Math.ceil(durationDays / bucketCount));
    const buckets = Array.from({ length: bucketCount }, (_, index) => {
      const bucketStart = addDays(start, index * bucketSize);
      const bucketEnd = new Date(Math.min(end.getTime(), addDays(bucketStart, bucketSize).getTime()));
      return {
        label: new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit" }).format(bucketStart),
        value: rows.filter((row) => isInWindow(row.createdAt, { start: bucketStart, end: bucketEnd })).length,
      };
    }).filter((bucket, index) => index === 0 || addDays(start, index * bucketSize) < end);
    const max = Math.max(1, ...buckets.map((bucket) => bucket.value));
    return `<div class="prospection-mini-chart" style="--chart-columns:${buckets.length}">${buckets.map((bucket) => `<div class="prospection-chart-column" title="${bucket.value} prospecções"><div class="prospection-chart-bar-wrap"><i class="prospection-chart-bar" style="--height:${Math.max(bucket.value ? 5 : 2, (bucket.value / max) * 100)}%"></i></div><span>${escapeHtml(bucket.label)}</span></div>`).join("")}</div>`;
  }

  function professionalPerformanceRows(rows) {
    const grouped = new Map();
    rows.forEach((row) => {
      const key = row.professionalId || `name:${normalize(row.professionalName || "Sem responsável")}`;
      if (!grouped.has(key)) grouped.set(key, { id: key, name: row.professionalName || "Sem responsável", total: 0, returned: 0, purchased: 0, revenue: 0, bonus: 0 });
      const item = grouped.get(key);
      item.total += 1;
      if (row.returnedAt) item.returned += 1;
      if (row.purchasedAt) { item.purchased += 1; item.revenue += row.purchaseAmount; }
      if (isBonusEligible(row)) item.bonus += settingsFor(row.storeId).bonusAmount;
    });
    return [...grouped.values()].sort((a, b) => b.purchased - a.purchased || b.revenue - a.revenue || b.returned - a.returned);
  }

  function professionalPerformanceMarkup(rows, { interactive = false } = {}) {
    const performance = professionalPerformanceRows(rows);
    if (!performance.length) return emptyMarkup("Nenhum responsável no período", "Registre o responsável nas prospecções para liberar o comparativo individual.");
    return `<div class="prospection-performance-table${interactive ? " is-interactive" : ""}" role="table"><div class="prospection-performance-head" role="row"><span>Responsável</span><span>Feitas</span><span>Retornaram</span><span>Compraram</span><span>Faturamento</span><span>Bônus</span>${interactive ? "<span>Registros</span>" : ""}</div>${performance.map((row, index) => `<div class="prospection-performance-row" role="row"><span><b>${index + 1}</b><strong>${escapeHtml(row.name)}</strong></span><span>${row.total}</span><span>${row.returned}<small>${percentage(row.returned, row.total)}%</small></span><span>${row.purchased}<small>${percentage(row.purchased, row.total)}%</small></span><span>${formatCurrency(row.revenue)}</span><span class="is-bonus">${formatCurrency(row.bonus)}</span>${interactive ? `<span><button class="prospection-button is-quiet" type="button" data-prospection-action="show-professional-records" data-professional-id="${escapeHtml(row.id)}">Ver lista</button></span>` : ""}</div>`).join("")}</div>`;
  }

  function professionalMatchesKey(row, professionalKey) {
    const rowKey = row.professionalId || `name:${normalize(row.professionalName || "Sem responsável")}`;
    return rowKey === professionalKey;
  }

  function professionalProspectDetailsMarkup(rows, professionalKey) {
    if (!professionalKey) return "";
    const selectedRows = rows.filter((row) => professionalMatchesKey(row, professionalKey)).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
    const name = selectedRows[0]?.professionalName || "Sem responsável";
    return `<article id="prospectionProfessionalRecords" class="prospection-panel prospection-professional-records"><div class="prospection-panel-heading"><div><p class="eyebrow">Registros individuais</p><h3>${escapeHtml(name)}</h3><span>${selectedRows.length} prospecções no período selecionado.</span></div><button class="prospection-button is-quiet" type="button" data-prospection-action="hide-professional-records"><i class="fa-solid fa-xmark"></i>Fechar lista</button></div>
      ${selectedRows.length ? `<div class="prospection-employee-prospect-list">${selectedRows.map((row) => `<article><div><strong>${escapeHtml(row.name)}</strong><span>${escapeHtml(row.phone || "Sem telefone")} · registrada em ${formatDateTime(row.createdAt)}</span><small>${row.returnedAt ? `Retornou em ${formatDate(row.returnedAt)}` : "Ainda não retornou"}</small></div><div><span>${row.purchasedAt ? "Compra confirmada" : "Sem compra"}</span><strong>${row.purchasedAt ? formatCurrency(row.purchaseAmount) : "—"}</strong><small>${row.purchaseOrder ? `OS ${escapeHtml(row.purchaseOrder)}` : escapeHtml(PROBABILITIES[row.probability]?.label || "")}</small></div></article>`).join("")}</div>` : emptyMarkup("Nenhuma prospecção encontrada", "Ajuste o período para consultar outros registros deste responsável.")}
    </article>`;
  }

  function storePerformanceMarkup(rows, storeIds) {
    const entries = storeIds.map((storeId) => {
      const store = storeById(storeId) || { name: "Cliente" };
      const storeRows = rows.filter((row) => row.storeId === storeId);
      const metrics = metricsFor(storeRows);
      return { store, metrics, revenue: storeRows.reduce((sum, row) => sum + (row.purchasedAt ? row.purchaseAmount : 0), 0) };
    }).sort((a, b) => b.metrics.purchased - a.metrics.purchased || b.revenue - a.revenue);
    if (entries.length <= 1) return "";
    return `<article class="prospection-panel prospection-store-comparison"><div class="prospection-panel-heading"><div><p class="eyebrow">Clientes</p><h3>Desempenho da carteira</h3><span>Comparação por cliente no mesmo período.</span></div></div><div class="prospection-ranking">${entries.map((entry, index) => `<div class="prospection-ranking-row"><span class="prospection-ranking-position">${index + 1}</span><div class="prospection-ranking-name"><strong>${escapeHtml(entry.store.name)}</strong><span>${entry.metrics.total} feitas · ${entry.metrics.returned} retornaram</span></div><div class="prospection-ranking-value"><strong>${entry.metrics.conversion}%</strong><span>${formatCurrency(entry.revenue)}</span></div></div>`).join("")}</div></article>`;
  }

  function analysisPeriodWindow(period = analysisPeriod) {
    if (period === "custom") {
      const range = dateRange(analysisStartDate, analysisEndDate);
      return { ...range, label: "período personalizado" };
    }
    const mappedPeriod = { daily: "today", weekly: "week", monthly: "month", yearly: "year" }[period] || "month";
    const window = periodWindow(mappedPeriod);
    return { ...window, label: { daily: "dia", weekly: "semana", monthly: "mês", yearly: "ano" }[period] || "mês" };
  }

  function analysisRowsForPeriod(storeId, period = analysisPeriod, applyProfessional = true) {
    const window = analysisPeriodWindow(period);
    return prospects.filter((row) => row.storeId === storeId && isInWindow(row.createdAt, window) && (!applyProfessional || matchesProfessionalFilter(row, analysisProfessionalId)));
  }

  function analysisOverviewMarkup(storeId) {
    const definitions = [["daily", "Hoje"], ["weekly", "Semana"], ["monthly", "Mês"], ["yearly", "Ano"]];
    return `<section class="admin-store-metrics" aria-label="Resumo da loja">${definitions.map(([period, label]) => {
      const window = analysisPeriodWindow(period);
      const rows = analysisRowsForPeriod(storeId, period, false);
      const storeRows = prospects.filter((row) => row.storeId === storeId);
      const returned = storeRows.filter((row) => isInWindow(row.returnedAt, window)).length;
      const purchased = storeRows.filter((row) => isInWindow(row.purchasedAt, window)).length;
      return `<div><strong>${rows.length}</strong><span>${label}</span><em>${returned} viram a loja</em><em class="admin-purchase-count">${purchased} compraram</em></div>`;
    }).join("")}</section>`;
  }

  function analysisPeriodControlsMarkup() {
    const definitions = [["daily", "Dia"], ["weekly", "Semana"], ["monthly", "Mês"], ["yearly", "Ano"]];
    return `<div class="admin-period-controls" aria-label="Período rápido">${definitions.map(([period, label]) => `<button class="admin-period-button${analysisPeriod === period ? " is-active" : ""}" type="button" data-prospection-action="set-analysis-period" data-analysis-period="${period}">${label}</button>`).join("")}</div>`;
  }

  function analysisComparisonMarkup(storeId, rows) {
    const window = analysisPeriodWindow();
    const storeRows = prospects.filter((row) => row.storeId === storeId && matchesProfessionalFilter(row, analysisProfessionalId));
    const returned = storeRows.filter((row) => isInWindow(row.returnedAt, window)).length;
    const purchased = storeRows.filter((row) => isInWindow(row.purchasedAt, window)).length;
    const label = window.label;
    return `<section class="admin-comparison"><div><strong>${rows.length}</strong><span>Prospecções neste ${label}</span></div><div><strong>${returned}</strong><span>Viram a loja neste ${label}</span></div><div><strong>${purchased}</strong><span>Compraram neste ${label}</span></div><div><strong>${percentage(purchased, rows.length)}%</strong><span>Compra sobre prospecções</span></div></section>`;
  }

  function analysisProfessionalPanelMarkup(storeId, rows) {
    const grouped = new Map();
    professionalsFor(storeId, true).forEach((professional) => grouped.set(professional.id, { id: professional.id, name: professional.name, total: 0, returned: 0, purchased: 0, tags: new Map(), active: professional.active }));
    rows.forEach((row) => {
      const key = row.professionalId || `name:${normalize(row.professionalName || "Sem responsável")}`;
      if (!grouped.has(key)) grouped.set(key, { id: key, name: row.professionalName || "Sem responsável", total: 0, returned: 0, purchased: 0, tags: new Map(), active: true });
      const item = grouped.get(key);
      item.total += 1;
      if (row.returnedAt) item.returned += 1;
      if (row.purchasedAt) item.purchased += 1;
      (row.tagValues?.length ? row.tagValues : ["Sem campanha"]).forEach((tag) => item.tags.set(tag, (item.tags.get(tag) || 0) + 1));
    });
    const items = [...grouped.values()].filter((item) => item.active || item.total).sort((a, b) => b.total - a.total || b.returned - a.returned || a.name.localeCompare(b.name, "pt-BR"));
    return `<section class="admin-professional-performance"><div class="admin-professional-performance-header"><h4>Profissionais</h4><span>Feitas, vieram, compraram e taxas</span></div><div class="admin-professional-list">${items.length ? items.map((item) => {
      const tagPreview = [...item.tags.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([tag, count]) => `${escapeHtml(tag)} ${count}`).join(" / ") || "Sem campanha no período";
      return `<div class="admin-professional-row"><div class="admin-professional-name"><strong>${escapeHtml(item.name)}</strong><small>${tagPreview}</small></div><div class="admin-professional-metrics"><span><b>${item.total}</b><small>feitas</small></span><span><b>${item.returned}</b><small>vieram</small></span><span><b>${item.purchased}</b><small>compraram</small></span></div><div class="admin-professional-actions"><div class="admin-professional-rates"><span>${percentage(item.returned, item.total)}% visita</span><span>${percentage(item.purchased, item.total)}% compra</span></div><button class="admin-professional-list-button" type="button" data-prospection-action="show-professional-records" data-professional-id="${escapeHtml(item.id)}">Listar</button></div></div>`;
    }).join("") : `<p class="admin-professional-empty">Nenhum profissional cadastrado nesta loja.</p>`}</div></section>`;
  }

  function analysisCampaignPanelMarkup(storeId, rows) {
    const grouped = new Map();
    tagsFor(storeId).forEach((tag) => grouped.set(normalize(tag.label), { label: tag.label, total: 0, returned: 0, purchased: 0 }));
    rows.forEach((row) => (row.tagValues?.length ? row.tagValues : ["Sem campanha"]).forEach((label) => {
      const key = normalize(label);
      if (!grouped.has(key)) grouped.set(key, { label, total: 0, returned: 0, purchased: 0 });
      const item = grouped.get(key);
      item.total += 1;
      if (row.returnedAt) item.returned += 1;
      if (row.purchasedAt) item.purchased += 1;
    }));
    const items = [...grouped.values()].sort((a, b) => b.total - a.total || b.returned - a.returned || a.label.localeCompare(b.label, "pt-BR"));
    return `<section class="admin-campaign-performance"><div class="admin-campaign-performance-header"><h4>Campanhas</h4><span>Feitas, vieram e compraram por etiqueta</span></div><div class="admin-campaign-performance-list">${items.length ? items.map((item) => `<div class="admin-campaign-performance-row"><strong>${escapeHtml(item.label)}</strong><span><b>${item.total}</b><small>feitas</small></span><span><b>${item.returned}</b><small>vieram</small></span><span><b>${item.purchased}</b><small>compraram</small></span><em>${percentage(item.purchased, item.total)}%</em></div>`).join("") : `<p class="admin-professional-empty">Nenhuma campanha neste período.</p>`}</div></section>`;
  }

  function analysisTrendBuckets(period = analysisPeriod) {
    const now = new Date();
    let starts = [];
    if (period === "daily") {
      const start = startOfDay(now);
      starts = Array.from({ length: 24 }, (_, index) => new Date(start.getTime() + index * 3600000));
    } else if (period === "weekly") {
      const start = startOfWeek(now);
      starts = Array.from({ length: 7 }, (_, index) => addDays(start, index));
    } else if (period === "yearly") {
      const start = new Date(now.getFullYear(), 0, 1);
      starts = Array.from({ length: 12 }, (_, index) => addMonths(start, index));
    } else if (period === "custom") {
      const window = analysisPeriodWindow("custom");
      const total = Math.max(1, Math.min(62, Math.ceil((window.end - window.start) / 86400000)));
      starts = Array.from({ length: total }, (_, index) => addDays(window.start, index));
    } else {
      const start = startOfMonth(now);
      const total = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
      starts = Array.from({ length: total }, (_, index) => addDays(start, index));
    }
    return starts.map((start, index) => {
      const end = period === "daily" ? new Date(start.getTime() + 3600000) : period === "yearly" ? addMonths(start, 1) : addDays(start, 1);
      const label = period === "daily" ? `${String(index).padStart(2, "0")}h` : period === "yearly" ? new Intl.DateTimeFormat("pt-BR", { month: "short" }).format(start).replace(".", "") : String(start.getDate());
      return { start, end, label, weekend: start.getDay() === 0 || start.getDay() === 6 };
    });
  }

  function analysisTrendMarkup(storeId) {
    const storeRows = prospects.filter((row) => row.storeId === storeId && matchesProfessionalFilter(row, analysisProfessionalId));
    const buckets = analysisTrendBuckets();
    const series = [
      { key: "createdAt", label: "Prospecções", color: "#2f80ed" },
      { key: "returnedAt", label: "Viram a loja", color: "#2fc49a" },
      { key: "purchasedAt", label: "Compraram", color: "#d48616" },
    ].map((item) => ({ ...item, values: buckets.map((bucket) => storeRows.filter((row) => isInWindow(row[item.key], bucket)).length) }));
    const goal = ["weekly", "monthly"].includes(analysisPeriod) ? settingsFor(storeId).dailyGoal : 0;
    const maxValue = Math.max(1, goal, ...series.flatMap((item) => item.values));
    const width = 1080;
    const height = 320;
    const padding = { top: 34, right: 34, bottom: 54, left: 48 };
    const plotWidth = width - padding.left - padding.right;
    const plotHeight = height - padding.top - padding.bottom;
    const x = (index) => padding.left + (buckets.length > 1 ? (plotWidth * index) / (buckets.length - 1) : plotWidth / 2);
    const y = (value) => padding.top + plotHeight - (value / maxValue) * plotHeight;
    const horizontal = Array.from({ length: 5 }, (_, index) => {
      const value = Math.round((maxValue * index) / 4);
      const yValue = y(value);
      return `<g class="admin-line-grid"><line x1="${padding.left}" y1="${yValue}" x2="${width - padding.right}" y2="${yValue}"></line><text x="8" y="${yValue + 4}">${value}</text></g>`;
    }).join("");
    const labelEvery = buckets.length > 35 ? 4 : buckets.length > 20 ? 2 : 1;
    const vertical = buckets.map((bucket, index) => `<line class="admin-line-vertical${index % labelEvery === 0 ? " is-major" : ""}" x1="${x(index)}" y1="${padding.top}" x2="${x(index)}" y2="${padding.top + plotHeight}"></line>`).join("");
    const goalLine = goal ? `<g class="admin-goal-line"><line x1="${padding.left}" y1="${y(goal)}" x2="${width - padding.right}" y2="${y(goal)}"></line><text x="${width - padding.right - 5}" y="${y(goal) - 7}">Meta ${goal}/dia</text></g>` : "";
    const paths = series.map((item) => {
      const points = item.values.map((value, index) => `${x(index)},${y(value)}`).join(" ");
      const dots = item.values.map((value, index) => `<circle cx="${x(index)}" cy="${y(value)}" r="${value ? 3.6 : 1.5}"><title>${item.label}: ${value} em ${buckets[index].label}</title></circle>${value ? `<text class="admin-line-value" x="${x(index)}" y="${Math.max(14, y(value) - 9)}">${value}</text>` : ""}`).join("");
      return `<g class="admin-line-series" style="--series-color:${item.color}"><polyline points="${points}"></polyline>${dots}</g>`;
    }).join("");
    const labels = buckets.map((bucket, index) => index % labelEvery || (index !== 0 && index !== buckets.length - 1 && buckets.length > 35 && index % labelEvery) ? "" : `<text class="admin-line-label${bucket.weekend ? " is-weekend" : ""}" x="${x(index)}" y="${height - 18}">${escapeHtml(bucket.label)}</text>`).join("");
    const legend = series.map((item) => `<span style="--series-color:${item.color}"><i></i><b>${item.label}</b><small>Total ${item.values.reduce((sum, value) => sum + value, 0)} · pico ${Math.max(0, ...item.values)}</small></span>`).join("");
    return `<section class="admin-trend-chart is-${analysisPeriod}"><div class="admin-trend-heading"><div class="admin-trend-title"><strong>Fluxo do período</strong><span>${buckets.length} blocos · evolução de prospecções, visitas e compras</span></div><div class="admin-trend-legend">${legend}</div></div><svg class="admin-line-chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="Gráfico de desempenho no período">${vertical}${horizontal}${goalLine}${paths}<g>${labels}</g></svg></section>`;
  }

  function analysisRows(storeIds) {
    const allowed = new Set(storeIds);
    return prospects.filter((row) => allowed.has(row.storeId) && isInOptionalRange(row.createdAt, analysisStartDate, analysisEndDate) && matchesProfessionalFilter(row, analysisProfessionalId));
  }

  function openAnalysis(requestedStoreId) {
    initializeInsightDates();
    const previousStoreId = analysisStoreId;
    analysisStoreId = insightScopeStoreId(bridge.profile.role === "store" ? bridge.profile.storeId : requestedStoreId || selectedStoreId || analysisStoreId);
    if (!analysisStoreId) {
      bridge.notify("Libere Prospecções para um cliente antes de abrir a análise.", "error");
      return;
    }
    if (previousStoreId && previousStoreId !== analysisStoreId) {
      analysisProfessionalId = "all";
      analysisDetailProfessionalId = "";
      analysisPeriod = "monthly";
      calendarDate = new Date();
    }
    const storeIds = insightStoreIds(analysisStoreId);
    const rows = analysisPeriod === "custom" ? analysisRows(storeIds) : analysisRowsForPeriod(analysisStoreId);
    const selectedStore = storeById(analysisStoreId);
    const title = selectedStore?.name || bridge.profile.storeName || "Minha empresa";
    const rangeLabel = analysisPeriod === "custom"
      ? `${formatInputDateDisplay(analysisStartDate)} a ${formatInputDateDisplay(analysisEndDate)}`
      : `Visão de ${analysisPeriodWindow().label}`;
    openDialog(dialogShell({
      eyebrow: "Inteligência de prospecção",
      title,
      wide: true,
      body: `<div class="prospection-prospec-analysis" style="--store-accent:${escapeHtml(settingsFor(analysisStoreId).accentColor)}">
      ${insightIdentityMarkup(selectedStore, `${rangeLabel} · ${rows.length} registros · meta ${settingsFor(analysisStoreId).dailyGoal}/dia`)}
      ${analysisOverviewMarkup(analysisStoreId)}
      ${analysisPeriodControlsMarkup()}
      ${analysisComparisonMarkup(analysisStoreId, rows)}
      <div class="admin-analysis-grid"><div class="admin-professional-performance-slot">${analysisProfessionalPanelMarkup(analysisStoreId, rows)}</div><div class="admin-campaign-performance-slot">${analysisCampaignPanelMarkup(analysisStoreId, rows)}</div><div class="admin-store-chart">${analysisTrendMarkup(analysisStoreId)}</div></div>
      ${calendarMarkup(analysisStoreId)}
      <article class="prospection-panel prospection-custom-query"><div class="prospection-panel-heading"><div><p class="eyebrow">Consulta personalizada</p><h3>Buscar por data e responsável</h3><span>Use uma faixa exata quando precisar conferir um intervalo específico.</span></div></div>
        ${dateShortcutsMarkup("analysis", analysisStartDate, analysisEndDate)}
        <form id="prospectionAnalysisFilters" class="prospection-insight-filters">
          <label>Cliente<select name="storeId">${insightStoreOptions(analysisStoreId)}</select></label>
          <label>Data inicial<input name="startDate" type="date" value="${escapeHtml(analysisStartDate)}" /></label>
          <label>Data final<input name="endDate" type="date" value="${escapeHtml(analysisEndDate)}" /></label>
          <label>Responsável<select name="professionalId">${professionalFilterOptions(storeIds, analysisProfessionalId)}</select></label>
          <button class="prospection-button" type="submit"><i class="fa-solid fa-filter"></i>Aplicar análise</button>
        </form>
      </article>
      ${professionalProspectDetailsMarkup(rows, analysisDetailProfessionalId)}
      </div>`,
    }));
    if (analysisDetailProfessionalId) requestAnimationFrame(() => root.querySelector("#prospectionProfessionalRecords")?.scrollIntoView({ behavior: "smooth", block: "start" }));
  }

  function bonusRows(storeIds) {
    const allowed = new Set(storeIds);
    return prospects.filter((row) => allowed.has(row.storeId) && row.purchasedAt && isInOptionalRange(row.purchasedAt, bonusStartDate, bonusEndDate) && matchesProfessionalFilter(row, bonusProfessionalId));
  }

  function bonusActivityRows(storeIds) {
    const allowed = new Set(storeIds);
    return prospects.filter((row) => allowed.has(row.storeId) && isInOptionalRange(row.createdAt, bonusStartDate, bonusEndDate) && matchesProfessionalFilter(row, bonusProfessionalId));
  }

  function bonusProfessionalPerformanceMarkup(activityRows, purchaseRows) {
    const grouped = new Map();
    const ensure = (row) => {
      const key = row.professionalId || `name:${normalize(row.professionalName || "Sem responsável")}`;
      if (!grouped.has(key)) grouped.set(key, { name: row.professionalName || "Sem responsável", total: 0, returned: 0, purchased: 0, revenue: 0, bonus: 0 });
      return grouped.get(key);
    };
    activityRows.forEach((row) => {
      const item = ensure(row);
      item.total += 1;
      if (row.returnedAt) item.returned += 1;
    });
    purchaseRows.forEach((row) => {
      const item = ensure(row);
      item.purchased += 1;
      item.revenue += row.purchaseAmount;
      if (isBonusEligible(row)) item.bonus += settingsFor(row.storeId).bonusAmount;
    });
    const entries = [...grouped.values()].sort((a, b) => b.bonus - a.bonus || b.purchased - a.purchased || b.revenue - a.revenue);
    if (!entries.length) return emptyMarkup("Nenhum responsável no período", "As atividades e compras aparecerão aqui após os primeiros registros.");
    return `<div class="prospection-performance-table" role="table"><div class="prospection-performance-head" role="row"><span>Responsável</span><span>Feitas</span><span>Retornaram</span><span>Compraram</span><span>Faturamento</span><span>Bônus</span></div>${entries.map((row, index) => `<div class="prospection-performance-row" role="row"><span><b>${index + 1}</b><strong>${escapeHtml(row.name)}</strong></span><span>${row.total}</span><span>${row.returned}<small>${percentage(row.returned, row.total)}%</small></span><span>${row.purchased}<small>${percentage(row.purchased, row.total)}%</small></span><span>${formatCurrency(row.revenue)}</span><span class="is-bonus">${formatCurrency(row.bonus)}</span></div>`).join("")}</div>`;
  }

  function bonusPurchaseListMarkup(rows) {
    if (!rows.length) return emptyMarkup("Nenhuma compra encontrada", "Ajuste o período ou registre as compras realizadas pelos clientes prospectados.");
    return `<div class="prospection-bonus-records">${rows.sort((a, b) => new Date(b.purchasedAt) - new Date(a.purchasedAt)).map((row) => {
      const eligible = isBonusEligible(row);
      const config = settingsFor(row.storeId);
      return `<article class="prospection-bonus-record${eligible ? " is-eligible" : ""}"><div><span>${escapeHtml(row.storeName)}</span><strong>${escapeHtml(row.name)}</strong><small>${escapeHtml(row.professionalName || "Sem responsável")} · ${formatDate(row.purchasedAt)}</small></div><div><span>OS</span><strong>${escapeHtml(row.purchaseOrder || "—")}</strong></div><div><span>Faturamento</span><strong>${formatCurrency(row.purchaseAmount)}</strong><small>Mínimo ${formatCurrency(config.bonusMinimum)}</small></div><div><span>Bonificação</span><strong>${eligible ? formatCurrency(config.bonusAmount) : "Não elegível"}</strong><small>${eligible ? "Compra válida" : "Abaixo do mínimo"}</small></div></article>`;
    }).join("")}</div>`;
  }

  function openBonus(requestedStoreId) {
    initializeInsightDates();
    const previousStoreId = bonusStoreId;
    bonusStoreId = insightScopeStoreId(bridge.profile.role === "store" ? bridge.profile.storeId : requestedStoreId || selectedStoreId || bonusStoreId);
    if (!bonusStoreId) {
      bridge.notify("Libere Prospecções para um cliente antes de abrir as bonificações.", "error");
      return;
    }
    if (previousStoreId && previousStoreId !== bonusStoreId) bonusProfessionalId = "all";
    const storeIds = insightStoreIds(bonusStoreId);
    const rows = bonusRows(storeIds);
    const activityRows = bonusActivityRows(storeIds);
    const eligibleRows = rows.filter(isBonusEligible);
    const titleStore = storeById(bonusStoreId);
    openDialog(dialogShell({
      eyebrow: "Remuneração variável",
      title: titleStore ? `Bonificações · ${titleStore.name}` : "Bonificações",
      wide: true,
      body: `${insightIdentityMarkup(titleStore, `${formatInputDateDisplay(bonusStartDate)} a ${formatInputDateDisplay(bonusEndDate)} · faturamento e OS desta loja`)}
      ${dateShortcutsMarkup("bonus", bonusStartDate, bonusEndDate)}
      <form id="prospectionBonusFilters" class="prospection-insight-filters prospection-bonus-filters">
        <label>Cliente<select name="storeId">${insightStoreOptions(bonusStoreId)}</select></label>
        <label>Data inicial<input name="startDate" type="date" value="${escapeHtml(bonusStartDate)}" /></label>
        <label>Data final<input name="endDate" type="date" value="${escapeHtml(bonusEndDate)}" /></label>
        <label>Responsável<select name="professionalId">${professionalFilterOptions(storeIds, bonusProfessionalId)}</select></label>
        <button class="prospection-button" type="submit"><i class="fa-solid fa-filter"></i>Aplicar período</button>
      </form>
      ${insightKpisMarkup(activityRows, { bonusRows: eligibleRows, purchaseRows: rows })}
      <article class="prospection-panel"><div class="prospection-panel-heading"><div><p class="eyebrow">Pagamento da equipe</p><h3>Bonificação por responsável</h3><span>Produção do período e compras que atingiram o mínimo configurado.</span></div></div>${bonusProfessionalPerformanceMarkup(activityRows, rows)}</article>
      <article class="prospection-panel"><div class="prospection-panel-heading"><div><p class="eyebrow">Conferência</p><h3>Clientes, faturamento e OS</h3><span>Rastreabilidade completa de cada compra do período.</span></div></div>${bonusPurchaseListMarkup(rows)}</article>`,
    }));
  }

  function configurationStoreIds(requestedStoreId = "") {
    if (requestedStoreId) return isLicensedStore(requestedStoreId) ? [requestedStoreId] : [];
    return licensedScopedStores().map((store) => store.id);
  }

  function isPersistedConfigurationId(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ""));
  }

  function createConfigurationClientKey(prefix) {
    if (window.crypto?.randomUUID) return `${prefix}:${window.crypto.randomUUID()}`;
    return `${prefix}:${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  }

  function buildConfigurationPayload(draft) {
    const numberValue = (value) => value === "" || value === null || value === undefined ? Number.NaN : Number(value);
    const categoriesWithPending = [...draft.categories];
    if (String(draft.pendingCategoryName || "").trim()) {
      categoriesWithPending.push({
        id: draft.pendingCategoryClientKey,
        clientKey: draft.pendingCategoryClientKey,
        name: draft.pendingCategoryName,
        tags: [],
      });
    }
    return {
      schema_version: 1,
      base_revision: draft.baseRevision,
      settings: {
        daily_goal: numberValue(draft.settings.dailyGoal),
        bonus_minimum: numberValue(draft.settings.bonusMinimum),
        bonus_amount: numberValue(draft.settings.bonusAmount),
        accent_color: String(draft.settings.accentColor || DEFAULT_SETTINGS.accentColor).toLowerCase(),
        logo_background_color: String(draft.settings.logoBackgroundColor || DEFAULT_SETTINGS.logoBackgroundColor).toLowerCase(),
      },
      categories: categoriesWithPending.map((category, categoryIndex) => ({
        id: isPersistedConfigurationId(category.id) ? category.id : null,
        client_key: category.clientKey || category.id,
        name: String(category.name || "").trim(),
        sort_order: (categoryIndex + 1) * 10,
        tags: [
          ...category.tags,
          ...(String(category.pendingTagName || "").trim() ? [{
            id: category.pendingTagClientKey,
            clientKey: category.pendingTagClientKey,
            label: category.pendingTagName,
          }] : []),
        ].map((tag, tagIndex) => ({
          id: isPersistedConfigurationId(tag.id) ? tag.id : null,
          client_key: tag.clientKey || tag.id,
          label: String(tag.label || "").trim(),
          sort_order: (tagIndex + 1) * 10,
        })),
      })),
      professionals: [
        ...draft.professionals,
        ...(String(draft.pendingProfessionalName || "").trim() ? [{
          id: draft.pendingProfessionalClientKey,
          clientKey: draft.pendingProfessionalClientKey,
          name: draft.pendingProfessionalName,
          active: true,
        }] : []),
      ].map((professional) => ({
        id: isPersistedConfigurationId(professional.id) ? professional.id : null,
        client_key: professional.clientKey || professional.id,
        name: String(professional.name || "").trim(),
        is_active: professional.active !== false,
      })),
      deleted_category_ids: [...draft.deletedCategoryIds],
      deleted_tag_ids: [...draft.deletedTagIds],
      deleted_professional_ids: [...draft.deletedProfessionalIds],
    };
  }

  function createConfigurationDraft(storeId) {
    const config = settingsFor(storeId);
    const draft = {
      storeId,
      baseRevision: config.revision || "",
      settings: { ...config },
      categories: categoriesFor(storeId).map((category) => ({
        ...category,
        clientKey: `category:${category.id}`,
        tags: tagsFor(storeId)
          .filter((tag) => tag.categoryId === category.id)
          .map((tag) => ({ ...tag, clientKey: `tag:${tag.id}` })),
        pendingTagName: "",
        pendingTagClientKey: createConfigurationClientKey("tag"),
      })),
      professionals: professionalsFor(storeId, true)
        .map((professional) => ({ ...professional, clientKey: `professional:${professional.id}` })),
      deletedCategoryIds: [],
      deletedTagIds: [],
      deletedProfessionalIds: [],
      removedProfessionals: [],
      pendingCategoryName: "",
      pendingCategoryClientKey: createConfigurationClientKey("category"),
      pendingProfessionalName: "",
      pendingProfessionalClientKey: createConfigurationClientKey("professional"),
      dirty: false,
      baseline: "",
    };
    draft.baseline = JSON.stringify(buildConfigurationPayload(draft));
    return draft;
  }

  function configurationDraftFor(storeId) {
    return configurationSession?.drafts.get(storeId) || null;
  }

  function syncConfigurationDirty(draft) {
    if (!draft) return false;
    draft.dirty = JSON.stringify(buildConfigurationPayload(draft)) !== draft.baseline;
    const row = root.querySelector(`[data-config-store="${CSS.escape(draft.storeId)}"]`);
    if (!row) return draft.dirty;
    const isLocked = Boolean(configurationSession?.saving || configurationSession?.recoveryRequired);
    row.classList.toggle("has-unsaved-changes", draft.dirty);
    row.setAttribute("aria-busy", isLocked ? "true" : "false");
    row.inert = isLocked;
    const saveButton = row.querySelector('[data-prospection-action="save-configuration"]');
    if (saveButton) {
      saveButton.disabled = !draft.dirty || isLocked;
      saveButton.classList.toggle("is-loading", Boolean(configurationSession?.saving));
      saveButton.innerHTML = configurationSession?.saving
        ? '<i class="fa-solid fa-circle-notch fa-spin"></i>Salvando…'
        : '<i class="fa-solid fa-check"></i>Salvar alterações';
    }
    const status = row.querySelector("[data-config-save-status]");
    if (status) {
      status.classList.toggle("is-dirty", draft.dirty);
      status.innerHTML = configurationSession?.recoveryRequired
        ? '<i class="fa-solid fa-cloud-arrow-down"></i><span><strong>Dados salvos</strong><small>Feche e reabra para carregar a versão atual.</small></span>'
        : draft.dirty
        ? '<i class="fa-solid fa-circle-exclamation"></i><span><strong>Alterações não salvas</strong><small>Revise e salve tudo de uma vez.</small></span>'
        : '<i class="fa-solid fa-circle-check"></i><span><strong>Tudo salvo</strong><small>A configuração está sincronizada.</small></span>';
    }
    const dialogClose = root.querySelector("[data-prospection-configuration-dialog] .prospection-dialog-close");
    if (dialogClose) dialogClose.disabled = Boolean(configurationSession?.saving);
    return draft.dirty;
  }

  function setConfigurationSavingState(isSaving) {
    if (!configurationSession) return;
    configurationSession.saving = Boolean(isSaving);
    configurationSession.drafts.forEach((draft) => syncConfigurationDirty(draft));
    const unsavedDialog = root.querySelector(".prospection-unsaved-dialog");
    if (unsavedDialog) {
      unsavedDialog.setAttribute("aria-busy", isSaving ? "true" : "false");
      unsavedDialog.querySelectorAll("button").forEach((button) => { button.disabled = Boolean(isSaving); });
    }
  }

  function hasUnsavedConfiguration() {
    return Boolean(configurationSession && [...configurationSession.drafts.values()].some((draft) => draft.dirty));
  }

  function configurationDialogMarkup(storesToConfigure, requestedStoreId) {
    const body = storesToConfigure.length
      ? `<div class="prospection-config-list">${storesToConfigure.map(configurationRowMarkup).join("")}</div>`
      : emptyMarkup("Nenhum cliente com Prospecções", "Libere uma licença para o cliente no módulo Leads antes de configurar categorias e equipe.");
    return `<div class="analysis-overlay prospection-dialog-backdrop" data-prospection-configuration-dialog><section class="admin-settings-panel" role="dialog" aria-modal="true" aria-labelledby="prospection-settings-title"><div class="admin-settings-header"><div><p class="eyebrow">${bridge.profile.role === "technician" ? "Configuração da Agência" : "Personalização"}</p><h2 id="prospection-settings-title">${requestedStoreId ? "Configurar cliente" : "Configurar clientes"}</h2></div><button class="icon-button prospection-dialog-close" type="button" data-prospection-action="close-dialog" aria-label="Fechar configurações">&#215;</button></div>${body}</section></div>`;
  }

  function renderConfigurationDialog({ preserveSession = false } = {}) {
    if (!configurationSession) return;
    const storesToConfigure = configurationSession.storeIds.map(storeById).filter(Boolean);
    const previousPanel = root.querySelector("[data-prospection-configuration-dialog] .admin-settings-panel");
    const previousScroll = previousPanel?.scrollTop ?? configurationSession.scrollTop ?? 0;
    configurationSession.scrollTop = previousScroll;
    if (!preserveSession) forceCloseDialogs({ preserveConfiguration: true });
    else root.querySelector("[data-prospection-configuration-dialog]")?.remove();
    root.insertAdjacentHTML("beforeend", configurationDialogMarkup(storesToConfigure, configurationSession.requestedStoreId));
    document.body.classList.add("is-modal-open");
    requestAnimationFrame(() => {
      const panel = root.querySelector("[data-prospection-configuration-dialog] .admin-settings-panel");
      if (panel) panel.scrollTop = previousScroll;
      configurationSession?.drafts.forEach((draft) => syncConfigurationDirty(draft));
      if (!preserveSession) root.querySelector(".prospection-dialog-close")?.focus();
    });
  }

  function showUnsavedConfigurationDialog() {
    if (root.querySelector(".prospection-unsaved-backdrop")) return;
    const configurationDialog = root.querySelector("[data-prospection-configuration-dialog] .admin-settings-panel");
    if (configurationDialog) configurationDialog.inert = true;
    root.insertAdjacentHTML("beforeend", `<div class="prospection-unsaved-backdrop"><section class="prospection-unsaved-dialog" role="alertdialog" aria-modal="true" aria-labelledby="prospection-unsaved-title" aria-describedby="prospection-unsaved-description"><span class="prospection-unsaved-icon"><i class="fa-solid fa-pen-to-square"></i></span><div class="prospection-unsaved-copy"><p class="eyebrow">Alterações pendentes</p><h3 id="prospection-unsaved-title">Salvar antes de sair?</h3><p id="prospection-unsaved-description">Você alterou esta configuração. Escolha se deseja salvar tudo agora ou sair sem aplicar as mudanças.</p></div><div class="prospection-unsaved-actions"><button class="secondary-button" type="button" data-prospection-action="cancel-configuration-exit">Continuar editando</button><button class="secondary-button is-danger" type="button" data-prospection-action="discard-configuration-exit">Sair sem salvar</button><button class="primary-button" type="button" data-prospection-action="save-configuration-exit"><i class="fa-solid fa-check"></i>Salvar e sair</button></div></section></div>`);
    requestAnimationFrame(() => root.querySelector('[data-prospection-action="save-configuration-exit"]')?.focus());
  }

  function requestConfigurationTransition(run = null) {
    if (configurationSession?.saving) {
      bridge.notify("Aguarde o salvamento terminar.");
      return true;
    }
    if (pendingConfigurationTransition) return true;
    if (!hasUnsavedConfiguration()) {
      if (run) run();
      return false;
    }
    pendingConfigurationTransition = { run, returnFocus: document.activeElement };
    showUnsavedConfigurationDialog();
    return true;
  }

  function requestDeactivate() {
    if (configurationSession?.saving) {
      bridge.notify("Aguarde o salvamento terminar.");
      return Promise.resolve(false);
    }
    if (pendingConfigurationTransition) return Promise.resolve(false);
    if (!active || !hasUnsavedConfiguration()) return Promise.resolve(true);
    return new Promise((resolve) => {
      pendingConfigurationTransition = { resolve, returnFocus: document.activeElement };
      showUnsavedConfigurationDialog();
    });
  }

  function finishConfigurationTransition(allow) {
    const transition = pendingConfigurationTransition;
    pendingConfigurationTransition = null;
    root.querySelector(".prospection-unsaved-backdrop")?.remove();
    const configurationDialog = root.querySelector("[data-prospection-configuration-dialog] .admin-settings-panel");
    if (configurationDialog) configurationDialog.inert = false;
    if (!transition) return;
    if (transition.resolve) transition.resolve(Boolean(allow));
    if (allow && transition.run) transition.run();
    if (!allow && transition.returnFocus instanceof HTMLElement) transition.returnFocus.focus();
  }

  async function openConfiguration(requestedStoreId = "", { preserveSession = false } = {}) {
    if (configurationNeedsRefresh) {
      try {
        await loadData();
        configurationNeedsRefresh = false;
      } catch (error) {
        bridge.notify(`Não foi possível recarregar a configuração: ${readableError(error)}`, "error");
        return;
      }
    }
    const storeIds = configurationStoreIds(requestedStoreId);
    if (!preserveSession || !configurationSession) {
      configurationSession = {
        requestedStoreId,
        storeIds,
        drafts: new Map(storeIds.map((storeId) => [storeId, createConfigurationDraft(storeId)])),
        saving: false,
        recoveryRequired: false,
        scrollTop: 0,
      };
    }
    renderConfigurationDialog({ preserveSession });
  }

  function canImportProspectionBackup() {
    return Boolean(bridge && ["admin", "technician"].includes(bridge.profile.role));
  }

  function summarizeBackupPayload(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("O arquivo não contém um objeto JSON válido.");
    if (payload.format !== "prospec-backup" || Number(payload.schema_version) !== 1) throw new Error("Use um backup do Prospec no formato versão 1.");
    if (payload.integrity && payload.integrity.import_ready === false) throw new Error("Este backup informa que não está pronto para importação.");
    const sourceStores = payload?.data?.stores;
    if (!Array.isArray(sourceStores) || sourceStores.length !== 1) throw new Error("O backup deve conter exatamente uma loja de origem.");
    const source = sourceStores[0] || {};
    if (!Array.isArray(source.prospects) || !Array.isArray(source.professionals) || !Array.isArray(source.tags)) {
      throw new Error("O backup não possui listas válidas de prospecções, profissionais e etiquetas.");
    }
    const historicalTags = new Set(source.tags.map((tag) => String(tag?.label || "").trim()).filter(Boolean));
    source.prospects.forEach((prospect) => {
      if (Array.isArray(prospect?.tags)) prospect.tags.forEach((tag) => historicalTags.add(String(tag || "").trim()));
    });
    return {
      prospects: source.prospects.length,
      professionals: source.professionals.length,
      tags: [...historicalTags].filter(Boolean).length,
      returns: source.prospects.filter((row) => row?.returned_at).length,
      purchases: source.prospects.filter((row) => row?.purchased_at).length,
      missingNames: source.prospects.filter((row) => !String(row?.name || "").trim()).length,
      exportedAt: payload.exported_at || null,
    };
  }

  function importMetricMarkup(icon, value, label) {
    return `<article><i class="fa-solid ${icon}"></i><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></article>`;
  }

  function importTargetMarkup(store) {
    const config = settingsFor(store.id);
    return `<div class="prospection-import-target" style="--account-color:${escapeHtml(config.accentColor)}">
      <div class="prospection-account-identity">${accountVisual(store.avatarUrl || "", store.name, "fa-store", config.logoBackgroundColor)}<div><small>Destino protegido</small><strong>${escapeHtml(store.name)}</strong><span>Nome, login, logo e acesso não serão alterados.</span></div></div>
      <span class="prospection-scope-lock"><i class="fa-solid fa-lock"></i>Dados isolados nesta loja</span>
    </div>`;
  }

  function importFileCardMarkup(draft) {
    const hasFile = Boolean(draft?.fileName);
    const statusLabel = draft?.status === "validating"
      ? "Validando no banco…"
      : draft?.status === "importing"
        ? "Importando com segurança…"
        : draft?.validation
          ? "Arquivo validado"
          : "Selecionar backup";
    return `<label class="prospection-import-dropzone${hasFile ? " has-file" : ""}${draft?.status === "validating" || draft?.status === "importing" ? " is-loading" : ""}" for="prospectionBackupFile">
      <input id="prospectionBackupFile" type="file" accept=".json,application/json" data-prospection-import-file data-store-id="${escapeHtml(draft?.storeId || "")}" />
      <span class="prospection-import-file-icon"><i class="fa-solid ${hasFile ? "fa-file-circle-check" : "fa-cloud-arrow-up"}"></i></span>
      <span class="prospection-import-file-copy"><strong>${hasFile ? escapeHtml(draft.fileName) : "Escolha o arquivo JSON"}</strong><small>${hasFile ? `${escapeHtml(formatFileSize(draft.fileSize))} · ${escapeHtml(statusLabel)}` : "Arraste ou clique para selecionar · máximo de 10 MB"}</small></span>
      <span class="secondary-button">${hasFile ? "Trocar arquivo" : "Procurar"}</span>
    </label>`;
  }

  function formatFileSize(size) {
    const bytes = Number(size || 0);
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1).replace(".", ",")} MB`;
  }

  function importPreviewMarkup(draft) {
    if (!draft?.validation) {
      const message = draft?.error
        ? `<div class="prospection-import-alert is-error"><i class="fa-solid fa-circle-exclamation"></i><span>${escapeHtml(draft.error)}</span></div>`
        : `<div class="prospection-import-empty"><i class="fa-solid fa-shield-halved"></i><div><strong>Importação segura e sem duplicação</strong><span>O arquivo é validado antes de qualquer gravação. Dados atuais permanecem e um reenvio do mesmo backup não cria cópias.</span></div></div>`;
      return `${message}<p class="prospection-form-message" data-dialog-message></p>`;
    }

    const result = normalizeRpcObject(draft.validation);
    const counts = result.counts || {};
    const prospectCounts = counts.prospects || {};
    const professionalCounts = counts.professionals || {};
    const tagCounts = counts.tags || {};
    const outcomes = counts.outcomes || {};
    const normalized = counts.normalized || {};
    const settingsPreview = result.settings || {};
    const alreadyImported = result.already_imported === true;
    const warnings = Object.values(result.warnings || {}).filter(Boolean);
    return `<div class="prospection-import-validation-bar${alreadyImported ? " is-repeated" : ""}"><i class="fa-solid ${alreadyImported ? "fa-clock-rotate-left" : "fa-shield-circle-check"}"></i><div><strong>${alreadyImported ? "Este arquivo já foi importado" : "Pronto para importar"}</strong><span>${alreadyImported ? "A confirmação apenas confere o lote existente; nenhuma prospecção será duplicada." : "Formato, escopo, datas e vínculos foram validados pelo banco."}</span></div></div>
      ${draft.error ? `<div class="prospection-import-alert is-error"><i class="fa-solid fa-circle-exclamation"></i><span>${escapeHtml(draft.error)}</span></div>` : ""}
      <div class="prospection-import-metrics">
        ${importMetricMarkup("fa-address-card", prospectCounts.eligible ?? prospectCounts.total ?? draft.localSummary?.prospects ?? 0, "Prospecções")}
        ${importMetricMarkup("fa-user-group", professionalCounts.total ?? draft.localSummary?.professionals ?? 0, "Profissionais")}
        ${importMetricMarkup("fa-tags", tagCounts.total ?? draft.localSummary?.tags ?? 0, "Etiquetas")}
        ${importMetricMarkup("fa-store", outcomes.returns ?? draft.localSummary?.returns ?? 0, "Retornos")}
        ${importMetricMarkup("fa-bag-shopping", outcomes.purchases ?? draft.localSummary?.purchases ?? 0, "Compras")}
      </div>
      <div class="prospection-import-details">
        <div><span>Meta diária</span><strong>${escapeHtml(settingsPreview.daily_goal ?? "—")}</strong></div>
        <div><span>Compra mínima</span><strong>${settingsPreview.bonus_minimum == null ? "—" : escapeHtml(formatCurrency(settingsPreview.bonus_minimum))}</strong></div>
        <div><span>Bônus por compra</span><strong>${settingsPreview.bonus_amount == null ? "—" : escapeHtml(formatCurrency(settingsPreview.bonus_amount))}</strong></div>
        <div><span>Histórico de origem</span><strong>${result.source?.exported_at ? escapeHtml(formatDateTime(result.source.exported_at)) : "Data não informada"}</strong></div>
      </div>
      ${warnings.length ? `<div class="prospection-import-alert"><i class="fa-solid fa-wand-magic-sparkles"></i><div>${warnings.map((warning) => `<span>${escapeHtml(warning)}</span>`).join("")}</div></div>` : ""}
      ${Number(prospectCounts.skipped_expired || 0) ? `<div class="prospection-import-alert"><i class="fa-solid fa-clock-rotate-left"></i><span>${escapeHtml(prospectCounts.skipped_expired)} registro(s) anteriores a dois anos serão ignorados conforme a política de retenção.</span></div>` : ""}
      ${Number(normalized.missing_names || 0) ? `<small class="prospection-import-footnote">Contatos sem nome recebem uma identificação rastreável; nenhum histórico válido é perdido.</small>` : ""}
      <label class="prospection-import-consent"><input type="checkbox" data-prospection-import-consent /><span>Confirmo a importação para <strong>${escapeHtml(storeById(draft.storeId)?.name || "esta loja")}</strong>. Os dados serão mesclados sem apagar os registros atuais.</span></label>
      <p class="prospection-form-message" data-dialog-message></p>`;
  }

  function openImportDialog(storeId, nextDraft = null) {
    if (!canImportProspectionBackup()) {
      bridge.notify("Apenas o Admin ou a Agência podem importar dados.", "error");
      return;
    }
    const store = storeById(storeId);
    if (!store || !isLicensedStore(storeId)) {
      bridge.notify("Cliente não encontrado ou sem acesso a Prospecções.", "error");
      return;
    }
    const draft = { storeId, ...(nextDraft || {}) };
    const isBusy = ["validating", "importing"].includes(draft.status);
    const body = `<div class="prospection-import-shell">
      ${importTargetMarkup(store)}
      <div class="prospection-import-layout">
        <section class="prospection-import-main">
          ${importFileCardMarkup(draft)}
          ${importPreviewMarkup(draft)}
        </section>
        <aside class="prospection-import-guardrails"><p class="eyebrow">O que será importado</p><ul><li><i class="fa-solid fa-check"></i>Prospecções e seus históricos</li><li><i class="fa-solid fa-check"></i>Profissionais e etiquetas</li><li><i class="fa-solid fa-check"></i>Retornos, compras, valores e OS</li><li><i class="fa-solid fa-check"></i>Meta e regras de bonificação</li></ul><p class="eyebrow">O que fica preservado</p><ul class="is-muted"><li><i class="fa-solid fa-lock"></i>Nome e login da loja</li><li><i class="fa-solid fa-lock"></i>Logo, cores e permissões</li><li><i class="fa-solid fa-lock"></i>Dados que já existem</li></ul></aside>
      </div>
      <div class="prospection-import-actions"><button class="prospection-button is-secondary" type="button" data-prospection-action="return-configuration" data-store-id="${escapeHtml(storeId)}"${isBusy ? " disabled" : ""}><i class="fa-solid fa-arrow-left"></i>Voltar às configurações</button>${draft.validation ? `<button class="prospection-button" type="button" data-prospection-action="confirm-import" data-store-id="${escapeHtml(storeId)}" disabled><i class="fa-solid ${draft.status === "importing" ? "fa-circle-notch fa-spin" : "fa-file-import"}"></i>${draft.status === "importing" ? "Importando…" : draft.validation?.already_imported ? "Conferir sem duplicar" : `Importar para ${escapeHtml(store.name)}`}</button>` : ""}</div>
    </div>`;
    openDialog(dialogShell({ eyebrow: "Migração de dados", title: "Importar backup do Prospec", body, wide: true }));
    importDraft = draft;
  }

  async function handleImportFile(input, droppedFile = null) {
    const storeId = input.dataset.storeId || "";
    const file = droppedFile || input.files?.[0];
    if (!file || !canImportProspectionBackup()) return;
    const nonce = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    let draft = { storeId, fileName: file.name, fileSize: file.size, nonce, status: "validating" };
    try {
      if (file.size > 10 * 1024 * 1024) throw new Error("O arquivo excede o limite de 10 MB.");
      if (!file.name.toLowerCase().endsWith(".json")) throw new Error("Selecione um arquivo com extensão .json.");
      const payload = JSON.parse(await file.text());
      const localSummary = summarizeBackupPayload(payload);
      draft = { ...draft, payload, localSummary };
      openImportDialog(storeId, draft);
      const validation = normalizeRpcObject(await bridge.rpc("lc_import_prospec_backup", {
        p_store_id: storeId,
        p_payload: payload,
        p_validate_only: true,
      }));
      if (importDraft?.nonce !== nonce) return;
      openImportDialog(storeId, { ...draft, status: "ready", validation });
    } catch (error) {
      const message = readableError(error);
      if (draft.payload && (!importDraft || importDraft.nonce !== nonce)) return;
      openImportDialog(storeId, { ...draft, status: "error", error: message });
      bridge.notify(message, "error");
    }
  }

  function importResultMarkup(store, result) {
    const counts = result.counts || {};
    const prospectCounts = counts.prospects || {};
    const professionalCounts = counts.professionals || {};
    const tagCounts = counts.tags || {};
    const repeated = result.already_imported === true;
    return `<div class="prospection-import-result">
      <span class="prospection-import-result-icon"><i class="fa-solid ${repeated ? "fa-shield" : "fa-circle-check"}"></i></span>
      <div><p class="eyebrow">${repeated ? "Backup protegido" : "Importação concluída"}</p><h3>${repeated ? "Nenhum dado foi duplicado" : `Dados adicionados a ${escapeHtml(store.name)}`}</h3><span>${repeated ? "Este mesmo arquivo já havia sido processado nesta loja." : "O lote foi gravado de forma atômica e já está disponível nas análises."}</span></div>
      <div class="prospection-import-metrics">
        ${importMetricMarkup("fa-plus", prospectCounts.inserted || 0, "Prospecções novas")}
        ${importMetricMarkup("fa-rotate", prospectCounts.updated || 0, "Atualizadas")}
        ${importMetricMarkup("fa-user-plus", professionalCounts.created || 0, "Profissionais novos")}
        ${importMetricMarkup("fa-tag", tagCounts.created || 0, "Etiquetas novas")}
        ${importMetricMarkup("fa-shield-halved", prospectCounts.unchanged || 0, "Já sincronizadas")}
      </div>
      <button class="prospection-button" type="button" data-prospection-action="return-configuration" data-store-id="${escapeHtml(store.id)}"><i class="fa-solid fa-check"></i>Concluir e revisar</button>
    </div>`;
  }

  async function executeBackupImport() {
    const draft = importDraft;
    if (!draft?.payload || !draft?.validation || draft.status === "importing") return;
    const consent = root.querySelector("[data-prospection-import-consent]");
    if (!consent?.checked) {
      const message = root.querySelector("[data-dialog-message]");
      if (message) message.textContent = "Confirme a loja de destino antes de importar.";
      return;
    }
    const nonce = draft.nonce;
    openImportDialog(draft.storeId, { ...draft, status: "importing" });
    try {
      const result = normalizeRpcObject(await bridge.rpc("lc_import_prospec_backup", {
        p_store_id: draft.storeId,
        p_payload: draft.payload,
        p_validate_only: false,
      }));
      await reload({ configuration: true });
      const store = storeById(draft.storeId);
      if (importDraft?.nonce !== nonce || !store) return;
      openDialog(dialogShell({
        eyebrow: "Importação segura",
        title: result.already_imported ? "Backup já conferido" : "Tudo pronto",
        body: importResultMarkup(store, result),
      }));
      bridge.notify(result.already_imported ? "Este backup já estava importado; nada foi duplicado." : "Backup importado com sucesso.");
    } catch (error) {
      const message = readableError(error);
      if (importDraft?.nonce === nonce) openImportDialog(draft.storeId, { ...draft, status: "ready", error: message });
      bridge.notify(message, "error");
    }
  }

  function configurationRowMarkup(store) {
    const draft = configurationDraftFor(store.id) || createConfigurationDraft(store.id);
    const config = draft.settings;
    return `<article class="admin-store-settings-panel prospection-config-row" data-config-store="${escapeHtml(store.id)}" style="--account-color:${escapeHtml(config.accentColor)}">
      <div class="prospection-config-row-header"><div class="prospection-account-identity">${accountVisual(store.avatarUrl || "", store.name, "fa-store", config.logoBackgroundColor)}<div><strong>${escapeHtml(store.name)}</strong><span>Metas, identidade, categorias, subcategorias e equipe</span></div></div>${["admin", "technician"].includes(bridge.profile.role) ? `<button class="secondary-button prospection-import-trigger" type="button" data-prospection-action="open-import" data-store-id="${escapeHtml(store.id)}"><i class="fa-solid fa-file-import"></i><span>Importar dados</span></button>` : ""}</div>
      <div class="prospection-config-section-heading"><div><span>Metas e identidade</span><small>Regras comerciais e aparência desta loja.</small></div></div>
      <div class="store-settings-fields prospection-config-grid" data-prospection-settings-editor data-store-id="${escapeHtml(store.id)}">
        <label class="prospection-field">Meta diária<input name="dailyGoal" data-config-setting="dailyGoal" type="number" min="1" max="9999" value="${config.dailyGoal}" /></label>
        <label class="prospection-field">Compra mínima para bônus<input name="bonusMinimum" data-config-setting="bonusMinimum" type="number" min="0" step="0.01" value="${config.bonusMinimum}" /></label>
        <label class="prospection-field">Bônus por compra válida<input name="bonusAmount" data-config-setting="bonusAmount" type="number" min="0" step="0.01" value="${config.bonusAmount}" /></label>
        <label class="prospection-field prospection-color-field"><span>Cor de destaque</span><span class="prospection-color-control"><input name="accentColor" data-config-setting="accentColor" type="color" value="${escapeHtml(config.accentColor)}" /><code>${escapeHtml(config.accentColor.toUpperCase())}</code></span></label>
        <label class="prospection-field prospection-color-field"><span>Fundo da logo</span><span class="prospection-color-control"><input name="logoBackgroundColor" data-config-setting="logoBackgroundColor" type="color" value="${escapeHtml(config.logoBackgroundColor)}" /><code>${escapeHtml(config.logoBackgroundColor.toUpperCase())}</code></span></label>
      </div>
      <div class="store-managers-grid prospection-config-columns">
        ${categoryManagerMarkup(store.id, draft)}
        ${professionalManagerMarkup(store.id, draft)}
      </div>
      <footer class="prospection-config-savebar"><div class="prospection-config-save-status${draft.dirty ? " is-dirty" : ""}" data-config-save-status aria-live="polite">${draft.dirty ? '<i class="fa-solid fa-circle-exclamation"></i><span><strong>Alterações não salvas</strong><small>Revise e salve tudo de uma vez.</small></span>' : '<i class="fa-solid fa-circle-check"></i><span><strong>Tudo salvo</strong><small>A configuração está sincronizada.</small></span>'}</div><button class="primary-button config-save-button" type="button" data-prospection-action="save-configuration" data-store-id="${escapeHtml(store.id)}"${draft.dirty ? "" : " disabled"}><i class="fa-solid fa-check"></i>Salvar alterações</button></footer>
    </article>`;
  }

  function categoryManagerMarkup(storeId, draft = configurationDraftFor(storeId)) {
    const storeCategories = draft?.categories || [];
    return `<section class="store-mini-manager prospection-category-manager">
      <form class="store-manager-form prospection-inline-form" data-prospection-category-form data-store-id="${escapeHtml(storeId)}"><input name="name" maxlength="60" placeholder="Nova categoria" value="${escapeHtml(draft?.pendingCategoryName || "")}" required /><button class="secondary-button" type="submit"><i class="fa-solid fa-plus"></i>Categoria</button></form>
      <div class="prospection-category-list">
        ${storeCategories.map((category, categoryIndex) => categoryEditorMarkup(category, categoryIndex, storeCategories.length, storeId)).join("") || `<div class="prospection-empty is-compact"><strong>Nenhuma categoria</strong><span>Crie a primeira categoria para organizar as subcategorias.</span></div>`}
      </div>
    </section>`;
  }

  function professionalManagerMarkup(storeId, draft = configurationDraftFor(storeId)) {
    const professionalsMarkup = draft.professionals.map((professional) => `<div class="store-professional-row prospection-managed-item" data-prospection-professional-update data-professional-id="${escapeHtml(professional.id)}"><input name="name" data-config-professional-name value="${escapeHtml(professional.name)}" maxlength="100" aria-label="Nome do profissional ${escapeHtml(professional.name)}" /><label class="store-professional-active"><input name="active" data-config-professional-active type="checkbox"${professional.active ? " checked" : ""} aria-label="Profissional ${escapeHtml(professional.name)} ativo em Prospecções" /><span class="prospection-toggle-track" aria-hidden="true"></span><em data-professional-status>${professional.active ? "Ativo" : "Inativo"}</em></label><button class="prospection-icon-action is-danger prospection-professional-delete" type="button" data-prospection-action="delete-professional" data-store-id="${escapeHtml(storeId)}" data-professional-id="${escapeHtml(professional.id)}" aria-label="Excluir profissional ${escapeHtml(professional.name)}"><i class="fa-solid fa-trash"></i></button></div>`).join("");
    const removalsMarkup = draft.removedProfessionals.map(({ professional, persisted }) => `<div class="prospection-professional-removal"><span><i class="fa-solid fa-user-slash"></i><strong>${escapeHtml(professional.name)}</strong> ${persisted ? "sairá da equipe ao salvar" : "foi removido do rascunho"}</span><button type="button" data-prospection-action="undo-delete-professional" data-store-id="${escapeHtml(storeId)}" data-professional-id="${escapeHtml(professional.id)}"><i class="fa-solid fa-rotate-left"></i>Desfazer</button></div>`).join("");
    return `<section class="store-mini-manager prospection-professional-manager"><div class="prospection-manager-heading"><div><span>Profissionais</span><small>Ative para Prospecções; inativos continuam disponíveis em Atendimentos.</small></div></div><form class="store-manager-form prospection-inline-form" data-prospection-professional-form data-store-id="${escapeHtml(storeId)}"><input name="name" maxlength="100" placeholder="Nome do profissional" value="${escapeHtml(draft.pendingProfessionalName)}" required /><button class="secondary-button" type="submit"><i class="fa-solid fa-plus"></i>Criar</button></form><div class="prospection-managed-items prospection-professional-list">${professionalsMarkup || `<div class="prospection-empty is-compact"><strong>Nenhum profissional</strong><span>Cadastre quem será responsável pelos atendimentos.</span></div>`}</div>${removalsMarkup ? `<div class="prospection-professional-removal-list" aria-label="Profissionais aguardando exclusão">${removalsMarkup}</div>` : ""}</section>`;
  }

  function categoryEditorMarkup(category, categoryIndex, categoryCount, storeId) {
    const categoryTags = category.tags || [];
    return `<article class="prospection-category-card">
      <div class="prospection-category-header">
        <div class="prospection-category-name" data-prospection-category-update data-category-id="${escapeHtml(category.id)}"><span class="prospection-drag-handle"><i class="fa-solid fa-grip-vertical"></i></span><input name="name" data-config-category-name value="${escapeHtml(category.name)}" maxlength="60" aria-label="Nome da categoria" /></div>
        <div class="prospection-order-actions"><button class="prospection-icon-action" type="button" data-prospection-action="move-category" data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(category.id)}" data-direction="up"${categoryIndex === 0 ? " disabled" : ""} aria-label="Mover categoria para cima"><i class="fa-solid fa-chevron-up"></i></button><button class="prospection-icon-action" type="button" data-prospection-action="move-category" data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(category.id)}" data-direction="down"${categoryIndex === categoryCount - 1 ? " disabled" : ""} aria-label="Mover categoria para baixo"><i class="fa-solid fa-chevron-down"></i></button><button class="prospection-icon-action is-danger" type="button" data-prospection-action="delete-category" data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(category.id)}" aria-label="Excluir categoria"><i class="fa-solid fa-trash"></i></button></div>
      </div>
      <form class="store-manager-form prospection-inline-form is-tag-form" data-prospection-tag-form data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(category.id)}"><input name="label" maxlength="60" placeholder="Nova subcategoria em ${escapeHtml(category.name)}" value="${escapeHtml(category.pendingTagName || "")}" required /><button class="secondary-button" type="submit"><i class="fa-solid fa-plus"></i>Subcategoria</button></form>
      <div class="prospection-tag-editor-list">
        ${categoryTags.map((tag, tagIndex) => tagEditorMarkup(tag, tagIndex, categoryTags.length, storeId, category.id)).join("") || `<small>Nenhuma subcategoria nesta categoria.</small>`}
      </div>
    </article>`;
  }

  function tagEditorMarkup(tag, tagIndex, tagCount, storeId, categoryId) {
    return `<div class="prospection-tag-editor-row" data-prospection-tag-update data-store-id="${escapeHtml(storeId)}" data-tag-id="${escapeHtml(tag.id)}" data-category-id="${escapeHtml(categoryId)}"><span class="prospection-drag-handle"><i class="fa-solid fa-tag"></i></span><input name="label" data-config-tag-label value="${escapeHtml(tag.label)}" maxlength="60" aria-label="Nome da etiqueta" /><div class="prospection-order-actions"><button class="prospection-icon-action" type="button" data-prospection-action="move-tag" data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(categoryId)}" data-tag-id="${escapeHtml(tag.id)}" data-direction="up"${tagIndex === 0 ? " disabled" : ""} aria-label="Mover etiqueta para cima"><i class="fa-solid fa-chevron-up"></i></button><button class="prospection-icon-action" type="button" data-prospection-action="move-tag" data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(categoryId)}" data-tag-id="${escapeHtml(tag.id)}" data-direction="down"${tagIndex === tagCount - 1 ? " disabled" : ""} aria-label="Mover etiqueta para baixo"><i class="fa-solid fa-chevron-down"></i></button><button class="prospection-icon-action is-danger" type="button" data-prospection-action="delete-tag" data-store-id="${escapeHtml(storeId)}" data-category-id="${escapeHtml(categoryId)}" data-tag-id="${escapeHtml(tag.id)}" aria-label="Excluir etiqueta"><i class="fa-solid fa-trash"></i></button></div></div>`;
  }

  function reportRows(storeIds) {
    return storeIds.map((storeId) => {
      const store = storeById(storeId) || { name: "Cliente" };
      const rows = prospectsFor(storeId);
      return { storeId, name: store.name, ...metricsFor(rows) };
    }).sort((a, b) => b.purchased - a.purchased || b.total - a.total);
  }

  function openReports(requestedStoreId = "") {
    const storeIds = requestedStoreId ? [requestedStoreId] : licensedScopedStores().map((store) => store.id);
    const rows = reportRows(storeIds);
    const table = rows.length ? `<div style="overflow:auto"><table class="prospection-report-table"><thead><tr><th>Cliente</th><th>Prospecções</th><th>Vieram</th><th>Compraram</th><th>Conversão</th><th>Bônus</th></tr></thead><tbody>${rows.map((row) => `<tr><td>${escapeHtml(row.name)}</td><td>${row.total}</td><td>${row.returned}</td><td>${row.purchased}</td><td>${row.conversion}%</td><td>${formatCurrency(row.bonus)}</td></tr>`).join("")}</tbody></table></div>` : emptyMarkup("Sem dados para relatório", "Registre prospecções para gerar o consolidado.");
    openDialog(dialogShell({
      eyebrow: "Relatórios",
      title: `Consolidado · ${periodWindow().label}`,
      wide: true,
      body: `<div class="prospection-account-actions"><button class="prospection-button" type="button" data-prospection-action="export-report" data-store-id="${escapeHtml(requestedStoreId)}"><i class="fa-solid fa-file-csv"></i>Exportar CSV</button></div>${table}`,
    }));
  }

  function exportReport(requestedStoreId = "") {
    const storeIds = requestedStoreId ? [requestedStoreId] : licensedScopedStores().map((store) => store.id);
    const rows = reportRows(storeIds);
    const csvRows = [["Cliente", "Prospeccoes", "Vieram", "Compraram", "Conversao", "Bonificacao"], ...rows.map((row) => [row.name, row.total, row.returned, row.purchased, `${row.conversion}%`, row.bonus.toFixed(2)])];
    const csv = csvRows.map((row) => row.map((cell) => `"${String(cell).replace(/"/g, '""')}"`).join(";")).join("\n");
    const url = URL.createObjectURL(new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `prospeccoes-${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    bridge.notify("Relatório exportado");
  }

  function exportArchivedProspections() {
    if (!archiveProspects.length) {
      bridge.notify("Nenhum registro disponível para exportação.", "error");
      return;
    }
    const probabilityLabels = Object.fromEntries(Object.entries(PROBABILITIES).map(([key, value]) => [key, value.label]));
    const csvRows = [[
      "Cliente", "Nome", "Telefone", "CPF", "Anotacoes", "Probabilidade", "Categorias e etiquetas",
      "Profissional", "Criado em", "Retornou em", "Comprou em", "Valor da compra", "OS", "Atualizado em",
    ], ...archiveProspects.map((row) => [
      row.storeName, row.name, row.phone, row.cpf, row.notes, probabilityLabels[row.probability] || row.probability,
      row.tagValues.join(" | "), row.professionalName, formatDateTime(row.createdAt), formatDateTime(row.returnedAt),
      formatDateTime(row.purchasedAt), row.purchaseAmount ? row.purchaseAmount.toFixed(2).replace(".", ",") : "",
      row.purchaseOrder, formatDateTime(row.updatedAt),
    ])];
    const csv = csvRows.map((row) => row.map((cell) => `"${String(cell ?? "").replace(/"/g, '""')}"`).join(";")).join("\n");
    const url = URL.createObjectURL(new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `historico-prospeccoes-${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    bridge.notify(`${archiveProspects.length} registros exportados.`);
  }

  async function mutate(task, successMessage, { configuration = false, closeDialog = false } = {}) {
    if (loading) return false;
    loading = true;
    try {
      await task();
      await reload({ configuration });
      if (closeDialog) closeDialogs();
      loading = false;
      render();
      if (successMessage) bridge.notify(successMessage);
      return true;
    } catch (error) {
      const message = readableError(error);
      const target = root.querySelector("[data-dialog-message]") || root.querySelector("#prospectionFormMessage");
      if (target) target.textContent = message;
      bridge.notify(message, "error");
      return false;
    } finally {
      loading = false;
    }
  }

  async function saveProspect(form) {
    const data = new FormData(form);
    const name = String(data.get("name") || "").trim();
    if (!name) return;
    const storeId = bridge.profile.role === "store" ? bridge.profile.storeId : selectedStoreId;
    const selectedTags = data.getAll("tags").map(String);
    const wasEditing = Boolean(editingId);
    const saved = await mutate(() => bridge.rpc("lc_upsert_prospection", {
      p_prospection_id: data.get("prospectId") || null,
      p_store_id: storeId,
      p_name: name,
      p_phone: String(data.get("phone") || "").trim() || null,
      p_cpf: String(data.get("cpf") || "").trim() || null,
      p_notes: String(data.get("notes") || "").trim() || null,
      p_probability: String(data.get("probability") || "blue"),
      p_tags: selectedTags,
      p_professional_id: data.get("professionalId") || null,
    }), wasEditing ? "Prospecção atualizada" : "Prospecção registrada");
    if (saved) {
      editingId = "";
      prospectPrefill = null;
      render();
    }
  }

  async function setOutcome(prospectId, values, message) {
    await mutate(() => bridge.rpc("lc_set_prospection_outcome", {
      p_prospection_id: prospectId,
      p_returned: values.returned ?? null,
      p_purchased: values.purchased ?? null,
      p_purchase_amount: values.purchaseAmount ?? null,
      p_purchase_order: values.purchaseOrder ?? null,
    }), message, { closeDialog: values.closeDialog });
  }

  async function savePurchase(form) {
    const data = new FormData(form);
    const amount = parseMoney(data.get("purchaseAmount"));
    const order = String(data.get("purchaseOrder") || "").trim();
    if (amount <= 0 || !order) {
      root.querySelector("[data-dialog-message]").textContent = "Informe um valor maior que zero e o número da OS.";
      return;
    }
    await setOutcome(pendingPurchaseId, { returned: true, purchased: true, purchaseAmount: amount, purchaseOrder: order, closeDialog: true }, "Compra registrada");
  }

  async function deleteProspect(prospectId) {
    await mutate(() => bridge.rpc("lc_delete_prospection", { p_prospection_id: prospectId }), "Prospecção excluída", { closeDialog: true });
    if (editingId === prospectId) editingId = "";
  }

  function validateConfigurationDraft(draft) {
    const payload = buildConfigurationPayload(draft);
    const { settings: nextSettings } = payload;
    if (!Number.isInteger(nextSettings.daily_goal) || nextSettings.daily_goal < 1 || nextSettings.daily_goal > 9999) return "Informe uma meta diária entre 1 e 9.999.";
    if (!Number.isFinite(nextSettings.bonus_minimum) || nextSettings.bonus_minimum < 0) return "A compra mínima não pode ser negativa.";
    if (!Number.isFinite(nextSettings.bonus_amount) || nextSettings.bonus_amount < 0) return "O bônus por compra não pode ser negativo.";
    if (!/^#[0-9a-f]{6}$/i.test(nextSettings.accent_color) || !/^#[0-9a-f]{6}$/i.test(nextSettings.logo_background_color)) return "Escolha cores válidas para a loja e para o fundo da logo.";

    const categoryNames = new Set();
    const tagNames = new Set();
    for (const category of payload.categories) {
      if (!category.name || category.name.length > 60) return "Toda categoria precisa de um nome com até 60 caracteres.";
      const categoryKey = normalize(category.name);
      if (categoryNames.has(categoryKey)) return `A categoria “${category.name}” está repetida.`;
      categoryNames.add(categoryKey);
      for (const tag of category.tags) {
        if (!tag.label || tag.label.length > 60) return "Toda subcategoria precisa de um nome com até 60 caracteres.";
        const tagKey = normalize(tag.label);
        if (tagNames.has(tagKey)) return `A subcategoria “${tag.label}” está repetida.`;
        tagNames.add(tagKey);
      }
    }

    const professionalNames = new Set();
    for (const professional of payload.professionals) {
      if (!professional.name || professional.name.length > 100) return "Todo profissional precisa de um nome com até 100 caracteres.";
      const professionalKey = normalize(professional.name);
      if (professionalNames.has(professionalKey)) return `O profissional “${professional.name}” está repetido.`;
      professionalNames.add(professionalKey);
    }
    return "";
  }

  async function saveConfigurationDraft(storeId, { renderAfter = true, notify = true } = {}) {
    const draft = configurationDraftFor(storeId);
    if (!draft || !draft.dirty) return true;
    const validationMessage = validateConfigurationDraft(draft);
    if (validationMessage) {
      bridge.notify(validationMessage, "error");
      return false;
    }
    if (configurationSession?.saving) return false;
    const payload = buildConfigurationPayload(draft);
    configurationSession.scrollTop = root.querySelector("[data-prospection-configuration-dialog] .admin-settings-panel")?.scrollTop || configurationSession.scrollTop || 0;
    setConfigurationSavingState(true);
    let committed = false;
    try {
      const result = normalizeRpcObject(await bridge.rpc("lc_save_prospection_configuration", {
        p_store_id: storeId,
        p_payload: payload,
      }));
      committed = true;
      if (result.revision) draft.baseRevision = result.revision;
      draft.baseline = JSON.stringify(buildConfigurationPayload(draft));
      draft.dirty = false;

      let reloadError = null;
      for (const delay of [0, 250, 750]) {
        if (delay) await new Promise((resolve) => window.setTimeout(resolve, delay));
        try {
          await reload({ configuration: true });
          reloadError = null;
          break;
        } catch (error) {
          reloadError = error;
        }
      }
      if (reloadError) {
        configurationNeedsRefresh = true;
        if (configurationSession) configurationSession.recoveryRequired = true;
        bridge.notify("As alterações foram salvas, mas a tela não conseguiu atualizar. Feche e reabra a configuração para sincronizar.", "warning");
        return true;
      }
      if (!configurationSession) return true;
      configurationSession.drafts.set(storeId, createConfigurationDraft(storeId));
      if (renderAfter) render();
      if (notify) bridge.notify("Todas as alterações foram salvas.");
      return true;
    } catch (error) {
      const message = readableError(error);
      bridge.notify(committed ? `As alterações foram salvas, mas houve uma falha ao atualizar a tela: ${message}` : message, committed ? "warning" : "error");
      return false;
    } finally {
      if (configurationSession) {
        setConfigurationSavingState(false);
        if (renderAfter && !configurationSession.recoveryRequired) renderConfigurationDialog({ preserveSession: true });
        else configurationSession.drafts.forEach((item) => syncConfigurationDirty(item));
      }
    }
  }

  async function saveAllDirtyConfigurations({ renderAfter = true } = {}) {
    if (!configurationSession) return true;
    const storeIds = [...configurationSession.drafts.values()].filter((draft) => draft.dirty).map((draft) => draft.storeId);
    for (const storeId of storeIds) {
      const saved = await saveConfigurationDraft(storeId, { renderAfter: false, notify: storeIds.length === 1 });
      if (!saved) {
        if (renderAfter && configurationSession) renderConfigurationDialog({ preserveSession: true });
        return false;
      }
    }
    if (storeIds.length > 1) bridge.notify(`Configurações de ${storeIds.length} clientes salvas.`);
    if (renderAfter && configurationSession && !configurationSession.recoveryRequired) {
      render();
      renderConfigurationDialog({ preserveSession: true });
    }
    return true;
  }

  function applyAnalysisFilters(form) {
    const data = new FormData(form);
    const nextStart = String(data.get("startDate") || "");
    const nextEnd = String(data.get("endDate") || "");
    if (nextStart && nextEnd && nextStart > nextEnd) {
      bridge.notify("A data inicial não pode ser posterior à data final.", "error");
      return;
    }
    const nextStoreId = bridge.profile.role === "store" ? bridge.profile.storeId : String(data.get("storeId") || "");
    if (nextStoreId !== analysisStoreId) analysisProfessionalId = "all";
    else analysisProfessionalId = String(data.get("professionalId") || "all");
    analysisDetailProfessionalId = "";
    analysisStartDate = nextStart;
    analysisEndDate = nextEnd;
    analysisPeriod = "custom";
    openAnalysis(nextStoreId);
  }

  function applyBonusFilters(form) {
    const data = new FormData(form);
    const nextStart = String(data.get("startDate") || "");
    const nextEnd = String(data.get("endDate") || "");
    if (nextStart && nextEnd && nextStart > nextEnd) {
      bridge.notify("A data inicial não pode ser posterior à data final.", "error");
      return;
    }
    const nextStoreId = bridge.profile.role === "store" ? bridge.profile.storeId : String(data.get("storeId") || "");
    if (nextStoreId !== bonusStoreId) bonusProfessionalId = "all";
    else bonusProfessionalId = String(data.get("professionalId") || "all");
    bonusStartDate = nextStart;
    bonusEndDate = nextEnd;
    openBonus(nextStoreId);
  }

  function applyDateShortcut(target, shortcut) {
    const range = shortcutRange(shortcut);
    if (target === "attendance") {
      const state = ensureAttendanceListState();
      state.startDate = formatDateInput(range.start);
      state.endDate = formatDateInput(range.end);
      state.loaded = false;
      state.error = "";
      if (state.loading) {
        attendanceListRequest += 1;
        state.loading = false;
      }
      loadAttendanceOpportunities();
      return;
    }
    if (target === "bonus") {
      bonusStartDate = formatDateInput(range.start);
      bonusEndDate = formatDateInput(range.end);
      openBonus(bonusStoreId || selectedStoreId);
      return;
    }
    analysisStartDate = formatDateInput(range.start);
    analysisEndDate = formatDateInput(range.end);
    analysisPeriod = "custom";
    analysisDetailProfessionalId = "";
    openAnalysis(analysisStoreId || selectedStoreId);
  }

  function setAnalysisPeriod(period) {
    if (!["daily", "weekly", "monthly", "yearly"].includes(period)) return;
    analysisPeriod = period;
    const window = analysisPeriodWindow(period);
    analysisStartDate = formatDateInput(window.start);
    analysisEndDate = formatDateInput(addDays(window.end, -1));
    analysisDetailProfessionalId = "";
    openAnalysis(analysisStoreId || selectedStoreId);
  }

  function addTag(form) {
    const draft = configurationDraftFor(form.dataset.storeId);
    const category = draft?.categories.find((item) => item.id === form.dataset.categoryId);
    const label = String(category?.pendingTagName || new FormData(form).get("label") || "").trim();
    if (!draft || !category || !label) return;
    const clientKey = category.pendingTagClientKey || createConfigurationClientKey("tag");
    category.tags.push({ id: clientKey, clientKey, storeId: draft.storeId, categoryId: category.id, label, sortOrder: category.tags.length * 10 + 10 });
    category.pendingTagName = "";
    category.pendingTagClientKey = createConfigurationClientKey("tag");
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
  }

  function saveCategory(form) {
    const draft = configurationDraftFor(form.dataset.storeId);
    const name = String(draft?.pendingCategoryName || new FormData(form).get("name") || "").trim();
    if (!draft || !name) return;
    const clientKey = draft.pendingCategoryClientKey || createConfigurationClientKey("category");
    draft.categories.push({ id: clientKey, clientKey, storeId: draft.storeId, name, sortOrder: draft.categories.length * 10 + 10, tags: [], pendingTagName: "", pendingTagClientKey: createConfigurationClientKey("tag") });
    draft.pendingCategoryName = "";
    draft.pendingCategoryClientKey = createConfigurationClientKey("category");
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
  }

  function moveCategory(storeId, categoryId, direction) {
    const draft = configurationDraftFor(storeId);
    if (!draft) return;
    const index = draft.categories.findIndex((row) => row.id === categoryId);
    const nextIndex = direction === "up" ? index - 1 : index + 1;
    if (index < 0 || nextIndex < 0 || nextIndex >= draft.categories.length) return;
    [draft.categories[index], draft.categories[nextIndex]] = [draft.categories[nextIndex], draft.categories[index]];
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
  }

  function moveTag(storeId, categoryId, tagId, direction) {
    const draft = configurationDraftFor(storeId);
    const category = draft?.categories.find((row) => row.id === categoryId);
    if (!draft || !category) return;
    const index = category.tags.findIndex((row) => row.id === tagId);
    const nextIndex = direction === "up" ? index - 1 : index + 1;
    if (index < 0 || nextIndex < 0 || nextIndex >= category.tags.length) return;
    [category.tags[index], category.tags[nextIndex]] = [category.tags[nextIndex], category.tags[index]];
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
  }

  function deleteCategory(storeId, categoryId) {
    const draft = configurationDraftFor(storeId);
    const category = draft?.categories.find((row) => row.id === categoryId);
    if (!draft || !category) return;
    if (isPersistedConfigurationId(category.id)) draft.deletedCategoryIds.push(category.id);
    category.tags.forEach((tag) => {
      if (isPersistedConfigurationId(tag.id)) draft.deletedTagIds.push(tag.id);
    });
    draft.categories = draft.categories.filter((row) => row.id !== category.id);
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
    bridge.notify("A categoria será excluída quando você salvar as alterações.");
  }

  function deleteTag(storeId, categoryId, tagId) {
    const draft = configurationDraftFor(storeId);
    const category = draft?.categories.find((row) => row.id === categoryId);
    const tag = category?.tags.find((row) => row.id === tagId);
    if (!draft || !category || !tag) return;
    if (isPersistedConfigurationId(tag.id)) draft.deletedTagIds.push(tag.id);
    category.tags = category.tags.filter((row) => row.id !== tag.id);
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
    bridge.notify("A subcategoria será excluída quando você salvar as alterações.");
  }

  function addProfessional(form) {
    const draft = configurationDraftFor(form.dataset.storeId);
    const name = String(draft?.pendingProfessionalName || new FormData(form).get("name") || "").trim();
    if (!draft || !name) return;
    const clientKey = draft.pendingProfessionalClientKey || createConfigurationClientKey("professional");
    draft.professionals.push({ id: clientKey, clientKey, storeId: draft.storeId, name, active: true });
    draft.pendingProfessionalName = "";
    draft.pendingProfessionalClientKey = createConfigurationClientKey("professional");
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
  }

  function deleteProfessional(storeId, professionalId) {
    const draft = configurationDraftFor(storeId);
    const index = draft?.professionals.findIndex((professional) => professional.id === professionalId) ?? -1;
    if (!draft || index < 0) return;
    const [professional] = draft.professionals.splice(index, 1);
    const persisted = isPersistedConfigurationId(professional.id);
    if (persisted) {
      if (!draft.deletedProfessionalIds.includes(professional.id)) draft.deletedProfessionalIds.push(professional.id);
    }
    draft.removedProfessionals.push({ professional, index, persisted });
    bridge.notify(persisted
      ? `O cadastro de ${professional.name} será excluído quando você salvar. O histórico será preservado.`
      : `A criação de ${professional.name} foi removida do rascunho.`);
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
    root.querySelector(`[data-prospection-action="undo-delete-professional"][data-professional-id="${CSS.escape(professional.id)}"]`)?.focus();
  }

  function undoDeleteProfessional(storeId, professionalId) {
    const draft = configurationDraftFor(storeId);
    const removalIndex = draft?.removedProfessionals.findIndex(({ professional }) => professional.id === professionalId) ?? -1;
    if (!draft || removalIndex < 0) return;
    const [{ professional, index }] = draft.removedProfessionals.splice(removalIndex, 1);
    draft.deletedProfessionalIds = draft.deletedProfessionalIds.filter((id) => id !== professional.id);
    draft.professionals.splice(Math.min(index, draft.professionals.length), 0, professional);
    syncConfigurationDirty(draft);
    renderConfigurationDialog({ preserveSession: true });
    root.querySelector(`[data-prospection-action="delete-professional"][data-professional-id="${CSS.escape(professional.id)}"]`)?.focus();
    bridge.notify(`${professional.name} voltou para a equipe.`);
  }

  function updateConfigurationDraftFromInput(input) {
    const row = input.closest("[data-config-store]");
    const draft = configurationDraftFor(row?.dataset.configStore || "");
    if (!draft) return;
    if (input.closest("[data-prospection-category-form]")) {
      draft.pendingCategoryName = input.value;
    } else if (input.closest("[data-prospection-tag-form]")) {
      const categoryId = input.closest("[data-prospection-tag-form]")?.dataset.categoryId;
      const category = draft.categories.find((item) => item.id === categoryId);
      if (category) category.pendingTagName = input.value;
    } else if (input.closest("[data-prospection-professional-form]")) {
      draft.pendingProfessionalName = input.value;
    } else if (input.dataset.configSetting) {
      const field = input.dataset.configSetting;
      draft.settings[field] = input.type === "number" ? (input.value === "" ? "" : Number(input.value)) : input.value;
    } else if (input.matches("[data-config-category-name]")) {
      const categoryId = input.closest("[data-category-id]")?.dataset.categoryId;
      const category = draft.categories.find((item) => item.id === categoryId);
      if (category) category.name = input.value;
    } else if (input.matches("[data-config-tag-label]")) {
      const tagId = input.closest("[data-tag-id]")?.dataset.tagId;
      draft.categories.some((category) => {
        const tag = category.tags.find((item) => item.id === tagId);
        if (!tag) return false;
        tag.label = input.value;
        return true;
      });
    } else if (input.matches("[data-config-professional-name]")) {
      const professionalId = input.closest("[data-professional-id]")?.dataset.professionalId;
      const professional = draft.professionals.find((item) => item.id === professionalId);
      if (professional) professional.name = input.value;
    } else if (input.matches("[data-config-professional-active]")) {
      const professionalRow = input.closest("[data-professional-id]");
      const professional = draft.professionals.find((item) => item.id === professionalRow?.dataset.professionalId);
      if (professional) professional.active = input.checked;
      const status = professionalRow?.querySelector("[data-professional-status]");
      if (status) status.textContent = input.checked ? "Ativo" : "Inativo";
    } else return;
    syncConfigurationDirty(draft);
  }

  root.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.target;
    if (form.id === "prospectForm") saveProspect(form);
    else if (form.id === "prospectionAttendanceFilters") applyAttendanceFilters(form);
    else if (form.id === "prospectionPurchaseForm") savePurchase(form);
    else if (form.id === "prospectionAnalysisFilters") applyAnalysisFilters(form);
    else if (form.id === "prospectionBonusFilters") applyBonusFilters(form);
    else if (form.matches("[data-prospection-category-form]")) saveCategory(form);
    else if (form.matches("[data-prospection-tag-form]")) addTag(form);
    else if (form.matches("[data-prospection-professional-form]")) addProfessional(form);
  });

  root.addEventListener("input", (event) => {
    if (event.target.closest("[data-config-store]")) updateConfigurationDraftFromInput(event.target);
    if (event.target.matches("[data-prospection-search]")) {
      listSearch = event.target.value;
      renderRecordList();
    }
    if (event.target.name === "phone") event.target.value = formatPhone(event.target.value);
    if (event.target.name === "cpf") event.target.value = formatCpf(event.target.value);
    if (event.target.type === "color" && event.target.closest(".prospection-color-control")) {
      const control = event.target.closest(".prospection-color-control");
      const code = control.querySelector("code");
      if (code) code.textContent = event.target.value.toUpperCase();
      const configRow = event.target.closest("[data-config-store]");
      if (event.target.name === "logoBackgroundColor") configRow?.querySelector(".prospection-account-icon.has-image")?.style.setProperty("--logo-background", event.target.value);
      if (event.target.name === "accentColor") configRow?.style.setProperty("--account-color", event.target.value);
    }
  });

  root.addEventListener("change", (event) => {
    if (event.target.closest("[data-config-store]")) updateConfigurationDraftFromInput(event.target);
    if (event.target.matches("[data-prospection-import-file]")) {
      handleImportFile(event.target);
      return;
    }
    if (event.target.matches("[data-prospection-import-consent]")) {
      const confirmButton = root.querySelector('[data-prospection-action="confirm-import"]');
      if (confirmButton) confirmButton.disabled = !event.target.checked;
      return;
    }
    if (event.target.matches("[data-prospection-period]")) {
      dashboardPeriod = event.target.value;
      filtersOpen = false;
      closeDialogs();
      render();
    }
    if (event.target.matches("[data-prospection-status]")) {
      listStatus = event.target.value;
      filtersOpen = false;
      render();
    }
  });

  root.addEventListener("dragover", (event) => {
    const dropzone = event.target.closest(".prospection-import-dropzone");
    if (!dropzone) return;
    event.preventDefault();
    dropzone.classList.add("is-dragging");
  });

  root.addEventListener("dragleave", (event) => {
    const dropzone = event.target.closest(".prospection-import-dropzone");
    if (!dropzone || dropzone.contains(event.relatedTarget)) return;
    dropzone.classList.remove("is-dragging");
  });

  root.addEventListener("drop", (event) => {
    const dropzone = event.target.closest(".prospection-import-dropzone");
    if (!dropzone) return;
    event.preventDefault();
    dropzone.classList.remove("is-dragging");
    const input = dropzone.querySelector("[data-prospection-import-file]");
    const file = event.dataTransfer?.files?.[0];
    if (input && file) handleImportFile(input, file);
  });

  root.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-prospection-action]");
    if (!button) {
      if (event.target.classList.contains("prospection-unsaved-backdrop")) {
        finishConfigurationTransition(false);
      } else if (event.target.classList.contains("prospection-dialog-backdrop")) {
        if (importDraft?.status === "importing") bridge.notify("Aguarde a importação terminar.");
        else if (event.target.matches("[data-prospection-configuration-dialog]")) requestConfigurationTransition(() => forceCloseDialogs());
        else closeDialogs();
      }
      else if (filtersOpen && !event.target.closest(".filter-menu")) { filtersOpen = false; render(); }
      return;
    }
    const action = button.dataset.prospectionAction;
    const prospectId = button.dataset.prospectId || "";
    if (action === "close-dialog") {
      if (importDraft?.status === "importing") bridge.notify("Aguarde a importação terminar.");
      else if (button.closest("[data-prospection-configuration-dialog]")) requestConfigurationTransition(() => forceCloseDialogs());
      else closeDialogs();
    }
    else if (action === "toggle-theme") { document.querySelector("#themeToggle")?.click(); render(); }
    else if (action === "logout") requestConfigurationTransition(() => document.querySelector("#logoutButton")?.click());
    else if (action === "open-leads") await bridge.openLeadsForStore?.(button.dataset.storeId || "");
    else if (action === "manage-access") bridge.openStoreAccess?.(button.dataset.storeId || "");
    else if (action === "export-archive") exportArchivedProspections();
    else if (action === "toggle-filters") { filtersOpen = !filtersOpen; render(); }
    else if (action === "set-list-mode") setListMode(button.dataset.listMode || "records");
    else if (action === "retry-attendances") await loadAttendanceOpportunities();
    else if (action === "load-more-attendances") await loadAttendanceOpportunities({ append: true });
    else if (action === "prefill-attendance") prefillProspectFromAttendance(button.dataset.attendanceId || "");
    else if (action === "review-duplicate-prospects") reviewDuplicateProspects(button.dataset.attendanceId || "");
    else if (action === "clear-form") { editingId = ""; prospectPrefill = null; render(); }
    else if (action === "select-agency") { selectedAgencyId = button.dataset.accountId; render(); }
    else if (action === "clear-agency") { selectedAgencyId = ""; render(); }
    else if (action === "select-store") {
      const storeId = button.dataset.accountId;
      if (!isLicensedStore(storeId)) bridge.notify("Este cliente possui somente Leads. Libere uma licença de Prospecções primeiro.", "error");
      else {
        selectedStoreId = storeId;
        editingId = "";
        prospectPrefill = null;
        listMode = "records";
        listSearch = "";
        listStatus = "all";
        attendanceListRequest += 1;
        attendanceListState = createAttendanceListState(storeId);
        render();
      }
    }
    else if (action === "back-dashboard") {
      selectedStoreId = "";
      editingId = "";
      prospectPrefill = null;
      listMode = "records";
      attendanceListRequest += 1;
      attendanceListState = createAttendanceListState("");
      render();
    }
    else if (action === "open-store-analysis") openAnalysis(button.dataset.storeId);
    else if (action === "open-analysis") openAnalysis();
    else if (action === "open-store-bonus") openBonus(button.dataset.storeId);
    else if (action === "open-bonus") openBonus();
    else if (action === "open-configuration") openConfiguration(button.dataset.storeId || "");
    else if (action === "open-import") requestConfigurationTransition(() => openImportDialog(button.dataset.storeId || ""));
    else if (action === "return-configuration") openConfiguration(button.dataset.storeId || "");
    else if (action === "confirm-import") await executeBackupImport();
    else if (action === "save-configuration") await saveConfigurationDraft(button.dataset.storeId || "");
    else if (action === "cancel-configuration-exit") finishConfigurationTransition(false);
    else if (action === "discard-configuration-exit") {
      configurationSession = null;
      finishConfigurationTransition(true);
    }
    else if (action === "save-configuration-exit") {
      const exitButton = button;
      exitButton.disabled = true;
      exitButton.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin"></i>Salvando…';
      const saved = await saveAllDirtyConfigurations({ renderAfter: false });
      if (saved) {
        render();
        configurationSession = null;
        finishConfigurationTransition(true);
      } else {
        exitButton.disabled = false;
        exitButton.innerHTML = '<i class="fa-solid fa-check"></i>Salvar e sair';
      }
    }
    else if (action === "open-reports") openReports(button.dataset.storeId || "");
    else if (action === "apply-date-shortcut") applyDateShortcut(button.dataset.shortcutTarget || "analysis", button.dataset.shortcutValue || "this-month");
    else if (action === "set-analysis-period") setAnalysisPeriod(button.dataset.analysisPeriod || "monthly");
    else if (action === "show-professional-records") {
      analysisDetailProfessionalId = button.dataset.professionalId || "";
      openAnalysis(analysisStoreId || selectedStoreId);
    }
    else if (action === "hide-professional-records") {
      analysisDetailProfessionalId = "";
      openAnalysis(analysisStoreId || selectedStoreId);
    }
    else if (action === "export-report") exportReport(button.dataset.storeId || "");
    else if (action === "edit-prospect") { editingId = prospectId; prospectPrefill = null; render(); root.querySelector("#prospectForm")?.scrollIntoView({ behavior: "smooth", block: "start" }); }
    else if (action === "cancel-edit") { editingId = ""; prospectPrefill = null; render(); }
    else if (action === "toggle-returned") await setOutcome(prospectId, { returned: button.dataset.nextValue === "true" }, button.dataset.nextValue === "true" ? "Volta registrada" : "Volta removida");
    else if (action === "open-purchase") openPurchaseDialog(prospectId);
    else if (action === "unmark-purchased") openConfirmDialog({ title: "Remover esta compra?", message: "O valor, a OS e a bonificação vinculada serão removidos.", action: "confirm-unmark-purchased", id: prospectId });
    else if (action === "confirm-unmark-purchased") await setOutcome(prospectId, { purchased: false, closeDialog: true }, "Compra removida");
    else if (action === "confirm-delete") openConfirmDialog({ title: "Excluir esta prospecção?", message: "O registro e seus resultados serão removidos definitivamente.", action: "delete-prospect", id: prospectId });
    else if (action === "delete-prospect") await deleteProspect(prospectId);
    else if (action === "move-category") moveCategory(button.dataset.storeId, button.dataset.categoryId, button.dataset.direction);
    else if (action === "delete-category") deleteCategory(button.dataset.storeId, button.dataset.categoryId);
    else if (action === "move-tag") moveTag(button.dataset.storeId, button.dataset.categoryId, button.dataset.tagId, button.dataset.direction);
    else if (action === "delete-tag") deleteTag(button.dataset.storeId, button.dataset.categoryId, button.dataset.tagId);
    else if (action === "delete-professional") deleteProfessional(button.dataset.storeId, button.dataset.professionalId);
    else if (action === "undo-delete-professional") undoDeleteProfessional(button.dataset.storeId, button.dataset.professionalId);
    else if (action === "calendar-prev" || action === "calendar-next") {
      calendarDate = addMonths(calendarDate, action === "calendar-prev" ? -1 : 1);
      openAnalysis(analysisStoreId || selectedStoreId);
    }
  });

  document.addEventListener("keydown", (event) => {
    const unsavedDialog = active ? root.querySelector(".prospection-unsaved-dialog") : null;
    if (unsavedDialog && event.key === "Tab") {
      const focusable = [...unsavedDialog.querySelectorAll("button:not([disabled])")];
      if (!focusable.length) {
        event.preventDefault();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    } else if (active && event.key === "Escape" && root.querySelector(".prospection-unsaved-backdrop")) {
      finishConfigurationTransition(false);
    } else if (active && event.key === "Escape" && root.querySelector(".prospection-dialog-backdrop")) {
      if (importDraft?.status === "importing") bridge.notify("Aguarde a importação terminar.");
      else if (root.querySelector("[data-prospection-configuration-dialog]")) requestConfigurationTransition(() => forceCloseDialogs());
      else closeDialogs();
    }
  });

  window.addEventListener("beforeunload", (event) => {
    if (!active || !hasUnsavedConfiguration()) return;
    event.preventDefault();
    event.returnValue = "";
  });

  window.addEventListener("resize", scheduleWorkspaceSizing);

  window.ProspectionsModule = {
    activate,
    deactivate,
    requestDeactivate,
    refreshContext,
    renderFatalError,
  };
})();
