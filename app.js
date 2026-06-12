const SUPABASE_URL = "https://menlvmsgkhgqxiydphbn.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1lbmx2bXNna2hncXhpeWRwaGJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEyNTYxNzEsImV4cCI6MjA5NjgzMjE3MX0.ylQcT5KnVDvdP3Wa8ZKdI6FpXWnjXAkpzpfzRw0FP30";
const SESSION_STORAGE_KEY = "lead-control-session";
const THEME_STORAGE_KEY = "lead-control-theme";

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
const fixedChannelOptions = new Set(["Instagram", "Facebook"]);
const nativeYesNoOptions = ["Sim", "Não"];
const defaultOptions = {
  channel: ["WhatsApp", "Instagram", "Facebook", "Ligação"],
  campaign: ["Orgânico", "Anúncio", "Indicação"],
  conversationStart: ["Preço", "Consulta", "Armação", "Lente"],
  conclusion: ["Aguardando", "Retornar", "Finalizado"],
  visited: nativeYesNoOptions,
  bought: nativeYesNoOptions,
};

let supabaseClient = null;
let options = cloneOptions(defaultOptions);
let optionRecords = createDefaultOptionRecords();
let currentProfile = null;
let activeStoreContext = null;
let stores = [];
let leads = [];
let pendingUnsavedAction = null;
const dirtyOptionKeys = new Set();
const dirtyOptionValues = new Map();
let selectedValues = createEmptySelection();

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

const authScreen = $("#authScreen");
const appView = $("#appView");
const adminView = $("#adminView");
const storeView = $("#storeView");
const sessionRole = $("#sessionRole");
const appNotification = $("#appNotification");
const themeToggle = $("#themeToggle");
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
const purchaseDetails = $("#purchaseDetails");
const purchaseAmountInput = $("#purchaseAmount");
const serviceOrderInput = $("#serviceOrder");
const storeOptionsPanel = $("#storeOptionsPanel");
const storeOptionsList = $("#storeOptionsList");
const storeOptionsMessage = $("#storeOptionsMessage");
const unsavedOptionsModal = $("#unsavedOptionsModal");
const unsavedCancel = $("#unsavedCancel");
const unsavedDiscard = $("#unsavedDiscard");
const unsavedSave = $("#unsavedSave");
let notificationTimer = null;

document.addEventListener("DOMContentLoaded", () => {
  init().catch((error) => {
    showAuth();
    showAuthMessage(readableError(error));
  });
});

async function init() {
  applyStoredTheme();
  setTodayLabel();
  bindEvents();
  showAuth();
  renderAll();
  initializeSupabase();

  if (!isSupabaseReady()) {
    showAuthMessage("Cole a URL e a chave pública/anon do Supabase no topo do app.js.");
    return;
  }

  await restoreSession();
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
  purchaseAmountInput.addEventListener("input", () => {
    purchaseAmountInput.value = purchaseAmountInput.value.replace(/[^\d.,]/g, "");
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
  themeToggle.addEventListener("click", toggleTheme);
}

function initializeSupabase() {
  if (!isSupabaseConfigured() || !window.supabase?.createClient) return;

  supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}

function isSupabaseConfigured() {
  return (
    SUPABASE_URL.startsWith("https://") &&
    !SUPABASE_URL.includes("SEU-PROJETO") &&
    SUPABASE_ANON_KEY &&
    !SUPABASE_ANON_KEY.includes("SUA_CHAVE")
  );
}

function isSupabaseReady() {
  return Boolean(supabaseClient);
}

async function handleAdminSignup(event) {
  event.preventDefault();
  clearAuthMessage();

  const username = normalizeNick(signupNick.value);
  if (!username) {
    showAuthMessage("Digite um nick válido.");
    return;
  }

  try {
    setFormBusy(signupForm, true);
    const row = firstRow(await rpc("lc_create_admin", {
      p_full_name: signupName.value.trim(),
      p_nick: username,
      p_password: signupPassword.value,
    }));
    signupForm.reset();
    await openProfile(profileFromSessionRow(row));
  } catch (error) {
    showAuthMessage(readableError(error));
  } finally {
    setFormBusy(signupForm, false);
  }
}

async function handleLogin(event) {
  event.preventDefault();
  clearAuthMessage();

  const username = normalizeNick(loginNick.value);
  if (!username) {
    showAuthMessage("Digite seu nick.");
    return;
  }

  try {
    setFormBusy(loginForm, true);
    const row = firstRow(await rpc("lc_login", {
      p_nick: username,
      p_password: loginPassword.value,
    }));
    loginForm.reset();
    await openProfile(profileFromSessionRow(row));
  } catch (error) {
    showAuthMessage(readableError(error));
  } finally {
    setFormBusy(loginForm, false);
  }
}

async function restoreSession() {
  const saved = readStoredSession();
  if (!saved?.sessionToken) return;

  if (saved.expiresAt && new Date(saved.expiresAt) <= new Date()) {
    clearStoredSession();
    return;
  }

  try {
    const row = firstRow(await rpc("lc_current_profile", {
      p_session_token: saved.sessionToken,
    }));
    await openProfile(profileFromProfileRow(row, saved.sessionToken, saved.expiresAt));
  } catch (error) {
    clearStoredSession();
    showAuthMessage("Sessão expirada. Entre novamente.");
  }
}

async function openProfile(profile) {
  currentProfile = profile;
  saveStoredSession(profile);

  authScreen.hidden = true;
  appView.hidden = false;
  await refreshRemoteState();

  if (profile.role === "admin") {
    showAdminDashboard();
    return;
  }

  showStoreDashboard();
}

function showAdminDashboard() {
  activeStoreContext = null;
  sessionRole.textContent = `Admin · ${currentProfile.username}`;
  backAdminButton.hidden = true;
  adminView.hidden = false;
  storeView.hidden = true;
  renderAll();
}

function showStoreDashboard() {
  activeStoreContext = stores.find((store) => store.id === currentProfile.storeId) || {
    id: currentProfile.storeId,
    name: currentProfile.storeName || currentProfile.username,
    username: currentProfile.username,
  };
  sessionRole.textContent = `Loja · ${activeStoreContext?.name || currentProfile.username}`;
  backAdminButton.hidden = true;
  toggleOptionsEditButton.hidden = true;
  clearFormButton.hidden = true;
  storeOptionsPanel.hidden = true;
  adminView.hidden = true;
  storeView.hidden = false;
  renderAll();
}

async function handleLogout() {
  try {
    if (currentProfile?.sessionToken) {
      await rpc("lc_logout", { p_session_token: currentProfile.sessionToken });
    }
  } catch (error) {
    console.warn(error);
  } finally {
    clearStoredSession();
    currentProfile = null;
    activeStoreContext = null;
    stores = [];
    leads = [];
    options = cloneOptions(defaultOptions);
    optionRecords = createDefaultOptionRecords();
    resetLeadForm();
    showAuth();
    renderAll();
  }
}

function showAuth() {
  clearAppNotification();
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

async function handleCreateStore(event) {
  event.preventDefault();
  clearStoreMessage();

  if (!currentProfile || currentProfile.role !== "admin") return;

  const username = normalizeNick(storeNick.value);
  if (!username) {
    showStoreMessage("Digite um nick válido para a loja.");
    return;
  }

  try {
    setFormBusy(storeForm, true);
    await authenticatedRpc("lc_create_store", {
      p_name: storeName.value.trim(),
      p_nick: username,
      p_password: storePassword.value,
    });
    storeForm.reset();
    await refreshRemoteState();
    showStoreMessage("Loja criada no Supabase.", "success");
    renderAll();
  } catch (error) {
    showStoreMessage(readableError(error));
  } finally {
    setFormBusy(storeForm, false);
  }
}

function handleStoreListClick(event) {
  const button = event.target.closest("[data-store-login]");
  if (!button || currentProfile?.role !== "admin") return;
  guardUnsavedOptions(() => openStoreAsAdmin(button.dataset.storeLogin));
}

function openStoreAsAdmin(storeId) {
  const store = stores.find((item) => item.id === storeId);
  if (!store) return;

  activeStoreContext = store;
  sessionRole.textContent = `Admin · ${store.name}`;
  backAdminButton.hidden = false;
  toggleOptionsEditButton.hidden = false;
  clearFormButton.hidden = true;
  adminView.hidden = true;
  storeView.hidden = false;
  resetLeadForm();
  renderAll();
}

function returnToAdmin() {
  if (currentProfile?.role !== "admin") return;
  clearFormButton.hidden = false;
  showAdminDashboard();
  resetLeadForm();
}

async function handleLeadSubmit(event) {
  event.preventDefault();

  const store = getActiveStore();
  if (!store) {
    showFormMessage("Entre em uma loja para cadastrar leads.");
    return;
  }

  const payload = {
    p_lead_id: editingIdInput.value || null,
    p_name: nameInput.value.trim(),
    p_phone: phoneInput.value.trim(),
    p_channel: selectedValues.channel,
    p_campaign: selectedValues.campaign,
    p_conversation_start: selectedValues.conversationStart,
    p_conclusion: selectedValues.conclusion,
    p_visited: selectedValues.visited,
    p_bought: selectedValues.bought,
    p_purchase_amount: selectedValues.bought === "Sim" ? parseCurrencyInput(purchaseAmountInput.value) : null,
    p_service_order: selectedValues.bought === "Sim" ? serviceOrderInput.value.trim() : null,
    p_store_id: store.id,
  };

  if (!payload.p_name || !payload.p_phone) {
    showFormMessage("Preencha nome e telefone.");
    return;
  }

  if (payload.p_visited === "Sim" && !payload.p_bought) {
    showFormMessage("Informe se o lead comprou ou não.");
    return;
  }

  if (payload.p_bought === "Sim" && (!payload.p_purchase_amount || payload.p_purchase_amount <= 0 || !payload.p_service_order)) {
    showFormMessage("Informe o valor da compra e a OS.");
    purchaseDetails.hidden = false;
    if (!payload.p_purchase_amount || payload.p_purchase_amount <= 0) purchaseAmountInput.focus();
    else serviceOrderInput.focus();
    return;
  }

  try {
    setFormBusy(form, true);
    await authenticatedRpc("lc_upsert_lead", payload);
    const wasEditing = Boolean(editingIdInput.value);
    await refreshRemoteState();
    resetLeadForm();
    showFormMessage(wasEditing ? "Lead atualizado no Supabase." : "Lead salvo no Supabase.", "success");
    renderAll();
  } catch (error) {
    showFormMessage(readableError(error));
  } finally {
    setFormBusy(form, false);
  }
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
  purchaseAmountInput.value = lead.purchaseAmount ? formatCurrencyInput(lead.purchaseAmount) : "";
  serviceOrderInput.value = lead.serviceOrder || "";
  formTitle.textContent = "Editar lead";
  submitButton.textContent = "Atualizar lead";
  cancelEditButton.hidden = false;
  updatePurchaseDetailsVisibility();
  renderChoiceButtons();
}

async function deleteLead(id) {
  try {
    await authenticatedRpc("lc_delete_lead", { p_lead_id: id });
    await refreshRemoteState();
    renderAll();
  } catch (error) {
    showFormMessage(readableError(error));
  }
}

function resetLeadForm() {
  form.reset();
  editingIdInput.value = "";
  selectedValues = createEmptySelection();
  purchaseAmountInput.value = "";
  serviceOrderInput.value = "";
  formTitle.textContent = "Cadastrar lead";
  submitButton.textContent = "Salvar lead";
  cancelEditButton.hidden = true;
  updatePurchaseDetailsVisibility();
  renderChoiceButtons();
}

async function refreshRemoteState() {
  if (!currentProfile?.sessionToken) return;

  const [storeRows, optionRows, leadRows] = await Promise.all([
    authenticatedRpc("lc_list_stores"),
    authenticatedRpc("lc_list_options"),
    authenticatedRpc("lc_list_leads"),
  ]);

  stores = (storeRows || []).map(mapStoreRow);
  leads = (leadRows || []).map(mapLeadRow);
  applyOptionRows(optionRows || []);

  if (activeStoreContext) {
    activeStoreContext = stores.find((store) => store.id === activeStoreContext.id) || activeStoreContext;
  }
}

async function refreshOptions() {
  applyOptionRows(await authenticatedRpc("lc_list_options"));
  renderAll();
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
            ${renderTag(lead.purchaseAmount ? `Valor: ${formatCurrency(lead.purchaseAmount)}` : "")}
            ${renderTag(lead.serviceOrder ? `OS: ${lead.serviceOrder}` : "")}
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
          const className = [
            "choice-button",
            isActive ? "is-active" : "",
            group === "channel" && selectedValues.channel && !isActive ? "is-dimmed" : "",
            (group === "visited" || group === "bought") && selectedValues[group] && !isActive ? "is-dimmed" : "",
            getChoiceClass(group, value),
          ].filter(Boolean).join(" ");
          return `<button class="${className}" type="button" data-choice="${group}" data-value="${escapeHtml(value)}">${getChoiceLabel(group, value)}</button>`;
        })
        .join("");

      container.querySelectorAll("[data-choice]").forEach((button) => {
        button.addEventListener("click", () => {
          selectedValues[group] =
            fixedOptionGroups.has(group) && selectedValues[group] === button.dataset.value
              ? ""
              : button.dataset.value;
          if (group === "bought" && selectedValues.bought !== "Sim") {
            purchaseAmountInput.value = "";
            serviceOrderInput.value = "";
          }
          renderChoiceButtons();
          updatePurchaseDetailsVisibility();
          if (group === "bought" && selectedValues.bought === "Sim") {
            purchaseAmountInput.focus();
          }
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
      const chips = (optionRecords[group] || [])
        .map((record) =>
          isFixed || record.fixed
            ? `<span class="option-chip">${escapeHtml(record.value)}</span>`
            : `<div class="option-row" data-group="${group}" data-option-id="${record.id}">
                <input value="${escapeHtml(dirtyOptionValues.get(record.id) ?? record.value)}" aria-label="${labels[group]}" />
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

  dirtyOptionKeys.add(row.dataset.optionId);
  dirtyOptionValues.set(row.dataset.optionId, event.target.value);
  const saveButton = row.querySelector("[data-option-action='save']");
  if (saveButton) saveButton.hidden = false;
}

async function handleOptionsEditorClick(event) {
  const button = event.target.closest("[data-option-action]");
  if (!button) return;

  const action = button.dataset.optionAction;
  const row = button.closest(".option-row");
  const group = button.dataset.group || row?.dataset.group;
  const messageTarget = button.closest("#adminOptionsList") ? adminOptionsMessage : storeOptionsMessage;

  if (fixedOptionGroups.has(group)) return;
  if (row && getOptionRecord(group, row.dataset.optionId)?.fixed) return;

  try {
    button.disabled = true;

    if (action === "add") {
      await authenticatedRpc("lc_add_option", { p_group_key: group });
      await refreshOptions();
      showOptionsMessage(messageTarget, "Opção criada no Supabase.", "success");
      return;
    }

    if (!row) return;

    if (action === "delete") {
      await authenticatedRpc("lc_delete_option", { p_option_id: row.dataset.optionId });
      dirtyOptionKeys.delete(row.dataset.optionId);
      dirtyOptionValues.delete(row.dataset.optionId);
      await refreshOptions();
      showOptionsMessage(messageTarget, "Opção removida no Supabase.", "success");
    }

    if (action === "save") {
      const value = row.querySelector("input").value.trim();
      if (!value) {
        showOptionsMessage(messageTarget, "Digite um valor.");
        return;
      }
      await authenticatedRpc("lc_update_option", {
        p_option_id: row.dataset.optionId,
        p_value: value,
      });
      dirtyOptionKeys.delete(row.dataset.optionId);
      dirtyOptionValues.delete(row.dataset.optionId);
      await refreshOptions();
      showOptionsMessage(messageTarget, "Opção salva no Supabase.", "success");
    }
  } catch (error) {
    showOptionsMessage(messageTarget, readableError(error));
  } finally {
    button.disabled = false;
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
  dirtyOptionValues.clear();
  renderOptionsEditors();
  continuePendingAction();
}

async function saveUnsavedOptionsAndContinue() {
  try {
    await saveDirtyOptions();
    continuePendingAction();
  } catch (error) {
    showOptionsMessage(storeOptionsPanel.hidden ? adminOptionsMessage : storeOptionsMessage, readableError(error));
  }
}

async function saveDirtyOptions() {
  for (const optionId of Array.from(dirtyOptionKeys)) {
    const value = dirtyOptionValues.get(optionId)?.trim();
    if (!value) throw new Error("Digite um valor para salvar as opções.");
    await authenticatedRpc("lc_update_option", {
      p_option_id: optionId,
      p_value: value,
    });
  }

  dirtyOptionKeys.clear();
  dirtyOptionValues.clear();
  await refreshOptions();
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
    const matchesSearch = !search || [lead.name, lead.phone, lead.storeName].some((value) => String(value || "").toLowerCase().includes(search));
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
  if (currentProfile?.role === "store") {
    return activeStoreContext || stores.find((store) => store.id === currentProfile.storeId) || null;
  }
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

async function rpc(functionName, args = {}) {
  if (!supabaseClient) {
    throw new Error("Supabase não configurado. Informe URL e chave pública/anon no app.js.");
  }

  const { data, error } = await supabaseClient.rpc(functionName, args);
  if (error) throw error;
  return data;
}

async function authenticatedRpc(functionName, args = {}) {
  if (!currentProfile?.sessionToken) {
    throw new Error("Sessão inválida. Entre novamente.");
  }

  return rpc(functionName, {
    p_session_token: currentProfile.sessionToken,
    ...args,
  });
}

function profileFromSessionRow(row) {
  if (!row) throw new Error("Resposta de sessão vazia.");
  return {
    id: row.user_id,
    adminId: row.admin_id,
    username: row.nick,
    fullName: row.full_name,
    role: row.role,
    storeId: row.store_id,
    storeName: row.store_name,
    sessionToken: row.session_token,
    expiresAt: row.expires_at,
  };
}

function profileFromProfileRow(row, sessionToken, expiresAt) {
  if (!row) throw new Error("Perfil não encontrado.");
  return {
    id: row.user_id,
    adminId: row.admin_id,
    username: row.nick,
    fullName: row.full_name,
    role: row.role,
    storeId: row.store_id,
    storeName: row.store_name,
    sessionToken,
    expiresAt,
  };
}

function mapStoreRow(row) {
  return {
    id: row.id,
    name: row.name,
    username: row.nick,
    createdAt: row.created_at,
    leadsCount: Number(row.leads_count || 0),
    salesCount: Number(row.sales_count || 0),
  };
}

function mapLeadRow(row) {
  return {
    id: row.id,
    storeId: row.store_id,
    storeName: row.store_name,
    name: row.name,
    phone: row.phone,
    channel: row.channel || "",
    campaign: row.campaign || "",
    conversationStart: row.conversation_start || "",
    conclusion: row.conclusion || "",
    visited: row.visited || "",
    bought: row.bought || "",
    purchaseAmount: row.purchase_amount === null || row.purchase_amount === undefined ? null : Number(row.purchase_amount),
    serviceOrder: row.service_order || "",
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function applyOptionRows(rows) {
  optionRecords = Object.fromEntries(optionGroups.map((group) => [group, []]));

  rows.forEach((row) => {
    if (!optionRecords[row.group_key]) return;
    optionRecords[row.group_key].push({
      id: row.id,
      groupKey: row.group_key,
      value: row.value,
      sortOrder: row.sort_order,
      fixed: row.fixed,
    });
  });

  optionGroups.forEach((group) => {
    optionRecords[group].sort((a, b) => a.sortOrder - b.sortOrder);
  });

  options = Object.fromEntries(
    optionGroups.map((group) => [group, optionRecords[group].map((record) => record.value)]),
  );
  dirtyOptionKeys.clear();
  dirtyOptionValues.clear();
}

function createDefaultOptionRecords() {
  return Object.fromEntries(
    optionGroups.map((group) => [
      group,
      defaultOptions[group].map((value, index) => ({
        id: `default-${group}-${index}`,
        groupKey: group,
        value,
        sortOrder: (index + 1) * 10,
        fixed: fixedOptionGroups.has(group) || fixedChannelOptions.has(value),
      })),
    ]),
  );
}

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data;
}

function readStoredSession() {
  try {
    return JSON.parse(localStorage.getItem(SESSION_STORAGE_KEY) || "null");
  } catch {
    return null;
  }
}

function saveStoredSession(profile) {
  localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({
    sessionToken: profile.sessionToken,
    expiresAt: profile.expiresAt,
  }));
}

function clearStoredSession() {
  localStorage.removeItem(SESSION_STORAGE_KEY);
}

function setFormBusy(targetForm, isBusy) {
  targetForm.querySelectorAll("button, input, select").forEach((element) => {
    element.disabled = isBusy;
  });
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

function updatePurchaseDetailsVisibility() {
  purchaseDetails.hidden = selectedValues.bought !== "Sim";
}

function parseCurrencyInput(value) {
  const normalized = String(value || "")
    .replace(/\s/g, "")
    .replace(/\./g, "")
    .replace(",", ".");
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatCurrency(value) {
  return new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(Number(value || 0));
}

function formatCurrencyInput(value) {
  return new Intl.NumberFormat("pt-BR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Number(value || 0));
}

function getChoiceClass(group, value) {
  if (group === "channel" && value === "Instagram") return "choice-instagram";
  if (group === "channel" && value === "Facebook") return "choice-facebook";
  if ((group === "visited" || group === "bought") && value === "Sim") return "choice-yes";
  if ((group === "visited" || group === "bought") && value === "Não") return "choice-no";
  return "";
}

function getChoiceLabel(group, value) {
  const escapedValue = escapeHtml(value);
  if (group === "channel" && value === "Instagram") {
    return `<span class="choice-brand-mark" aria-hidden="true">${getInstagramLogoSvg()}</span><span>${escapedValue}</span>`;
  }
  if (group === "channel" && value === "Facebook") {
    return `<span class="choice-brand-mark" aria-hidden="true">${getFacebookLogoSvg()}</span><span>${escapedValue}</span>`;
  }
  return escapedValue;
}

function getInstagramLogoSvg() {
  return `
    <svg viewBox="0 0 24 24" focusable="false" aria-hidden="true">
      <rect x="3.2" y="3.2" width="17.6" height="17.6" rx="5.1"></rect>
      <circle cx="12" cy="12" r="4.1"></circle>
      <circle class="instagram-dot" cx="17.15" cy="6.85" r="1.15"></circle>
    </svg>
  `;
}

function getFacebookLogoSvg() {
  return `
    <svg viewBox="0 0 24 24" focusable="false" aria-hidden="true">
      <path d="M14.4 8.1h2.15V4.55A27.7 27.7 0 0 0 13.42 4c-3.1 0-5.22 1.9-5.22 5.36v3H4.75v3.97H8.2V24h4.22v-7.67h3.3l.62-3.97h-3.92V9.75c0-1.15.31-1.65 1.98-1.65Z"></path>
    </svg>
  `;
}

function getOptionRecord(group, optionId) {
  return (optionRecords[group] || []).find((record) => record.id === optionId) || null;
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

function applyStoredTheme() {
  setTheme(localStorage.getItem(THEME_STORAGE_KEY) === "dark" ? "dark" : "light");
}

function toggleTheme() {
  setTheme(document.body.classList.contains("is-dark") ? "light" : "dark");
}

function setTheme(theme) {
  const isDark = theme === "dark";
  document.body.classList.toggle("is-dark", isDark);
  localStorage.setItem(THEME_STORAGE_KEY, isDark ? "dark" : "light");
  themeToggle.textContent = isDark ? "Modo claro" : "Modo escuro";
  themeToggle.setAttribute("aria-pressed", String(isDark));
}

function readableError(error) {
  return error?.message || String(error || "Erro inesperado.");
}

function showAppNotification(message, type = "success") {
  if (!message || !appNotification || appView.hidden) return;

  clearTimeout(notificationTimer);
  appNotification.textContent = message;
  appNotification.classList.toggle("error", type === "error");
  appNotification.hidden = false;

  notificationTimer = setTimeout(() => {
    appNotification.hidden = true;
    appNotification.textContent = "";
  }, 3600);
}

function clearAppNotification() {
  clearTimeout(notificationTimer);
  if (!appNotification) return;
  appNotification.hidden = true;
  appNotification.textContent = "";
  appNotification.classList.remove("error");
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
  if (type === "success") showAppNotification(message, "success");
}

function clearStoreMessage() {
  showStoreMessage("");
}

function showFormMessage(message, type = "error") {
  formMessage.textContent = message;
  formMessage.classList.toggle("success", type === "success");
  if (type === "success") showAppNotification(message, "success");
}

function showOptionsMessage(target, message, type = "error") {
  target.textContent = message;
  target.classList.toggle("success", type === "success");
  if (type === "success") showAppNotification(message, "success");
}
