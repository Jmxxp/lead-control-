const labels = {
  channel: "Canal",
  campaign: "Campanha",
  conversationStart: "Início da conversa",
  conclusion: "Conclusão",
  visited: "Visitou a loja",
  bought: "Comprou",
};

const optionGroups = Object.keys(labels);
const fixedOptionGroups = new Set(["visited", "bought"]);
const nativeYesNoOptions = ["Sim", "Não"];
const defaultOptions = {
  channel: ["WhatsApp", "Instagram", "Facebook", "Ligação"],
  campaign: ["Orgânico", "Anúncio", "Indicação"],
  conversationStart: ["Preço", "Consulta", "Armação", "Lente"],
  conclusion: ["Aguardando", "Retornar", "Finalizado"],
  visited: nativeYesNoOptions,
  bought: nativeYesNoOptions,
};

let options = cloneOptions(defaultOptions);
let currentProfile = null;
let activeStoreContext = null;
let stores = [];
let leads = [];
let users = [];
let pendingUnsavedAction = null;
const dirtyOptionKeys = new Set();
let selectedValues = createEmptySelection();

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

const authScreen = $("#authScreen");
const appView = $("#appView");
const adminView = $("#adminView");
const storeView = $("#storeView");
const sessionRole = $("#sessionRole");
const logoutButton = $("#logoutButton");
const backAdminButton = $("#backAdminButton");
const loginForm = $("#loginForm");
const signupForm = $("#signupForm");
const authMessage = $("#authMessage");
const loginNick = $("#loginNick");
const loginPassword = $("#loginPassword");
const signupName = $("#signupName");
const signupNick = $("#signupNick");
const signupPassword = $("#signupPassword");
const storeForm = $("#storeForm");
const storeName = $("#storeName");
const storeNick = $("#storeNick");
const storePassword = $("#storePassword");
const storeMessage = $("#storeMessage");
const storeEmptyState = $("#storeEmptyState");
const storeList = $("#storeList");
const adminOptionsList = $("#adminOptionsList");
const adminOptionsMessage = $("#adminOptionsMessage");
const analyticsToggle = $("#analyticsToggle");
const analyticsToggleLabel = $("#analyticsToggleLabel");
const analyticsContent = $("#analyticsContent");
const analyticsStoreFilter = $("#analyticsStoreFilter");
const analyticsSingleDate = $("#analyticsSingleDate");
const analyticsStartDate = $("#analyticsStartDate");
const analyticsEndDate = $("#analyticsEndDate");
const analyticsSingleDateField = $(".analytics-single-date");
const analyticsRangeDateFields = $$(".analytics-range-date");
const analyticsDateModeButtons = $$("[data-analytics-date-mode]");
const analyticsQuickRangeButtons = $$("[data-analytics-range]");
const form = $("#leadForm");
const formTitle = $("#formTitle");
const submitButton = $("#submitButton");
const formMessage = $("#formMessage");
const clearFormButton = $("#clearForm");
const cancelEditButton = $("#cancelEdit");
const toggleOptionsEditButton = $("#toggleOptionsEdit");
const editingIdInput = $("#editingId");
const nameInput = $("#name");
const phoneInput = $("#phone");
const searchInput = $("#search");
const filtersPanel = $("#filtersPanel");
const toggleFiltersButton = $("#toggleFilters");
const channelFilter = $("#channelFilter");
const campaignFilter = $("#campaignFilter");
const conversationStartFilter = $("#conversationStartFilter");
const conclusionFilter = $("#conclusionFilter");
const visitedFilter = $("#visitedFilter");
const boughtFilter = $("#boughtFilter");
const startDateFilter = $("#startDateFilter");
const endDateFilter = $("#endDateFilter");
const clearFiltersButton = $("#clearFilters");
const emptyState = $("#emptyState");
const leadList = $("#leadList");
const storeOptionsPanel = $("#storeOptionsPanel");
const storeOptionsList = $("#storeOptionsList");
const storeOptionsMessage = $("#storeOptionsMessage");
const unsavedOptionsModal = $("#unsavedOptionsModal");
const unsavedCancel = $("#unsavedCancel");
const unsavedDiscard = $("#unsavedDiscard");
const unsavedSave = $("#unsavedSave");

document.addEventListener("DOMContentLoaded", init);

function init() {
  setTodayLabel();
  bindEvents();
  showAuth();
  renderAll();
}

function bindEvents() {
  $$("[data-auth-tab]").forEach((tab) => {
    tab.addEventListener("click", () => setAuthTab(tab.dataset.authTab));
  });

  $$("[data-toggle-password]").forEach((button) => {
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
  ].forEach((element) => element.addEventListener("input", renderLeadList));

  toggleFiltersButton.addEventListener("click", toggleFilters);
  clearFiltersButton.addEventListener("click", clearFilters);
  leadList.addEventListener("click", handleLeadListClick);
  storeList.addEventListener("click", handleStoreListClick);
}

function handleAdminSignup(event) {
  event.preventDefault();
  clearAuthMessage();

  const username = normalizeNick(signupNick.value);
  if (!username) {
    showAuthMessage("Digite um nick válido.");
    return;
  }

  if (users.some((user) => user.role === "admin")) {
    showAuthMessage("Admin temporário já existe nesta aba.");
    return;
  }

  const admin = {
    id: createId(),
    username,
    password: signupPassword.value,
    fullName: signupName.value.trim() || username,
    role: "admin",
    storeId: null,
  };

  users.push(admin);
  signupForm.reset();
  openProfile(admin);
}

function handleLogin(event) {
  event.preventDefault();
  clearAuthMessage();

  const username = normalizeNick(loginNick.value);
  const matchedUser = users.find((user) => user.username === username && user.password === loginPassword.value);

  if (!matchedUser) {
    showAuthMessage("Login temporário não encontrado. Crie um admin nesta aba.");
    return;
  }

  openProfile(matchedUser);
}

function openProfile(profile) {
  currentProfile = profile;
  authScreen.hidden = true;
  appView.hidden = false;

  if (profile.role === "admin") {
    activeStoreContext = null;
    sessionRole.textContent = `Admin · ${profile.username}`;
    backAdminButton.hidden = true;
    adminView.hidden = false;
    storeView.hidden = true;
    renderAll();
    return;
  }

  activeStoreContext = stores.find((store) => store.id === profile.storeId) || null;
  sessionRole.textContent = `Loja · ${activeStoreContext?.name || profile.username}`;
  backAdminButton.hidden = true;
  adminView.hidden = true;
  storeView.hidden = false;
  renderAll();
}

function handleLogout() {
  currentProfile = null;
  activeStoreContext = null;
  resetLeadForm();
  showAuth();
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

  $$("[data-auth-tab]").forEach((tab) => {
    tab.classList.toggle("is-active", tab.dataset.authTab === tabName);
  });
}

function handleCreateStore(event) {
  event.preventDefault();
  clearStoreMessage();

  if (!currentProfile || currentProfile.role !== "admin") return;

  const username = normalizeNick(storeNick.value);
  if (!username) {
    showStoreMessage("Digite um nick válido para a loja.");
    return;
  }

  if (users.some((user) => user.username === username)) {
    showStoreMessage("Esse nick já existe nesta aba.");
    return;
  }

  const store = {
    id: createId(),
    name: storeName.value.trim(),
    username,
    createdAt: new Date().toISOString(),
  };
  const storeUser = {
    id: createId(),
    username,
    password: storePassword.value,
    fullName: store.name,
    role: "store",
    storeId: store.id,
  };

  stores.push(store);
  users.push(storeUser);
  storeForm.reset();
  showStoreMessage("Loja temporária criada nesta aba.", "success");
  renderAll();
}

function handleStoreListClick(event) {
  const button = event.target.closest("[data-store-login]");
  if (!button) return;

  const user = users.find((item) => item.role === "store" && item.storeId === button.dataset.storeLogin);
  if (user) guardUnsavedOptions(() => openProfile(user));
}

function returnToAdmin() {
  const admin = users.find((user) => user.role === "admin");
  if (admin) openProfile(admin);
}

function handleLeadSubmit(event) {
  event.preventDefault();

  const store = getActiveStore();
  if (!store) {
    showFormMessage("Entre em uma loja para cadastrar leads.");
    return;
  }

  const payload = {
    name: nameInput.value.trim(),
    phone: phoneInput.value.trim(),
    channel: selectedValues.channel,
    campaign: selectedValues.campaign,
    conversationStart: selectedValues.conversationStart,
    conclusion: selectedValues.conclusion,
    visited: selectedValues.visited,
    bought: selectedValues.bought,
    storeId: store.id,
    storeName: store.name,
    updatedAt: new Date().toISOString(),
  };

  if (!payload.name || !payload.phone) {
    showFormMessage("Preencha nome e telefone.");
    return;
  }

  if (editingIdInput.value) {
    leads = leads.map((lead) => (lead.id === editingIdInput.value ? { ...lead, ...payload } : lead));
    showFormMessage("Lead atualizado nesta aba.", "success");
  } else {
    leads.unshift({ id: createId(), createdAt: new Date().toISOString(), ...payload });
    showFormMessage("Lead salvo temporariamente nesta aba.", "success");
  }

  resetLeadForm();
  renderAll();
}

function handleLeadListClick(event) {
  const button = event.target.closest("[data-action]");
  if (!button) return;

  if (button.dataset.action === "edit") guardUnsavedOptions(() => editLead(button.dataset.id));
  if (button.dataset.action === "delete") deleteLead(button.dataset.id);
}

function editLead(id) {
  const lead = leads.find((item) => item.id === id);
  if (!lead) return;

  editingIdInput.value = lead.id;
  nameInput.value = lead.name;
  phoneInput.value = lead.phone;
  selectedValues = {
    channel: lead.channel || "",
    campaign: lead.campaign || "",
    conversationStart: lead.conversationStart || "",
    conclusion: lead.conclusion || "",
    visited: lead.visited || "",
    bought: lead.bought || "",
  };
  formTitle.textContent = "Editar lead";
  submitButton.textContent = "Atualizar lead";
  cancelEditButton.hidden = false;
  renderChoiceButtons();
}

function deleteLead(id) {
  leads = leads.filter((lead) => lead.id !== id);
  renderAll();
}

function resetLeadForm() {
  form.reset();
  editingIdInput.value = "";
  selectedValues = createEmptySelection();
  formTitle.textContent = "Cadastrar lead";
  submitButton.textContent = "Salvar lead";
  cancelEditButton.hidden = true;
  renderChoiceButtons();
}

function renderAll() {
  renderChoiceButtons();
  renderFilters();
  renderOptionsEditors();
  renderAdminDashboard();
  renderLeadList();
  renderTodayCount();
}

function renderAdminDashboard() {
  $("#totalStores").textContent = stores.length;
  $("#adminTotalLeads").textContent = leads.length;
  $("#adminSalesCount").textContent = countByValue(leads, "bought", "Sim");
  $("#adminConversionRate").textContent = formatPercent(countByValue(leads, "bought", "Sim"), leads.length);
  renderStoreList();
  renderAdminAnalytics();
}

function renderStoreList() {
  storeEmptyState.hidden = stores.length > 0;
  storeList.innerHTML = stores
    .map(
      (store) => `
        <article class="lead-card">
          <div>
            <strong>${escapeHtml(store.name)}</strong>
            <span>${escapeHtml(store.username)}</span>
          </div>
          <button class="secondary-button" type="button" data-store-login="${store.id}">Entrar</button>
        </article>
      `,
    )
    .join("");

  analyticsStoreFilter.innerHTML = '<option value="">Todas as lojas</option>' +
    stores.map((store) => `<option value="${store.id}">${escapeHtml(store.name)}</option>`).join("");
}

function renderLeadList() {
  const filteredLeads = getFilteredLeads();
  emptyState.hidden = filteredLeads.length > 0;
  leadList.innerHTML = filteredLeads
    .map(
      (lead) => `
        <article class="lead-card">
          <div>
            <strong>${escapeHtml(lead.name)}</strong>
            <span>${escapeHtml(lead.phone)} · ${escapeHtml(lead.storeName || "")}</span>
          </div>
          <div class="lead-tags">
            ${renderTag(lead.channel)}
            ${renderTag(lead.campaign)}
            ${renderTag(lead.conclusion)}
            ${renderTag(lead.visited ? `Visitou: ${lead.visited}` : "")}
            ${renderTag(lead.bought ? `Comprou: ${lead.bought}` : "")}
          </div>
          <div class="card-actions">
            <button class="mini-button" type="button" data-action="edit" data-id="${lead.id}">Editar</button>
            <button class="mini-button danger" type="button" data-action="delete" data-id="${lead.id}">Excluir</button>
          </div>
        </article>
      `,
    )
    .join("");

  const storeLeads = getVisibleStoreLeads();
  $("#totalLeads").textContent = storeLeads.length;
  $("#storeVisits").textContent = countByValue(storeLeads, "visited", "Sim");
  $("#salesCount").textContent = countByValue(storeLeads, "bought", "Sim");
  $("#conversionRate").textContent = formatPercent(countByValue(storeLeads, "bought", "Sim"), storeLeads.length);
}

function renderChoiceButtons() {
  optionGroups.forEach((group) => {
    $$(`[data-choice-group="${group}"]`).forEach((container) => {
      container.innerHTML = options[group]
        .map((value) => {
          const isActive = selectedValues[group] === value;
          return `<button class="choice-button ${isActive ? "is-active" : ""}" type="button" data-choice="${group}" data-value="${escapeHtml(value)}">${escapeHtml(value)}</button>`;
        })
        .join("");

      if (fixedOptionGroups.has(group)) {
        container.insertAdjacentHTML(
          "beforeend",
          `<button class="choice-button ${selectedValues[group] === "" ? "is-active" : ""}" type="button" data-choice="${group}" data-value="">Limpar</button>`,
        );
      }

      container.querySelectorAll("[data-choice]").forEach((button) => {
        button.addEventListener("click", () => {
          selectedValues[group] = button.dataset.value;
          renderChoiceButtons();
        });
      });
    });
  });
}

function renderFilters() {
  fillSelect(channelFilter, options.channel, "Todos");
  fillSelect(campaignFilter, options.campaign, "Todos");
  fillSelect(conversationStartFilter, options.conversationStart, "Todos");
  fillSelect(conclusionFilter, options.conclusion, "Todos");
  fillSelect(visitedFilter, options.visited, "Todos");
  fillSelect(boughtFilter, [...options.bought, "sem-resposta"], "Todos");
}

function renderOptionsEditors() {
  renderOptionsEditor(adminOptionsList, "admin");
  renderOptionsEditor(storeOptionsList, "store");
}

function renderOptionsEditor(container, scope) {
  container.innerHTML = optionGroups
    .map((group) => {
      const isFixed = fixedOptionGroups.has(group);
      const chips = options[group]
        .map((value, index) =>
          isFixed
            ? `<span class="option-chip">${escapeHtml(value)}</span>`
            : `<div class="option-row" data-group="${group}" data-index="${index}">
                <input value="${escapeHtml(value)}" aria-label="${labels[group]}" />
                <button class="mini-button option-save" type="button" data-option-action="save" hidden>Salvar</button>
                <button class="mini-button danger" type="button" data-option-action="delete">Excluir</button>
              </div>`,
        )
        .join("");
      const addButton = isFixed
        ? ""
        : `<button class="mini-button" type="button" data-option-action="add" data-group="${group}">Adicionar</button>`;

      return `
        <section class="option-group" data-scope="${scope}">
          <div class="option-group-heading">
            <strong>${labels[group]}</strong>
            ${addButton}
          </div>
          <div class="option-list">${chips}</div>
        </section>
      `;
    })
    .join("");
}

function handleOptionsEditorInput(event) {
  const row = event.target.closest(".option-row");
  if (!row) return;

  dirtyOptionKeys.add(`${row.dataset.group}:${row.dataset.index}`);
  const saveButton = row.querySelector("[data-option-action='save']");
  if (saveButton) saveButton.hidden = false;
}

function handleOptionsEditorClick(event) {
  const button = event.target.closest("[data-option-action]");
  if (!button) return;

  const action = button.dataset.optionAction;
  const row = button.closest(".option-row");
  const group = button.dataset.group || row?.dataset.group;
  const messageTarget = button.closest("#adminOptionsList") ? adminOptionsMessage : storeOptionsMessage;

  if (fixedOptionGroups.has(group)) return;

  if (action === "add") {
    options[group].push("Nova opção");
    dirtyOptionKeys.add(`${group}:${options[group].length - 1}`);
    renderOptionsEditors();
    return;
  }

  if (!row) return;

  const index = Number(row.dataset.index);
  if (action === "delete") {
    options[group].splice(index, 1);
    dirtyOptionKeys.clear();
    renderAll();
    showOptionsMessage(messageTarget, "Opção removida nesta aba.", "success");
  }

  if (action === "save") {
    const value = row.querySelector("input").value.trim();
    if (!value) {
      showOptionsMessage(messageTarget, "Digite um valor.");
      return;
    }
    options[group][index] = value;
    dirtyOptionKeys.delete(`${group}:${index}`);
    renderAll();
    showOptionsMessage(messageTarget, "Opção salva nesta aba.", "success");
  }
}

function toggleStoreOptionsMode() {
  storeOptionsPanel.hidden = !storeOptionsPanel.hidden;
}

function hasUnsavedOptions() {
  return dirtyOptionKeys.size > 0;
}

function guardUnsavedOptions(nextAction) {
  if (!hasUnsavedOptions()) {
    nextAction();
    return;
  }

  pendingUnsavedAction = nextAction;
  unsavedOptionsModal.hidden = false;
}

function closeUnsavedOptionsModal() {
  pendingUnsavedAction = null;
  unsavedOptionsModal.hidden = true;
}

function discardUnsavedOptionsAndContinue() {
  dirtyOptionKeys.clear();
  continuePendingAction();
}

function saveUnsavedOptionsAndContinue() {
  dirtyOptionKeys.clear();
  renderAll();
  continuePendingAction();
}

function continuePendingAction() {
  const nextAction = pendingUnsavedAction;
  closeUnsavedOptionsModal();
  if (nextAction) nextAction();
}

function renderAdminAnalytics() {
  const filtered = getAnalyticsLeads();
  const total = filtered.length;
  const visited = countByValue(filtered, "visited", "Sim");
  const bought = countByValue(filtered, "bought", "Sim");

  $("#analyticsTotalLeads").textContent = total;
  $("#analyticsVisitedLeads").textContent = visited;
  $("#analyticsBoughtLeads").textContent = bought;
  $("#analyticsConversionRate").textContent = formatPercent(bought, total);
  $("#analyticsFunnelLabel").textContent = total ? `${total} leads` : "Sem dados";
  $("#analyticsRatesLabel").textContent = total ? `${formatPercent(bought, total)} conversão` : "Sem dados";

  renderMetricBars($("#analyticsFunnelChart"), [
    ["Leads", total],
    ["Visitaram", visited],
    ["Compraram", bought],
  ]);
  renderMetricBars($("#analyticsRatesChart"), [
    ["Visita", total ? Math.round((visited / total) * 100) : 0],
    ["Compra", total ? Math.round((bought / total) * 100) : 0],
  ], "%");
  renderRanking($("#campaignRanking"), $("#topCampaignLabel"), filtered, "campaign");
  renderRanking($("#storeRanking"), $("#topStoreLabel"), filtered, "storeName");
  renderRanking($("#conversationStartRanking"), $("#topStartLabel"), filtered, "conversationStart");
  renderRanking($("#conclusionRanking"), $("#topConclusionLabel"), filtered, "conclusion");
  renderRanking($("#visitedRanking"), $("#topVisitedLabel"), filtered, "visited");
  renderRanking($("#boughtRanking"), $("#topBoughtLabel"), filtered, "bought");
}

function renderMetricBars(container, rows, suffix = "") {
  const max = Math.max(...rows.map(([, value]) => value), 1);
  container.innerHTML = rows
    .map(([label, value]) => `
      <div class="metric-bar-row">
        <span>${escapeHtml(label)}</span>
        <div class="metric-bar-track"><i style="width:${Math.max((value / max) * 100, value ? 8 : 0)}%"></i></div>
        <strong>${value}${suffix}</strong>
      </div>
    `)
    .join("");
}

function renderRanking(container, labelElement, rows, key) {
  const ranking = Object.entries(
    rows.reduce((acc, row) => {
      const value = row[key] || "Sem resposta";
      acc[value] = (acc[value] || 0) + 1;
      return acc;
    }, {}),
  ).sort((a, b) => b[1] - a[1]);
  const max = ranking[0]?.[1] || 1;

  labelElement.textContent = ranking[0] ? `${ranking[0][0]} (${ranking[0][1]})` : "Sem dados";
  container.innerHTML = ranking
    .slice(0, 5)
    .map(([label, value]) => `
      <div class="ranking-row">
        <span>${escapeHtml(label)}</span>
        <div class="ranking-track"><i style="width:${(value / max) * 100}%"></i></div>
        <strong>${value}</strong>
      </div>
    `)
    .join("");
}

function getFilteredLeads() {
  const visible = getVisibleStoreLeads();
  const search = searchInput.value.trim().toLowerCase();
  return visible.filter((lead) => {
    const matchesSearch = !search || [lead.name, lead.phone, lead.storeName].some((value) => value.toLowerCase().includes(search));
    const matchesSimpleFilters =
      matchesFilter(lead.channel, channelFilter.value) &&
      matchesFilter(lead.campaign, campaignFilter.value) &&
      matchesFilter(lead.conversationStart, conversationStartFilter.value) &&
      matchesFilter(lead.conclusion, conclusionFilter.value) &&
      matchesFilter(lead.visited, visitedFilter.value) &&
      matchesFilter(lead.bought || "sem-resposta", boughtFilter.value);
    const createdDate = lead.createdAt.slice(0, 10);
    const matchesStart = !startDateFilter.value || createdDate >= startDateFilter.value;
    const matchesEnd = !endDateFilter.value || createdDate <= endDateFilter.value;

    return matchesSearch && matchesSimpleFilters && matchesStart && matchesEnd;
  });
}

function getVisibleStoreLeads() {
  const store = getActiveStore();
  if (!store) return currentProfile?.role === "admin" ? leads : [];
  return leads.filter((lead) => lead.storeId === store.id);
}

function getAnalyticsLeads() {
  let result = [...leads];
  if (analyticsStoreFilter.value) {
    result = result.filter((lead) => lead.storeId === analyticsStoreFilter.value);
  }

  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  if (mode === "single" && analyticsSingleDate.value) {
    result = result.filter((lead) => lead.createdAt.slice(0, 10) === analyticsSingleDate.value);
  }
  if (mode === "range") {
    if (analyticsStartDate.value) result = result.filter((lead) => lead.createdAt.slice(0, 10) >= analyticsStartDate.value);
    if (analyticsEndDate.value) result = result.filter((lead) => lead.createdAt.slice(0, 10) <= analyticsEndDate.value);
  }

  return result;
}

function getActiveStore() {
  if (currentProfile?.role === "store") return activeStoreContext;
  return activeStoreContext;
}

function toggleAnalytics() {
  analyticsContent.hidden = !analyticsContent.hidden;
  analyticsToggle.setAttribute("aria-expanded", String(!analyticsContent.hidden));
  analyticsToggleLabel.textContent = analyticsContent.hidden ? "Mostrar análise" : "Ocultar análise";
}

function setAnalyticsDateMode(mode) {
  analyticsDateModeButtons.forEach((button) => {
    button.classList.toggle("is-active", button.dataset.analyticsDateMode === mode);
  });
  analyticsSingleDateField.hidden = mode !== "single";
  analyticsRangeDateFields.forEach((field) => {
    field.hidden = mode !== "range";
  });
  renderAdminAnalytics();
}

function setAnalyticsQuickRange(range) {
  setAnalyticsDateMode("range");
  const today = new Date();
  const start = new Date(today);
  if (range === "week") start.setDate(today.getDate() - 6);
  if (range === "month") start.setMonth(today.getMonth() - 1);
  if (range === "year") start.setFullYear(today.getFullYear() - 1);
  analyticsStartDate.value = toDateInput(start);
  analyticsEndDate.value = toDateInput(today);
  renderAdminAnalytics();
}

function toggleFilters() {
  filtersPanel.hidden = !filtersPanel.hidden;
}

function clearFilters() {
  [searchInput, channelFilter, campaignFilter, conversationStartFilter, conclusionFilter, visitedFilter, boughtFilter, startDateFilter, endDateFilter].forEach((element) => {
    element.value = "";
  });
  renderLeadList();
}

function renderTodayCount() {
  const today = toDateInput(new Date());
  const count = getVisibleStoreLeads().filter((lead) => lead.createdAt.slice(0, 10) === today).length;
  $("#todayCount").textContent = `${count} ${count === 1 ? "lead" : "leads"}`;
}

function setTodayLabel() {
  const label = new Intl.DateTimeFormat("pt-BR", {
    weekday: "long",
    day: "2-digit",
    month: "long",
  }).format(new Date());

  $("#todayLabel").textContent = label.charAt(0).toUpperCase() + label.slice(1);
}

function fillSelect(select, values, firstLabel) {
  const currentValue = select.value;
  select.innerHTML = `<option value="">${firstLabel}</option>` +
    values.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join("");
  select.value = values.includes(currentValue) ? currentValue : "";
}

function matchesFilter(value, filterValue) {
  return !filterValue || value === filterValue;
}

function countByValue(rows, key, value) {
  return rows.filter((row) => row[key] === value).length;
}

function formatPercent(value, total) {
  return total ? `${Math.round((value / total) * 100)}%` : "0%";
}

function createEmptySelection() {
  return optionGroups.reduce((acc, group) => ({ ...acc, [group]: "" }), {});
}

function cloneOptions(source) {
  return Object.fromEntries(Object.entries(source).map(([key, value]) => [key, [...value]]));
}

function normalizeNick(value) {
  return value.trim().toLowerCase().replace(/\s+/g, "-");
}

function createId() {
  return crypto.randomUUID ? crypto.randomUUID() : String(Date.now() + Math.random());
}

function formatPhone(value) {
  const digits = value.replace(/\D/g, "").slice(0, 11);
  if (digits.length <= 2) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 2)}) ${digits.slice(2)}`;
  if (digits.length <= 10) return `(${digits.slice(0, 2)}) ${digits.slice(2, 6)}-${digits.slice(6)}`;
  return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7)}`;
}

function toDateInput(date) {
  return date.toISOString().slice(0, 10);
}

function renderTag(value) {
  return value ? `<span>${escapeHtml(value)}</span>` : "";
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function togglePassword(button) {
  const input = $(`#${button.dataset.togglePassword}`);
  const isPassword = input.type === "password";
  input.type = isPassword ? "text" : "password";
  button.textContent = isPassword ? "Ocultar" : "Ver";
}

function showAuthMessage(message, type = "error") {
  authMessage.textContent = message;
  authMessage.classList.toggle("success", type === "success");
}

function clearAuthMessage() {
  showAuthMessage("");
}

function showStoreMessage(message, type = "error") {
  storeMessage.textContent = message;
  storeMessage.classList.toggle("success", type === "success");
}

function clearStoreMessage() {
  showStoreMessage("");
}

function showFormMessage(message, type = "error") {
  formMessage.textContent = message;
  formMessage.classList.toggle("success", type === "success");
}

function showOptionsMessage(target, message, type = "error") {
  target.textContent = message;
  target.classList.toggle("success", type === "success");
}
