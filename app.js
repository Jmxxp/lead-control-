const SUPABASE_URL = "https://nuuebvpsfcgsgkefecab.supabase.co";
const SUPABASE_ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im51dWVidnBzZmNnc2drZWZlY2FiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODExOTQ5ODMsImV4cCI6MjA5Njc3MDk4M30.6PxIIOP2oQvlbUP87ab79VsXj5e4NCNhjUgnECIN5pA";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const labels = {
  channel: "Canal",
  campaign: "Campanha",
  conversationStart: "Início da conversa",
  conclusion: "Conclusão",
  visited: "Visitou a loja",
  bought: "Comprou",
};

const optionGroups = Object.keys(labels);
const nativeYesNoOptions = ["Sim", "Não"];
const fixedOptionGroups = new Set(["visited", "bought"]);
let options = createEmptyOptions();

let session = null;
let currentProfile = null;
let activeStoreContext = null;
let stores = [];
let leads = [];
let realtimeChannel = null;
let realtimeReloadTimer = null;
const realtimePendingTables = new Set();
let pendingUnsavedAction = null;
const dirtyOptionKeys = new Set();
let selectedValues = {
  channel: "",
  campaign: "",
  conversationStart: "",
  conclusion: "",
  visited: "",
  bought: "",
};

const authScreen = document.querySelector("#authScreen");
const appView = document.querySelector("#appView");
const adminView = document.querySelector("#adminView");
const storeView = document.querySelector("#storeView");
const sessionRole = document.querySelector("#sessionRole");
const logoutButton = document.querySelector("#logoutButton");
const backAdminButton = document.querySelector("#backAdminButton");

const loginForm = document.querySelector("#loginForm");
const signupForm = document.querySelector("#signupForm");
const authMessage = document.querySelector("#authMessage");
const authTabs = document.querySelectorAll("[data-auth-tab]");
const passwordToggleButtons = document.querySelectorAll("[data-toggle-password]");
const loginNick = document.querySelector("#loginNick");
const loginPassword = document.querySelector("#loginPassword");
const signupName = document.querySelector("#signupName");
const signupNick = document.querySelector("#signupNick");
const signupPassword = document.querySelector("#signupPassword");

const storeForm = document.querySelector("#storeForm");
const storeName = document.querySelector("#storeName");
const storeNick = document.querySelector("#storeNick");
const storePassword = document.querySelector("#storePassword");
const storeMessage = document.querySelector("#storeMessage");
const storeEmptyState = document.querySelector("#storeEmptyState");
const storeList = document.querySelector("#storeList");
const adminOptionsList = document.querySelector("#adminOptionsList");
const adminOptionsMessage = document.querySelector("#adminOptionsMessage");
const analyticsToggle = document.querySelector("#analyticsToggle");
const analyticsToggleLabel = document.querySelector("#analyticsToggleLabel");
const analyticsContent = document.querySelector("#analyticsContent");
const analyticsStoreFilter = document.querySelector("#analyticsStoreFilter");
const analyticsDateModeButtons = document.querySelectorAll("[data-analytics-date-mode]");
const analyticsSingleDate = document.querySelector("#analyticsSingleDate");
const analyticsStartDate = document.querySelector("#analyticsStartDate");
const analyticsEndDate = document.querySelector("#analyticsEndDate");
const analyticsSingleDateField = document.querySelector(".analytics-single-date");
const analyticsRangeDateFields = document.querySelectorAll(".analytics-range-date");
const analyticsQuickRangeButtons = document.querySelectorAll("[data-analytics-range]");

const form = document.querySelector("#leadForm");
const formTitle = document.querySelector("#formTitle");
const submitButton = document.querySelector("#submitButton");
const formMessage = document.querySelector("#formMessage");
const clearFormButton = document.querySelector("#clearForm");
const cancelEditButton = document.querySelector("#cancelEdit");
const toggleOptionsEditButton = document.querySelector("#toggleOptionsEdit");
const editingIdInput = document.querySelector("#editingId");
const nameInput = document.querySelector("#name");
const phoneInput = document.querySelector("#phone");
const searchInput = document.querySelector("#search");
const filtersPanel = document.querySelector("#filtersPanel");
const toggleFiltersButton = document.querySelector("#toggleFilters");
const channelFilter = document.querySelector("#channelFilter");
const campaignFilter = document.querySelector("#campaignFilter");
const conversationStartFilter = document.querySelector("#conversationStartFilter");
const conclusionFilter = document.querySelector("#conclusionFilter");
const visitedFilter = document.querySelector("#visitedFilter");
const boughtFilter = document.querySelector("#boughtFilter");
const startDateFilter = document.querySelector("#startDateFilter");
const endDateFilter = document.querySelector("#endDateFilter");
const clearFiltersButton = document.querySelector("#clearFilters");
const emptyState = document.querySelector("#emptyState");
const leadList = document.querySelector("#leadList");
const storeOptionsPanel = document.querySelector("#storeOptionsPanel");
const storeOptionsList = document.querySelector("#storeOptionsList");
const storeOptionsMessage = document.querySelector("#storeOptionsMessage");
const unsavedOptionsModal = document.querySelector("#unsavedOptionsModal");
const unsavedCancel = document.querySelector("#unsavedCancel");
const unsavedDiscard = document.querySelector("#unsavedDiscard");
const unsavedSave = document.querySelector("#unsavedSave");

document.addEventListener("DOMContentLoaded", init);

async function init() {
  setTodayLabel();
  bindEvents();
  await restoreSession();
}

function bindEvents() {
  authTabs.forEach((tab) => {
    tab.addEventListener("click", () => setAuthTab(tab.dataset.authTab));
  });

  passwordToggleButtons.forEach((button) => {
    button.addEventListener("click", () => togglePassword(button));
  });

  loginForm.addEventListener("submit", handleLogin);
  signupForm.addEventListener("submit", handleAdminSignup);
  logoutButton.addEventListener("click", () => guardUnsavedOptions(handleLogout));
  backAdminButton.addEventListener("click", () => guardUnsavedOptions(returnToAdmin));
  storeForm.addEventListener("submit", handleCreateStore);
  adminOptionsList.addEventListener("click", handleOptionsEditorClick);
  storeOptionsList.addEventListener("click", handleOptionsEditorClick);
  adminOptionsList.addEventListener("input", handleOptionsEditorInput);
  storeOptionsList.addEventListener("input", handleOptionsEditorInput);
  unsavedCancel.addEventListener("click", closeUnsavedOptionsModal);
  unsavedDiscard.addEventListener("click", discardUnsavedOptionsAndContinue);
  unsavedSave.addEventListener("click", saveUnsavedOptionsAndContinue);
  analyticsToggle.addEventListener("click", toggleAnalytics);
  analyticsStoreFilter.addEventListener("input", renderAdminAnalytics);
  [analyticsSingleDate, analyticsStartDate, analyticsEndDate].forEach((element) => {
    element.addEventListener("input", renderAdminAnalytics);
  });
  analyticsDateModeButtons.forEach((button) => {
    button.addEventListener("click", () => setAnalyticsDateMode(button.dataset.analyticsDateMode));
  });
  analyticsQuickRangeButtons.forEach((button) => {
    button.addEventListener("click", () => setAnalyticsQuickRange(button.dataset.analyticsRange));
  });

  form.addEventListener("submit", handleLeadSubmit);
  clearFormButton.addEventListener("click", resetLeadForm);
  cancelEditButton.addEventListener("click", resetLeadForm);
  toggleOptionsEditButton.addEventListener("click", () => {
    if (!storeOptionsPanel.hidden) {
      guardUnsavedOptions(toggleStoreOptionsMode);
      return;
    }

    toggleStoreOptionsMode();
  });
  phoneInput.addEventListener("input", () => {
    phoneInput.value = formatPhone(phoneInput.value);
  });

  [
    searchInput,
    channelFilter,
    campaignFilter,
    conversationStartFilter,
    conclusionFilter,
    visitedFilter,
    boughtFilter,
    startDateFilter,
    endDateFilter,
  ].forEach((element) => {
    element.addEventListener("input", renderLeadList);
  });

  toggleFiltersButton.addEventListener("click", toggleFilters);
  clearFiltersButton.addEventListener("click", clearFilters);

  leadList.addEventListener("click", (event) => {
    const actionButton = event.target.closest("[data-action]");
    if (!actionButton) return;

    if (actionButton.dataset.action === "edit") guardUnsavedOptions(() => editLead(actionButton.dataset.id));
    if (actionButton.dataset.action === "delete") deleteLead(actionButton.dataset.id);
  });

  storeList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-store-login]");
    if (!button) return;

    guardUnsavedOptions(() => enterStoreContext(button.dataset.storeLogin));
  });

  window.addEventListener("beforeunload", (event) => {
    if (!hasUnsavedOptions()) return;
    event.preventDefault();
    event.returnValue = "";
  });
}

async function restoreSession() {
  const { data, error } = await supabaseClient.auth.getSession();
  if (error) {
    showAuthMessage("Não foi possível carregar a sessão.");
    return;
  }

  if (!data.session) {
    showAuth();
    return;
  }

  session = data.session;
  currentProfile = await loadCurrentProfile();

  if (!currentProfile) {
    showAuth();
    return;
  }

  await openSession(data.session);
}

async function openSession(activeSession) {
  session = activeSession;
  currentProfile = currentProfile || (await loadCurrentProfile());
  if (!currentProfile) {
    showAuth();
    showAuthMessage("Faça login com seu nick.");
    return;
  }
  authScreen.hidden = true;
  appView.hidden = false;

  if (currentProfile.role === "admin") {
    activeStoreContext = null;
    sessionRole.textContent = `Admin · ${currentProfile.username}`;
    backAdminButton.hidden = true;
    adminView.hidden = false;
    storeView.hidden = true;
    await loadOptions();
    await loadAdminDashboard();
    setupRealtimeSubscriptions();
    return;
  }

  sessionRole.textContent = `Loja · ${currentProfile.store_name || currentProfile.username}`;
  backAdminButton.hidden = true;
  adminView.hidden = true;
  storeView.hidden = false;
  await loadOptions();
  await loadLeads();
  setupRealtimeSubscriptions();
}

async function ensureAnonymousSession() {
  const { data: currentData } = await supabaseClient.auth.getSession();
  if (currentData.session) {
    const { data: userData, error: userError } = await supabaseClient.auth.getUser();

    if (!userError && userData.user) {
      session = currentData.session;
      return currentData.session;
    }

    await supabaseClient.auth.signOut();
  }

  const { data, error } = await supabaseClient.auth.signInAnonymously();
  if (error || !data.session) {
    showAuthMessage("Habilite Anonymous sign-ins no Supabase Auth.");
    return null;
  }

  session = data.session;
  return data.session;
}

async function loadCurrentProfile() {
  const { data, error } = await supabaseClient.rpc("app_current_profile");

  if (error) return null;

  return data;
}

async function loadOptions() {
  const storeId = getOptionsStoreId();
  let loadedOptions = await loadOptionsRows(storeId);

  if (storeId && !hasCustomOptionRows(loadedOptions)) {
    loadedOptions = await loadOptionsRows(null);
  }

  options = normalizeOptions(loadedOptions);
  renderChoiceButtons();
  renderFilters();
  renderOptionsEditors();
}

async function saveCurrentOptions(messageTarget) {
  const storeId = getOptionsStoreId();
  const normalizedOptions = normalizeOptions(options);
  const deleteQuery = supabaseClient.from("lead_options").delete();
  const { error: deleteError } = storeId
    ? await deleteQuery.eq("store_id", storeId)
    : await deleteQuery.is("store_id", null);

  if (deleteError) {
    showOptionsMessage(messageTarget, "Não foi possível atualizar as opções no banco.");
    return false;
  }

  const rows = buildOptionRows(normalizedOptions, storeId);

  if (rows.length) {
    const { error: insertError } = await supabaseClient.from("lead_options").insert(rows);

    if (insertError) {
      showOptionsMessage(messageTarget, "Não foi possível salvar as opções no banco.");
      return false;
    }
  }

  options = normalizedOptions;
  dirtyOptionKeys.clear();
  renderChoiceButtons();
  renderFilters();
  renderOptionsEditors();
  showOptionsMessage(messageTarget, "Opções salvas no banco de dados.", "success");
  return true;
}

function showAuth() {
  authScreen.hidden = false;
  appView.hidden = true;
  adminView.hidden = true;
  storeView.hidden = true;
}

function setAuthTab(tabName) {
  const isLogin = tabName === "login";
  loginForm.hidden = !isLogin;
  signupForm.hidden = isLogin;
  clearAuthMessage();

  authTabs.forEach((tab) => {
    tab.classList.toggle("is-active", tab.dataset.authTab === tabName);
  });
}

async function handleLogin(event) {
  event.preventDefault();
  clearAuthMessage();

  if (!normalizeNick(loginNick.value)) {
    showAuthMessage("Digite um nick válido.");
    return;
  }

  const anonymousSession = await ensureAnonymousSession();
  if (!anonymousSession) {
    showAuthMessage("Não foi possível iniciar a sessão.");
    return;
  }

  const { data, error } = await supabaseClient.rpc("app_login", {
    login_username: normalizeNick(loginNick.value),
    login_password: loginPassword.value,
  });

  if (error) {
    showAuthMessage(formatAuthError(error));
    return;
  }

  currentProfile = data;
  await openSession(anonymousSession);
}

async function handleAdminSignup(event) {
  event.preventDefault();
  clearAuthMessage();

  if (!normalizeNick(signupNick.value)) {
    showAuthMessage("Digite um nick válido.");
    return;
  }

  const anonymousSession = await ensureAnonymousSession();
  if (!anonymousSession) {
    showAuthMessage("Não foi possível iniciar a sessão.");
    return;
  }

  const { data, error } = await supabaseClient.rpc("app_create_admin", {
    admin_name: signupName.value.trim(),
    admin_username: normalizeNick(signupNick.value),
    admin_password: signupPassword.value,
  });

  if (error) {
    showAuthMessage(formatAuthError(error));
    return;
  }

  signupForm.reset();
  currentProfile = data;
  await openSession(anonymousSession);
}

async function handleLogout() {
  teardownRealtimeSubscriptions();
  await supabaseClient.rpc("app_logout");
  await supabaseClient.auth.signOut();
  session = null;
  currentProfile = null;
  activeStoreContext = null;
  stores = [];
  leads = [];
  resetLeadForm();
  showAuth();
}

function setupRealtimeSubscriptions() {
  teardownRealtimeSubscriptions();

  realtimeChannel = supabaseClient
    .channel("lead-control-db-changes")
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "stores" },
      () => scheduleRealtimeReload("stores"),
    )
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "leads" },
      () => scheduleRealtimeReload("leads"),
    )
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "lead_options" },
      () => scheduleRealtimeReload("lead_options"),
    )
    .subscribe();
}

function teardownRealtimeSubscriptions() {
  if (realtimeReloadTimer) {
    clearTimeout(realtimeReloadTimer);
    realtimeReloadTimer = null;
  }
  realtimePendingTables.clear();

  if (realtimeChannel) {
    supabaseClient.removeChannel(realtimeChannel);
    realtimeChannel = null;
  }
}

function scheduleRealtimeReload(table) {
  if (!currentProfile) return;

  realtimePendingTables.add(table);
  if (realtimeReloadTimer) clearTimeout(realtimeReloadTimer);
  realtimeReloadTimer = setTimeout(() => {
    realtimeReloadTimer = null;
    const tables = [...realtimePendingTables];
    realtimePendingTables.clear();
    refreshRealtimeData(tables);
  }, 250);
}

async function refreshRealtimeData(tables) {
  if (tables.includes("lead_options")) {
    if (!hasUnsavedOptions()) {
      await loadOptions();
    }
  }

  if (currentProfile.role === "admin" && !activeStoreContext) {
    if (tables.includes("stores")) {
      await loadStores();
      renderAnalyticsControls();
    }

    if (tables.includes("leads")) {
      await loadAdminLeads();
      renderAdminStats();
    }
    return;
  }

  if (tables.includes("leads")) {
    await loadLeads();
  }
}

async function loadAdminDashboard() {
  await Promise.all([loadStores(), loadAdminLeads()]);
  renderAdminStats();
}

async function loadStores() {
  const { data, error } = await supabaseClient
    .from("stores")
    .select("id,name,username,created_at")
    .order("created_at", { ascending: false });

  if (error) {
    showStoreMessage("Não foi possível carregar as lojas.");
    return;
  }

  stores = data || [];
  renderStoreList();
}

async function loadAdminLeads() {
  const { data, error } = await supabaseClient
    .from("leads")
    .select(
      "id,store_id,name,phone,channel,campaign,conversation_start,conclusion,visited,bought,created_at,updated_at,stores(name)",
    )
    .order("created_at", { ascending: false });

  leads = error ? [] : (data || []).map(mapLeadFromDb);
}

async function handleCreateStore(event) {
  event.preventDefault();
  clearStoreMessage();

  const name = storeName.value.trim();
  const username = normalizeNick(storeNick.value);

  if (!name) {
    showStoreMessage("Digite o nome da loja.");
    return;
  }

  if (!username) {
    showStoreMessage("Digite um identificador válido para a loja.");
    return;
  }

  const { error } = await supabaseClient.rpc("app_create_store", {
    store_name: name,
    store_username: username,
    store_password: storePassword.value,
  });

  if (error) {
    showStoreMessage(
      error.message?.includes("duplicate") || error.message?.includes("existe")
        ? "Já existe uma loja com esse nick."
        : "Não foi possível criar a loja.",
    );
    return;
  }

  storeForm.reset();
  showStoreMessage("Loja e login salvos no banco de dados.", "success");
  await loadAdminDashboard();
}

function renderAdminStats() {
  const bought = leads.filter((lead) => isPositiveAnswer(lead.bought)).length;
  const conversion = leads.length ? Math.round((bought / leads.length) * 100) : 0;

  document.querySelector("#totalStores").textContent = stores.length;
  document.querySelector("#adminTotalLeads").textContent = leads.length;
  document.querySelector("#adminSalesCount").textContent = bought;
  document.querySelector("#adminConversionRate").textContent = `${conversion}%`;
  document.querySelector("#todayCount").textContent = pluralize(leads.length, "lead");
  renderAnalyticsControls();
  renderAdminAnalytics();
}

function toggleAnalytics() {
  const isOpening = analyticsContent.hidden;
  analyticsContent.hidden = !isOpening;
  analyticsToggle.setAttribute("aria-expanded", String(isOpening));
  analyticsToggleLabel.textContent = isOpening ? "Ocultar análise" : "Mostrar análise";
}

function renderAnalyticsControls() {
  const currentStore = analyticsStoreFilter.value;
  analyticsStoreFilter.innerHTML = `<option value="">Todas as lojas</option>`;
  analyticsStoreFilter.innerHTML += stores
    .map((store) => `<option value="${store.id}">${escapeHtml(store.name)}</option>`)
    .join("");
  analyticsStoreFilter.value = stores.some((store) => store.id === currentStore) ? currentStore : "";
}

function setAnalyticsDateMode(mode) {
  const nextMode = mode === "range" ? "range" : "single";

  analyticsDateModeButtons.forEach((button) => {
    button.classList.toggle("is-active", button.dataset.analyticsDateMode === nextMode);
  });

  analyticsSingleDateField.hidden = nextMode !== "single";
  analyticsRangeDateFields.forEach((field) => {
    field.hidden = nextMode !== "range";
  });

  renderAdminAnalytics();
}

function setAnalyticsQuickRange(range) {
  setAnalyticsDateMode("range");

  const today = new Date();
  const start = new Date(today);

  if (range === "week") {
    const day = start.getDay();
    const distanceFromMonday = day === 0 ? 6 : day - 1;
    start.setDate(start.getDate() - distanceFromMonday);
  }

  if (range === "month") {
    start.setDate(1);
  }

  if (range === "year") {
    start.setMonth(0, 1);
  }

  analyticsStartDate.value = formatInputDate(start);
  analyticsEndDate.value = formatInputDate(today);
  renderAdminAnalytics();
}

function renderAdminAnalytics() {
  const filteredLeads = getAnalyticsFilteredLeads();
  const total = filteredLeads.length;
  const visited = filteredLeads.filter((lead) => isPositiveAnswer(lead.visited)).length;
  const bought = filteredLeads.filter((lead) => isPositiveAnswer(lead.bought)).length;
  const conversion = total ? Math.round((bought / total) * 100) : 0;

  document.querySelector("#analyticsTotalLeads").textContent = total;
  document.querySelector("#analyticsVisitedLeads").textContent = visited;
  document.querySelector("#analyticsBoughtLeads").textContent = bought;
  document.querySelector("#analyticsConversionRate").textContent = `${conversion}%`;

  renderAnalyticsMetricCharts({ total, visited, bought });

  renderMetricRanking({
    containerId: "campaignRanking",
    topLabelId: "topCampaignLabel",
    rows: buildMetricRanking(filteredLeads, (lead) => lead.campaign),
    emptyLabel: "Nenhuma campanha no filtro",
  });
  renderMetricRanking({
    containerId: "storeRanking",
    topLabelId: "topStoreLabel",
    rows: buildMetricRanking(filteredLeads, getLeadStoreName),
    emptyLabel: "Nenhuma loja no filtro",
  });
  renderMetricRanking({
    containerId: "conversationStartRanking",
    topLabelId: "topStartLabel",
    rows: buildMetricRanking(filteredLeads, (lead) => lead.conversationStart),
    emptyLabel: "Nenhum início no filtro",
  });
  renderMetricRanking({
    containerId: "conclusionRanking",
    topLabelId: "topConclusionLabel",
    rows: buildMetricRanking(filteredLeads, (lead) => lead.conclusion),
    emptyLabel: "Nenhum fim no filtro",
  });
  renderMetricRanking({
    containerId: "visitedRanking",
    topLabelId: "topVisitedLabel",
    rows: buildMetricRanking(filteredLeads, (lead) => lead.visited || "Sem resposta"),
    emptyLabel: "Nenhuma visita no filtro",
    compact: true,
  });
  renderMetricRanking({
    containerId: "boughtRanking",
    topLabelId: "topBoughtLabel",
    rows: buildMetricRanking(filteredLeads, (lead) => lead.bought || "Sem resposta"),
    emptyLabel: "Nenhuma compra no filtro",
    compact: true,
  });
}

function getAnalyticsFilteredLeads() {
  const selectedStoreId = analyticsStoreFilter.value;
  const dateMode = getAnalyticsDateMode();

  return leads.filter((lead) => {
    const leadDate = getDateOnly(lead.createdAt);
    const matchesStore = !selectedStoreId || lead.storeId === selectedStoreId;
    const matchesSingleDate =
      dateMode !== "single" || !analyticsSingleDate.value || leadDate === analyticsSingleDate.value;
    const matchesStartDate =
      dateMode !== "range" || !analyticsStartDate.value || leadDate >= analyticsStartDate.value;
    const matchesEndDate =
      dateMode !== "range" || !analyticsEndDate.value || leadDate <= analyticsEndDate.value;

    return matchesStore && matchesSingleDate && matchesStartDate && matchesEndDate;
  });
}

function getAnalyticsDateMode() {
  const activeButton = [...analyticsDateModeButtons].find((button) =>
    button.classList.contains("is-active"),
  );

  return activeButton?.dataset.analyticsDateMode || "single";
}

function buildMetricRanking(items, labelGetter) {
  const grouped = new Map();

  items.forEach((lead) => {
    const label = String(labelGetter(lead) || "Sem resposta").trim() || "Sem resposta";
    const current = grouped.get(label) || { label, count: 0, visited: 0, bought: 0 };
    current.count += 1;
    if (isPositiveAnswer(lead.visited)) current.visited += 1;
    if (isPositiveAnswer(lead.bought)) current.bought += 1;
    grouped.set(label, current);
  });

  return [...grouped.values()]
    .map((row) => ({
      ...row,
      conversion: row.count ? Math.round((row.bought / row.count) * 100) : 0,
    }))
    .sort((first, second) => second.count - first.count || first.label.localeCompare(second.label));
}

function renderMetricRanking({ containerId, topLabelId, rows, emptyLabel, compact = false }) {
  const container = document.querySelector(`#${containerId}`);
  const topLabel = document.querySelector(`#${topLabelId}`);
  const maxCount = rows[0]?.count || 0;

  topLabel.textContent = rows[0]
    ? `${rows[0].label} · ${pluralize(rows[0].count, "lead")}`
    : "Sem dados";

  if (!rows.length) {
    container.innerHTML = `<div class="ranking-empty">${emptyLabel}</div>`;
    return;
  }

  container.innerHTML = rows
    .map((row, index) => {
      const width = maxCount ? Math.max(8, Math.round((row.count / maxCount) * 100)) : 0;
      const detail = compact
        ? `${pluralize(row.count, "lead")}`
        : `${pluralize(row.count, "lead")} · ${row.visited} visitas · ${row.bought} compras · ${row.conversion}%`;

      return `
        <div class="ranking-row">
          <div class="ranking-row-top">
            <span>${String(index + 1).padStart(2, "0")} · ${escapeHtml(row.label)}</span>
            <strong>${escapeHtml(detail)}</strong>
          </div>
          <div class="bar-track" aria-hidden="true">
            <span class="bar-fill" style="width: ${width}%"></span>
          </div>
        </div>
      `;
    })
    .join("");
}

function renderAnalyticsMetricCharts({ total, visited, bought }) {
  const visitRate = total ? Math.round((visited / total) * 100) : 0;
  const buyRate = total ? Math.round((bought / total) * 100) : 0;
  const visitorCloseRate = visited ? Math.round((bought / visited) * 100) : 0;

  document.querySelector("#analyticsFunnelLabel").textContent = total
    ? `${pluralize(total, "lead")} no filtro`
    : "Sem dados";
  document.querySelector("#analyticsRatesLabel").textContent = total
    ? `${buyRate}% de conversão`
    : "Sem dados";

  renderMetricBars("analyticsFunnelChart", [
    { label: "Leads", value: total, width: 100, detail: pluralize(total, "lead") },
    { label: "Visitas", value: visited, width: visitRate, detail: `${visited} visitas` },
    { label: "Compras", value: bought, width: buyRate, detail: `${bought} compras` },
  ]);

  renderMetricBars("analyticsRatesChart", [
    { label: "Visita sobre leads", value: visitRate, width: visitRate, detail: `${visitRate}%` },
    { label: "Compra sobre leads", value: buyRate, width: buyRate, detail: `${buyRate}%` },
    {
      label: "Compra após visita",
      value: visitorCloseRate,
      width: visitorCloseRate,
      detail: `${visitorCloseRate}%`,
    },
  ]);
}

function renderMetricBars(containerId, rows) {
  const container = document.querySelector(`#${containerId}`);

  if (!rows.some((row) => row.value > 0)) {
    container.innerHTML = `<div class="ranking-empty compact-empty">Sem dados para o gráfico</div>`;
    return;
  }

  container.innerHTML = rows
    .map((row) => {
      const width = Math.max(row.value > 0 ? 6 : 0, Math.min(row.width, 100));

      return `
        <div class="metric-bar-row">
          <div class="metric-bar-top">
            <span>${escapeHtml(row.label)}</span>
            <strong>${escapeHtml(row.detail)}</strong>
          </div>
          <div class="metric-bar-track" aria-hidden="true">
            <span class="metric-bar-fill" style="width: ${width}%"></span>
          </div>
        </div>
      `;
    })
    .join("");
}

function getLeadStoreName(lead) {
  return lead.storeName || stores.find((store) => store.id === lead.storeId)?.name || "Sem loja";
}

function renderStoreList() {
  storeEmptyState.style.display = stores.length ? "none" : "grid";
  storeList.innerHTML = stores
    .map((store) => {
      return `
        <article class="lead-card">
          <div class="lead-card-header">
            <div class="lead-person">
              <strong>${escapeHtml(store.name)}</strong>
              <span>Nick: ${escapeHtml(store.username)} · criada em ${formatShortDate(store.created_at)}</span>
            </div>
            <div class="lead-actions">
              <button class="mini-button" type="button" data-store-login="${store.id}">Entrar na loja</button>
              <span class="badge green">Loja ativa</span>
            </div>
          </div>
        </article>
      `;
    })
    .join("");
}

async function enterStoreContext(storeId) {
  const store = stores.find((item) => item.id === storeId);
  if (!store) return;

  activeStoreContext = {
    id: store.id,
    name: store.name,
  };
  sessionRole.textContent = `Admin na loja · ${store.name}`;
  backAdminButton.hidden = false;
  adminView.hidden = true;
  storeView.hidden = false;
  resetLeadForm();
  await loadOptions();
  await loadLeads();
}

async function returnToAdmin() {
  activeStoreContext = null;
  resetLeadForm();
  sessionRole.textContent = `Admin · ${currentProfile.username}`;
  backAdminButton.hidden = true;
  storeView.hidden = true;
  adminView.hidden = false;
  await loadOptions();
  await loadAdminDashboard();
}

function renderOptionsEditors() {
  if (currentProfile?.role === "admin") {
    adminOptionsList.innerHTML = renderOptionsEditor("admin");
  }

  if (currentProfile?.role === "store" || activeStoreContext) {
    storeOptionsList.innerHTML = renderOptionsEditor("store");
  }
}

function renderOptionsEditor(scope) {
  return optionGroups
    .map((group) => {
      const items = options[group] || [];
      const isFixedGroup = fixedOptionGroups.has(group);
      const rows = isFixedGroup
        ? nativeYesNoOptions
            .map((item) => `<span class="fixed-option">${escapeHtml(item)}</span>`)
            .join("")
        : items.length
          ? items
              .map(
                (item, index) => `
                  <div class="option-row">
                    <input value="${escapeHtml(item)}" data-original-value="${escapeHtml(item)}" data-option-input="${scope}" data-group="${group}" data-index="${index}" />
                    <button class="mini-button option-save-button" type="button" data-option-action="save" data-scope="${scope}" data-group="${group}" data-index="${index}" hidden>Salvar</button>
                    <button class="mini-button danger" type="button" data-option-action="delete" data-scope="${scope}" data-group="${group}" data-index="${index}">Excluir</button>
                  </div>
                `,
              )
              .join("")
          : `<div class="option-empty">Nada cadastrado.</div>`;

      return `
        <section class="option-group">
          <div class="section-title">
            <h3>${labels[group]}</h3>
          </div>
          <div class="${isFixedGroup ? "fixed-option-list" : "option-list"}">${rows}</div>
          ${
            isFixedGroup
              ? ""
              : `
                <div class="option-add">
                  <input placeholder="Nova opção" data-option-new="${scope}" data-group="${group}" />
                  <button class="secondary-button" type="button" data-option-action="add" data-scope="${scope}" data-group="${group}">Adicionar</button>
                </div>
              `
          }
        </section>
      `;
    })
    .join("");
}

async function handleOptionsEditorClick(event) {
  const button = event.target.closest("[data-option-action]");
  if (!button) return;

  const { action, group, scope } = button.dataset.optionAction
    ? {
        action: button.dataset.optionAction,
        group: button.dataset.group,
        scope: button.dataset.scope,
      }
    : {};
  const messageTarget = scope === "admin" ? "admin" : "store";
  clearOptionsMessage(messageTarget);

  if (fixedOptionGroups.has(group)) return;

  if (action === "add") {
    const input = document.querySelector(`[data-option-new="${scope}"][data-group="${group}"]`);
    const value = input.value.trim();
    if (!value) {
      showOptionsMessage(messageTarget, "Digite uma opção antes de adicionar.");
      return;
    }

    options[group] = [...(options[group] || []), value];
    input.value = "";
  }

  if (action === "save") {
    const index = Number(button.dataset.index);
    const input = document.querySelector(
      `[data-option-input="${scope}"][data-group="${group}"][data-index="${index}"]`,
    );
    const value = input.value.trim();
    if (!value) {
      showOptionsMessage(messageTarget, "A opção não pode ficar vazia.");
      return;
    }

    options[group][index] = value;
    clearDirtyOption(button.dataset.scope, group, index);
  }

  if (action === "delete") {
    const index = Number(button.dataset.index);
    options[group] = (options[group] || []).filter((_, itemIndex) => itemIndex !== index);
    clearDirtyOption(button.dataset.scope, group, index);

    if (selectedValues[group] && !options[group].includes(selectedValues[group])) {
      selectedValues[group] = "";
    }
  }

  if (!collectDirtyOptionInputs()) {
    showOptionsMessage(messageTarget, "A opção não pode ficar vazia.");
    return;
  }

  options = normalizeOptions(options);
  renderChoiceButtons();
  renderFilters();
  renderOptionsEditors();
  showOptionsMessage(messageTarget, "Salvando...", "success");

  const saved = await saveCurrentOptions(messageTarget);
  if (!saved) await loadOptions();
}

function handleOptionsEditorInput(event) {
  const input = event.target.closest("[data-option-input]");
  if (!input) return;

  const { group, index } = input.dataset;
  if (fixedOptionGroups.has(group)) return;

  const key = getDirtyOptionKey(input.dataset.optionInput, group, index);
  const saveButton = document.querySelector(
    `[data-option-action="save"][data-scope="${input.dataset.optionInput}"][data-group="${group}"][data-index="${index}"]`,
  );
  const isDirty = input.value.trim() !== input.dataset.originalValue;

  if (isDirty) {
    dirtyOptionKeys.add(key);
  } else {
    dirtyOptionKeys.delete(key);
  }

  if (saveButton) saveButton.hidden = !isDirty;
}

function getDirtyOptionKey(scope, group, index) {
  return `${scope}:${group}:${index}`;
}

function clearDirtyOption(scope, group, index) {
  dirtyOptionKeys.delete(getDirtyOptionKey(scope, group, index));
}

function hasUnsavedOptions() {
  return dirtyOptionKeys.size > 0;
}

function collectDirtyOptionInputs() {
  let isValid = true;

  document.querySelectorAll("[data-option-input]").forEach((input) => {
    const { group, index } = input.dataset;
    if (!dirtyOptionKeys.has(getDirtyOptionKey(input.dataset.optionInput, group, index))) return;

    const value = input.value.trim();
    if (!value) {
      isValid = false;
      input.focus();
      return;
    }
    options[group][Number(index)] = value;
  });

  return isValid;
}

function getActiveOptionsMessageTarget() {
  return currentProfile?.role === "admin" && !activeStoreContext ? "admin" : "store";
}

function guardUnsavedOptions(action) {
  if (!hasUnsavedOptions()) {
    action();
    return;
  }

  pendingUnsavedAction = action;
  unsavedOptionsModal.hidden = false;
}

function closeUnsavedOptionsModal() {
  pendingUnsavedAction = null;
  unsavedOptionsModal.hidden = true;
}

async function discardUnsavedOptionsAndContinue() {
  const action = pendingUnsavedAction;
  dirtyOptionKeys.clear();
  pendingUnsavedAction = null;
  unsavedOptionsModal.hidden = true;
  await loadOptions();
  if (action) action();
}

async function saveUnsavedOptionsAndContinue() {
  const action = pendingUnsavedAction;
  const target = getActiveOptionsMessageTarget();
  if (!collectDirtyOptionInputs()) {
    showOptionsMessage(target, "A opção não pode ficar vazia.");
    return;
  }
  const saved = await saveCurrentOptions(target);
  if (!saved) return;

  dirtyOptionKeys.clear();
  pendingUnsavedAction = null;
  unsavedOptionsModal.hidden = true;
  if (action) action();
}

async function loadLeads() {
  let query = supabaseClient
    .from("leads")
    .select("*")
    .order("created_at", { ascending: false });

  const activeStoreId = getActiveStoreId();
  if (activeStoreId) {
    query = query.eq("store_id", activeStoreId);
  }

  const { data, error } = await query;

  if (error) {
    showLeadMessage("Não foi possível carregar os leads.");
    return;
  }

  leads = (data || []).map(mapLeadFromDb);
  renderLeadApp();
}

function renderChoiceButtons() {
  document.querySelectorAll("[data-choice-group]").forEach((container) => {
    const group = container.dataset.choiceGroup;
    const groupOptions = options[group] || [];

    if (!groupOptions.length) {
      container.innerHTML = `<div class="choice-empty">Nenhuma opção cadastrada.</div>`;
      return;
    }

    container.innerHTML = groupOptions
      .map(
        (option) => `
          <button class="choice-button" type="button" data-choice="${group}" data-value="${option}">
            ${escapeHtml(option)}
          </button>
        `,
      )
      .join("");

    container.onclick = (event) => {
      const button = event.target.closest("[data-choice]");
      if (!button) return;

      selectedValues[group] =
        (group === "bought" || group === "visited") && selectedValues[group] === button.dataset.value
          ? ""
          : button.dataset.value;
      renderSelectedChoice(group);
      clearLeadMessage();
    };
  });
}

function renderFilters() {
  renderSelectOptions(channelFilter, options.channel, "Todos");
  renderSelectOptions(campaignFilter, options.campaign, "Todos");
  renderSelectOptions(conversationStartFilter, options.conversationStart, "Todos");
  renderSelectOptions(conclusionFilter, options.conclusion, "Todos");
  renderSelectOptions(visitedFilter, options.visited, "Todos", true);
  renderSelectOptions(boughtFilter, options.bought, "Todos", true);
}

function renderSelectOptions(select, values, defaultLabel, includeEmptyOption = false) {
  const currentValue = select.value;
  select.innerHTML = `<option value="">${defaultLabel}</option>`;
  select.innerHTML += (values || [])
    .map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`)
    .join("");

  if (includeEmptyOption) {
    select.innerHTML += `<option value="sem-resposta">Sem resposta</option>`;
  }

  select.value = [...select.options].some((option) => option.value === currentValue)
    ? currentValue
    : "";
}

function toggleFilters() {
  filtersPanel.hidden = !filtersPanel.hidden;
  toggleFiltersButton.classList.toggle("is-active", !filtersPanel.hidden);
}

function clearFilters() {
  [
    channelFilter,
    campaignFilter,
    conversationStartFilter,
    conclusionFilter,
    visitedFilter,
    boughtFilter,
    startDateFilter,
    endDateFilter,
  ].forEach((element) => {
    element.value = "";
  });

  renderLeadList();
}

async function handleLeadSubmit(event) {
  event.preventDefault();
  clearLeadMessage();

  const validationMessage = getValidationMessage();
  if (validationMessage) {
    showLeadMessage(validationMessage);
    return;
  }

  const editingId = editingIdInput.value;
  const payload = mapLeadToDb({
    name: nameInput.value.trim(),
    phone: phoneInput.value.trim(),
    channel: selectedValues.channel,
    campaign: selectedValues.campaign,
    conversationStart: selectedValues.conversationStart,
    conclusion: selectedValues.conclusion,
    visited: selectedValues.visited,
    bought: selectedValues.bought,
  });

  const request = editingId
    ? supabaseClient.from("leads").update(payload).eq("id", editingId)
    : supabaseClient.from("leads").insert({
        ...payload,
        store_id: getActiveStoreId(),
      });

  const { error } = await request;

  if (error) {
    showLeadMessage("Não foi possível salvar o lead.");
    return;
  }

  showLeadMessage(editingId ? "Lead atualizado com sucesso." : "Lead salvo com sucesso.", "success");
  resetLeadForm({ keepMessage: true });
  await loadLeads();
}

function getValidationMessage() {
  if (!nameInput.value.trim()) return "Preencha o nome do lead.";
  if (!phoneInput.value.trim()) return "Preencha o telefone do lead.";

  const emptyRequiredGroup = optionGroups.find(
    (group) => group !== "bought" && group !== "visited" && !(options[group] || []).length,
  );
  if (emptyRequiredGroup) {
    return `Cadastre pelo menos uma opção em ${labels[emptyRequiredGroup]}.`;
  }

  const missingGroup = Object.entries(selectedValues).find(
    ([group, value]) => group !== "bought" && group !== "visited" && !value,
  );
  if (missingGroup) return `Selecione uma opção em ${labels[missingGroup[0]]}.`;

  return "";
}

function renderLeadApp() {
  renderLeadStats();
  renderLeadList();
}

function renderLeadStats() {
  const today = new Date().toDateString();
  const todayLeads = leads.filter((lead) => new Date(lead.createdAt).toDateString() === today);
  const visited = leads.filter((lead) => isPositiveAnswer(lead.visited)).length;
  const bought = leads.filter((lead) => isPositiveAnswer(lead.bought)).length;
  const conversion = leads.length ? Math.round((bought / leads.length) * 100) : 0;

  document.querySelector("#todayCount").textContent = pluralize(todayLeads.length, "lead");
  document.querySelector("#totalLeads").textContent = leads.length;
  document.querySelector("#storeVisits").textContent = visited;
  document.querySelector("#salesCount").textContent = bought;
  document.querySelector("#conversionRate").textContent = `${conversion}%`;
}

function renderLeadList() {
  const filteredLeads = getFilteredLeads();

  emptyState.style.display = filteredLeads.length ? "none" : "grid";
  leadList.innerHTML = filteredLeads.map(renderLeadCard).join("");
}

function getFilteredLeads() {
  const term = normalize(searchInput.value);

  return leads.filter((lead, index) => {
    const leadNumber = getLeadNumber(index);
    const matchesSearch =
      !term ||
      normalize(`${leadNumber} ${lead.id} ${lead.name} ${lead.phone}`).includes(term);
    const matchesChannel = !channelFilter.value || lead.channel === channelFilter.value;
    const matchesCampaign = !campaignFilter.value || lead.campaign === campaignFilter.value;
    const matchesConversationStart =
      !conversationStartFilter.value ||
      lead.conversationStart === conversationStartFilter.value;
    const matchesConclusion = !conclusionFilter.value || lead.conclusion === conclusionFilter.value;
    const matchesVisited =
      !visitedFilter.value ||
      (visitedFilter.value === "sem-resposta" && !lead.visited) ||
      lead.visited === visitedFilter.value;
    const matchesBought =
      !boughtFilter.value ||
      (boughtFilter.value === "sem-resposta" && !lead.bought) ||
      lead.bought === boughtFilter.value;
    const matchesStartDate =
      !startDateFilter.value || getDateOnly(lead.createdAt) >= startDateFilter.value;
    const matchesEndDate =
      !endDateFilter.value || getDateOnly(lead.createdAt) <= endDateFilter.value;

    return (
      matchesSearch &&
      matchesChannel &&
      matchesCampaign &&
      matchesConversationStart &&
      matchesConclusion &&
      matchesVisited &&
      matchesBought &&
      matchesStartDate &&
      matchesEndDate
    );
  });
}

function renderLeadCard(lead) {
  const leadNumber = getLeadNumber(leads.findIndex((item) => item.id === lead.id));
  const visitedLabel = lead.visited || "Sem resposta";
  const boughtLabel = lead.bought || "Sem resposta";
  const createdAt = new Intl.DateTimeFormat("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(lead.createdAt));

  return `
    <article class="lead-card">
      <div class="lead-card-header">
        <div class="lead-person">
          <strong>${leadNumber} · ${escapeHtml(lead.name)}</strong>
          <span>${escapeHtml(lead.phone)} · ${createdAt}</span>
        </div>
        <div class="lead-actions">
          <button class="mini-button" type="button" data-action="edit" data-id="${lead.id}">Editar</button>
          <button class="mini-button danger" type="button" data-action="delete" data-id="${lead.id}">Excluir</button>
        </div>
      </div>

      <div class="badge-row">
        <span class="badge">${escapeHtml(lead.channel)}</span>
        <span class="badge amber">${escapeHtml(lead.campaign)}</span>
        <span class="badge ${isPositiveAnswer(lead.visited) ? "green" : "rose"}">Visitou: ${escapeHtml(visitedLabel)}</span>
        <span class="badge ${isPositiveAnswer(lead.bought) ? "green" : "rose"}">Comprou: ${escapeHtml(boughtLabel)}</span>
      </div>

      <div class="lead-meta">
        <div class="meta-item">
          <span>Início</span>
          <strong>${escapeHtml(lead.conversationStart)}</strong>
        </div>
        <div class="meta-item">
          <span>Conclusão</span>
          <strong>${escapeHtml(lead.conclusion)}</strong>
        </div>
        <div class="meta-item">
          <span>Última atualização</span>
          <strong>${formatShortDate(lead.updatedAt)}</strong>
        </div>
      </div>
    </article>
  `;
}

function editLead(id) {
  setStoreOptionsMode(false);
  const lead = leads.find((item) => item.id === id);
  if (!lead) return;

  editingIdInput.value = lead.id;
  nameInput.value = lead.name;
  phoneInput.value = lead.phone;
  selectedValues = {
    channel: lead.channel,
    campaign: lead.campaign,
    conversationStart: lead.conversationStart,
    conclusion: lead.conclusion,
    visited: lead.visited || null,
    bought: lead.bought,
  };

  Object.keys(selectedValues).forEach(renderSelectedChoice);
  formTitle.textContent = "Editar lead";
  submitButton.textContent = "Atualizar lead";
  cancelEditButton.hidden = false;
  clearLeadMessage();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function deleteLead(id) {
  const lead = leads.find((item) => item.id === id);
  if (!lead) return;

  const confirmed = window.confirm(`Excluir o lead ${lead.name}?`);
  if (!confirmed) return;

  const { error } = await supabaseClient.from("leads").delete().eq("id", id);

  if (error) {
    showLeadMessage("Não foi possível excluir o lead.");
    return;
  }

  await loadLeads();
}

function resetLeadForm(config = {}) {
  form.reset();
  editingIdInput.value = "";
  selectedValues = {
    channel: "",
    campaign: "",
    conversationStart: "",
    conclusion: "",
    visited: "",
    bought: "",
  };

  Object.keys(selectedValues).forEach(renderSelectedChoice);
  formTitle.textContent = "Cadastrar lead";
  submitButton.textContent = "Salvar lead";
  cancelEditButton.hidden = true;

  if (!config.keepMessage) clearLeadMessage();
}

function toggleStoreOptionsMode() {
  setStoreOptionsMode(storeOptionsPanel.hidden);
}

function setStoreOptionsMode(isEditingOptions) {
  storeOptionsPanel.hidden = !isEditingOptions;
  form.classList.toggle("is-options-mode", isEditingOptions);
  toggleOptionsEditButton.textContent = isEditingOptions ? "Cadastrar lead" : "Editar opções";

  if (isEditingOptions) {
    resetLeadForm();
    clearOptionsMessage("store");
  }
}

function renderSelectedChoice(group) {
  document.querySelectorAll(`[data-choice="${group}"]`).forEach((button) => {
    button.classList.toggle("is-selected", button.dataset.value === selectedValues[group]);
  });
}

function mapLeadFromDb(lead) {
  return {
    id: lead.id,
    storeId: lead.store_id,
    storeName: lead.stores?.name || "",
    name: lead.name,
    phone: lead.phone,
    channel: lead.channel,
    campaign: lead.campaign,
    conversationStart: lead.conversation_start,
    conclusion: lead.conclusion,
    visited: lead.visited,
    bought: lead.bought || "",
    createdAt: lead.created_at,
    updatedAt: lead.updated_at,
  };
}

function mapLeadToDb(lead) {
  return {
    name: lead.name,
    phone: lead.phone,
    channel: lead.channel,
    campaign: lead.campaign,
    conversation_start: lead.conversationStart,
    conclusion: lead.conclusion,
    visited: lead.visited || null,
    bought: lead.bought || null,
    updated_at: new Date().toISOString(),
  };
}

function formatPhone(value) {
  const digits = value.replace(/\D/g, "").slice(0, 11);
  if (digits.length <= 2) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 2)}) ${digits.slice(2)}`;
  if (digits.length <= 10) {
    return `(${digits.slice(0, 2)}) ${digits.slice(2, 6)}-${digits.slice(6)}`;
  }
  return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7)}`;
}

function setTodayLabel() {
  const label = new Intl.DateTimeFormat("pt-BR", {
    weekday: "long",
    day: "2-digit",
    month: "long",
  }).format(new Date());

  document.querySelector("#todayLabel").textContent =
    label.charAt(0).toUpperCase() + label.slice(1);
}

function togglePassword(button) {
  const input = document.querySelector(`#${button.dataset.togglePassword}`);
  if (!input) return;

  const isPassword = input.type === "password";
  input.type = isPassword ? "text" : "password";
  button.textContent = isPassword ? "Ocultar" : "Ver";
}

function showAuthMessage(message, type = "error") {
  authMessage.textContent = message;
  authMessage.classList.toggle("success", type === "success");
}

function formatAuthError(error) {
  const message = typeof error === "string" ? error : error?.message || "";
  const normalizedMessage = String(message).toLowerCase();
  const isMissingRpc =
    error?.status === 404 ||
    error?.code === "PGRST202" ||
    normalizedMessage.includes("could not find the function") ||
    normalizedMessage.includes("schema cache");

  if (isMissingRpc) {
    return "Banco ainda não foi atualizado. Rode o supabase/schema.sql inteiro no SQL Editor.";
  }
  if (normalizedMessage.includes("already registered")) {
    return "Esse nick já está cadastrado.";
  }
  if (normalizedMessage.includes("invalid login") || normalizedMessage.includes("senha inválidos")) {
    return "Nick ou senha inválidos.";
  }
  if (normalizedMessage.includes("admin já existe")) {
    return "Já existe um admin. Entre com o nick e senha cadastrados.";
  }
  if (normalizedMessage.includes("app_user_sessions_auth_user_id_fkey")) {
    return "Sessão antiga do navegador. Clique em Sair ou recarregue a página e tente criar o admin de novo.";
  }
  return message || "Não foi possível concluir a ação.";
}

function clearAuthMessage() {
  authMessage.textContent = "";
  authMessage.classList.remove("success");
}

function showStoreMessage(message, type = "error") {
  storeMessage.textContent = message;
  storeMessage.classList.toggle("success", type === "success");
}

function clearStoreMessage() {
  storeMessage.textContent = "";
  storeMessage.classList.remove("success");
}

function showLeadMessage(message, type = "error") {
  formMessage.textContent = message;
  formMessage.classList.toggle("success", type === "success");
}

function clearLeadMessage() {
  formMessage.textContent = "";
  formMessage.classList.remove("success");
}

function pluralize(count, word) {
  return `${count} ${count === 1 ? word : `${word}s`}`;
}

function formatShortDate(date) {
  return new Intl.DateTimeFormat("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(new Date(date));
}

function getDateOnly(date) {
  return formatInputDate(new Date(date));
}

function formatInputDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function getLeadNumber(index) {
  return `Lead ${String(index + 1).padStart(3, "0")}`;
}

function getActiveStoreId() {
  return activeStoreContext?.id || currentProfile?.store_id || "";
}

function isPositiveAnswer(value) {
  const normalizedValue = normalize(value || "");
  return Boolean(value) && normalizedValue !== "nao" && normalizedValue !== "nao retornou";
}

function showOptionsMessage(target, message, type = "error") {
  const element = target === "admin" ? adminOptionsMessage : storeOptionsMessage;
  element.textContent = message;
  element.classList.toggle("success", type === "success");
}

function clearOptionsMessage(target) {
  const element = target === "admin" ? adminOptionsMessage : storeOptionsMessage;
  element.textContent = "";
  element.classList.remove("success");
}

function createEmptyOptions(includeNativeYesNo = true) {
  return optionGroups.reduce((result, group) => {
    result[group] =
      includeNativeYesNo && (group === "visited" || group === "bought")
        ? [...nativeYesNoOptions]
        : [];
    return result;
  }, {});
}

function normalizeOptions(source) {
  const normalizedOptions = createEmptyOptions();

  optionGroups.forEach((group) => {
    const values = Array.isArray(source?.[group]) ? source[group] : [];
    normalizedOptions[group] = [
      ...new Set(
        [...normalizedOptions[group], ...values]
          .map((value) => String(value).trim())
          .filter(Boolean),
      ),
    ];
  });

  return normalizedOptions;
}

function getOptionsStoreId() {
  return activeStoreContext?.id || (currentProfile?.role === "store" ? currentProfile.store_id : null);
}

async function loadOptionsRows(storeId) {
  const query = supabaseClient
    .from("lead_options")
    .select("group_key,value,sort_order,store_id")
    .order("group_key", { ascending: true })
    .order("sort_order", { ascending: true });

  const { data, error } = storeId ? await query.eq("store_id", storeId) : await query.is("store_id", null);

  if (error) {
    showOptionsMessage(currentProfile?.role === "admin" && !activeStoreContext ? "admin" : "store", "Não foi possível carregar as opções do banco.");
    return createEmptyOptions(false);
  }

  return optionsFromRows(data || []);
}

function hasCustomOptionRows(nextOptions) {
  return optionGroups.some((group) => (nextOptions[group] || []).length > 0);
}

function optionsFromRows(rows) {
  const nextOptions = createEmptyOptions(false);

  rows.forEach((row) => {
    if (!optionGroups.includes(row.group_key)) return;
    nextOptions[row.group_key] = [...(nextOptions[row.group_key] || []), row.value];
  });

  return nextOptions;
}

function buildOptionRows(sourceOptions, storeId) {
  return optionGroups.filter((group) => !fixedOptionGroups.has(group)).flatMap((group) =>
    (sourceOptions[group] || []).map((value, index) => ({
      store_id: storeId,
      group_key: group,
      value,
      sort_order: index,
      created_by: currentProfile?.id || null,
    })),
  );
}

function normalizeNick(nick) {
  return normalize(nick)
    .replace(/[^a-z0-9._-]/g, "")
    .replace(/^[._-]+|[._-]+$/g, "");
}

function normalize(value) {
  return value
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
