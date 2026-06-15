const SUPABASE_URL = "https://menlvmsgkhgqxiydphbn.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1lbmx2bXNna2hncXhpeWRwaGJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEyNTYxNzEsImV4cCI6MjA5NjgzMjE3MX0.ylQcT5KnVDvdP3Wa8ZKdI6FpXWnjXAkpzpfzRw0FP30";
const SESSION_STORAGE_KEY = "lead-control-session";
const THEME_STORAGE_KEY = "lead-control-theme";
const AI_SETTINGS_STORAGE_KEY = "lead-control-ai-settings";

const DEFAULT_AI_SYSTEM_PROMPT = `Você é uma IA especialista em análise comercial de leads para óticas. Analise os registros filtrados, encontre padrões, gargalos e oportunidades, compare lojas, canais, campanhas e resultados, e responda com recomendações objetivas para aumentar visitas, compras e conversão. Use apenas os dados fornecidos no contexto, indique quando houver pouca amostra e priorize ações práticas.`;

const aiProviderOptions = {
  gemini: {
    label: "Google Gemini",
    models: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.5-pro"],
  },
  deepseek: {
    label: "DeepSeek",
    models: ["deepseek-v4-flash", "deepseek-v4-pro"],
  },
};

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
let activeTechnicianContext = null;
let stores = [];
let leads = [];
let technicians = [];
let customCategories = [];
let pendingUnsavedAction = null;
const dirtyOptionKeys = new Set();
const dirtyOptionValues = new Map();
let newOptionCounter = 0;
let selectedValues = createEmptySelection();
let selectedCustomValues = {};
let aiSettings = createDefaultAiSettings();
let aiMessages = [];
let aiIsSending = false;

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
const settingsButton = $("#settingsButton");
const loginForm = $("#loginForm");
const signupForm = $("#signupForm");
const authMessage = $("#authMessage");
const authTitle = $("#authTitle");
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
const technicianForm = $("#technicianForm");
const technicianName = $("#technicianName");
const technicianNick = $("#technicianNick");
const technicianPassword = $("#technicianPassword");
const technicianMessage = $("#technicianMessage");
const technicianEmptyState = $("#technicianEmptyState");
const technicianList = $("#technicianList");
const technicianListPanel = $("#technicianListPanel");
const storeListPanel = $(".store-list-panel");
const settingsModal = $("#settingsModal");
const settingsClose = $("#settingsClose");
const settingsCancel = $("#settingsCancel");
const adminAccountForm = $("#adminAccountForm");
const adminAccountNick = $("#adminAccountNick");
const adminCurrentPassword = $("#adminCurrentPassword");
const adminNewPassword = $("#adminNewPassword");
const adminAccountMessage = $("#adminAccountMessage");
const managedAccountModal = $("#managedAccountModal");
const managedAccountClose = $("#managedAccountClose");
const managedAccountCancel = $("#managedAccountCancel");
const managedAccountForm = $("#managedAccountForm");
const managedAccountTitle = $("#managedAccountTitle");
const managedAccountType = $("#managedAccountType");
const managedAccountId = $("#managedAccountId");
const managedAccountName = $("#managedAccountName");
const managedAccountNameLabel = $("#managedAccountNameLabel");
const managedAccountNick = $("#managedAccountNick");
const managedAccountPassword = $("#managedAccountPassword");
const managedAccountMessage = $("#managedAccountMessage");
const storeEmptyState = $("#storeEmptyState");
const storeList = $("#storeList");
const adminOptionsList = $("#adminOptionsList");
const adminOptionsMessage = $("#adminOptionsMessage");
const analyticsToggle = $("#analyticsToggle");
const analyticsToggleLabel = $("#analyticsToggleLabel");
const analyticsContent = $("#analyticsContent");
const analyticsStoreFilter = $("#analyticsStoreFilter");
const analyticsChannelFilter = $("#analyticsChannelFilter");
const analyticsCampaignFilter = $("#analyticsCampaignFilter");
const analyticsConclusionFilter = $("#analyticsConclusionFilter");
const analyticsVisitedFilter = $("#analyticsVisitedFilter");
const analyticsBoughtFilter = $("#analyticsBoughtFilter");
const analyticsSingleDate = $("#analyticsSingleDate");
const analyticsStartDate = $("#analyticsStartDate");
const analyticsEndDate = $("#analyticsEndDate");
const analyticsSingleDateField = $(".analytics-single-date");
const analyticsRangeDateFields = $$(".analytics-range-date");
const analyticsQuickRangeField = $(".quick-range-field");
const analyticsCustomFilters = $("#analyticsCustomFilters");
const analyticsCustomSections = $("#analyticsCustomSections");
const analyticsDateModeButtons = $$("[data-analytics-date-mode]");
const analyticsQuickRangeButtons = $$("[data-analytics-range]");
const exportLeadsButton = $("#exportLeadsButton");
const aiInsightsButton = $("#aiInsightsButton");
const aiChatModal = $("#aiChatModal");
const aiChatClose = $("#aiChatClose");
const aiSettingsToggle = $("#aiSettingsToggle");
const aiSettingsPanel = $("#aiSettingsPanel");
const aiLeadContextLabel = $("#aiLeadContextLabel");
const aiChatMessages = $("#aiChatMessages");
const aiChatForm = $("#aiChatForm");
const aiChatInput = $("#aiChatInput");
const aiChatSend = $("#aiChatSend");
const aiSettingsForm = $("#aiSettingsForm");
const aiProvider = $("#aiProvider");
const aiModel = $("#aiModel");
const aiApiKey = $("#aiApiKey");
const aiSystemPrompt = $("#aiSystemPrompt");
const aiSettingsMessage = $("#aiSettingsMessage");
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
const customLeadFields = $("#customLeadFields");
const customLeadFilters = $("#customLeadFilters");
const purchaseDetails = $("#purchaseDetails");
const purchaseAmountInput = $("#purchaseAmount");
const serviceOrderInput = $("#serviceOrder");
const leadNotesInput = $("#leadNotes");
const storeOptionsPanel = $("#storeOptionsPanel");
const storeOptionsList = $("#storeOptionsList");
const storeOptionsMessage = $("#storeOptionsMessage");
const unsavedOptionsModal = $("#unsavedOptionsModal");
const unsavedCancel = $("#unsavedCancel");
const unsavedDiscard = $("#unsavedDiscard");
const unsavedSave = $("#unsavedSave");
const confirmModal = $("#confirmModal");
const confirmEyebrow = $("#confirmEyebrow");
const confirmTitle = $("#confirmTitle");
const confirmMessage = $("#confirmMessage");
const confirmCancel = $("#confirmCancel");
const confirmAccept = $("#confirmAccept");
const analyticsInspectorModal = $("#analyticsInspectorModal");
const analyticsInspectorEyebrow = $("#analyticsInspectorEyebrow");
const analyticsInspectorTitle = $("#analyticsInspectorTitle");
const analyticsInspectorSubtitle = $("#analyticsInspectorSubtitle");
const analyticsInspectorList = $("#analyticsInspectorList");
const analyticsInspectorClose = $("#analyticsInspectorClose");
const leadDetailsModal = $("#leadDetailsModal");
const leadDetailsTitle = $("#leadDetailsTitle");
const leadDetailsContent = $("#leadDetailsContent");
const leadDetailsClose = $("#leadDetailsClose");
let notificationTimer = null;
let pendingConfirmAction = null;

const analyticsSections = [
  { id: "campaign", label: "Campanhas", key: "campaign", container: "#analyticsCampaignCards", summary: "#analyticsCampaignSummary" },
  { id: "store", label: "Lojas", key: "storeName", container: "#analyticsStoreCards", summary: "#analyticsStoreSummary" },
  { id: "channel", label: "Canais", key: "channel", container: "#analyticsChannelCards", summary: "#analyticsChannelSummary" },
  { id: "start", label: "Início da conversa", key: "conversationStart", container: "#analyticsStartCards", summary: "#analyticsStartSummary" },
  { id: "conclusion", label: "Resultado", key: "conclusion", container: "#analyticsConclusionCards", summary: "#analyticsConclusionSummary" },
  { id: "visited", label: "Visitas", key: "visited", container: "#analyticsVisitedCards", summary: "#analyticsVisitedSummary" },
  { id: "bought", label: "Compras", key: "bought", container: "#analyticsBoughtCards", summary: "#analyticsBoughtSummary" },
];

document.addEventListener("DOMContentLoaded", () => {
  init().catch((error) => {
    showAuth();
    showAuthMessage(readableError(error));
  });
});

async function init() {
  applyStoredTheme();
  loadAiSettings();
  setTodayLabel();
  bindEvents();
  showAuth();
  renderAiSettingsForm();
  renderAiMessages();
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
  logoutButton.addEventListener("click", () => guardUnsavedOptions(confirmLogout));
  backAdminButton.addEventListener("click", () => guardUnsavedOptions(returnToAdmin));
  settingsButton.addEventListener("click", openSettingsModal);
  settingsClose.addEventListener("click", closeSettingsModal);
  settingsCancel.addEventListener("click", closeSettingsModal);
  settingsModal.addEventListener("click", (event) => {
    if (event.target === settingsModal) closeSettingsModal();
  });
  managedAccountClose.addEventListener("click", closeManagedAccountModal);
  managedAccountCancel.addEventListener("click", closeManagedAccountModal);
  managedAccountModal.addEventListener("click", (event) => {
    if (event.target === managedAccountModal) closeManagedAccountModal();
  });
  managedAccountForm.addEventListener("submit", handleManagedAccountSubmit);
  storeForm.addEventListener("submit", handleCreateStore);
  technicianForm.addEventListener("submit", handleCreateTechnician);
  adminAccountForm.addEventListener("submit", handleAdminAccountSubmit);
  adminOptionsList.addEventListener("click", handleOptionsEditorClick);
  storeOptionsList.addEventListener("click", handleOptionsEditorClick);
  adminOptionsList.addEventListener("input", handleOptionsEditorInput);
  storeOptionsList.addEventListener("input", handleOptionsEditorInput);
  unsavedCancel.addEventListener("click", closeUnsavedOptionsModal);
  unsavedDiscard.addEventListener("click", discardUnsavedOptionsAndContinue);
  unsavedSave.addEventListener("click", saveUnsavedOptionsAndContinue);
  confirmCancel.addEventListener("click", closeConfirmModal);
  confirmAccept.addEventListener("click", runConfirmedAction);
  confirmModal.addEventListener("click", (event) => {
    if (event.target === confirmModal) closeConfirmModal();
  });
  analyticsInspectorClose.addEventListener("click", closeAnalyticsInspector);
  analyticsInspectorModal.addEventListener("click", (event) => {
    if (event.target === analyticsInspectorModal) closeAnalyticsInspector();
  });
  analyticsInspectorList.addEventListener("click", handleAnalyticsInspectorClick);
  leadDetailsClose.addEventListener("click", closeLeadDetailsModal);
  leadDetailsModal.addEventListener("click", (event) => {
    if (event.target === leadDetailsModal) closeLeadDetailsModal();
  });
  analyticsToggle.addEventListener("click", toggleAnalytics);
  exportLeadsButton.addEventListener("click", exportLeadsToExcel);
  aiInsightsButton.addEventListener("click", openAiChat);
  aiChatClose.addEventListener("click", closeAiChat);
  aiChatModal.addEventListener("click", (event) => {
    if (event.target === aiChatModal) closeAiChat();
  });
  aiSettingsToggle.addEventListener("click", toggleAiSettingsPanel);
  aiProvider.addEventListener("input", handleAiProviderChange);
  aiSettingsForm.addEventListener("submit", handleAiSettingsSubmit);
  aiChatForm.addEventListener("submit", handleAiChatSubmit);
  aiChatInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      aiChatForm.requestSubmit();
    }
  });
  [
    analyticsStoreFilter,
    analyticsChannelFilter,
    analyticsCampaignFilter,
    analyticsConclusionFilter,
    analyticsVisitedFilter,
    analyticsBoughtFilter,
  ].forEach((element) => {
    element.addEventListener("input", renderAdminAnalytics);
  });
  analyticsCustomFilters.addEventListener("input", renderAdminAnalytics);
  analyticsContent.addEventListener("click", handleAnalyticsClick);
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
  customLeadFilters.addEventListener("input", renderLeadList);

  toggleFiltersButton.addEventListener("click", toggleFilters);
  clearFiltersButton.addEventListener("click", clearFilters);
  leadList.addEventListener("click", handleLeadListClick);
  storeList.addEventListener("click", handleManagementListClick);
  technicianList.addEventListener("click", handleManagementListClick);
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

  if (profile.role === "admin" || profile.role === "technician") {
    showAdminDashboard();
    return;
  }

  showStoreDashboard();
}

function showAdminDashboard() {
  activeStoreContext = null;
  activeTechnicianContext = null;
  const isTechnician = currentProfile.role === "technician";
  sessionRole.textContent = `${isTechnician ? "Técnico" : "Admin"} · ${currentProfile.username}`;
  storeForm.hidden = isTechnician;
  technicianForm.hidden = isTechnician;
  technicianListPanel.hidden = isTechnician;
  settingsButton.hidden = isTechnician;
  closeSettingsModal();
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
  settingsButton.hidden = true;
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
    technicians = [];
    aiMessages = [];
    customCategories = [];
    options = cloneOptions(defaultOptions);
    optionRecords = createDefaultOptionRecords();
    selectedCustomValues = {};
    resetLeadForm();
    closeAiChat();
    showAuth();
    renderAll();
  }
}

function showAuth() {
  clearAppNotification();
  closeSettingsModal();
  closeManagedAccountModal();
  closeAiChat();
  settingsButton.hidden = true;
  authScreen.hidden = false;
  appView.hidden = true;
  adminView.hidden = true;
  storeView.hidden = true;
}

function setAuthTab(tabName) {
  const isLogin = tabName === "login";
  loginForm.hidden = !isLogin;
  signupForm.hidden = isLogin;
  authTitle.textContent = isLogin ? "Login" : "Criar admin";
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
    showStoreMessage("Loja criada.", "success");
    renderAll();
  } catch (error) {
    showStoreMessage(readableError(error));
  } finally {
    setFormBusy(storeForm, false);
  }
}

async function handleCreateTechnician(event) {
  event.preventDefault();
  clearTechnicianMessage();

  if (!currentProfile || currentProfile.role !== "admin") return;

  const username = normalizeNick(technicianNick.value);
  if (!username) {
    showTechnicianMessage("Digite um nick válido para o técnico.");
    return;
  }

  try {
    setFormBusy(technicianForm, true);
    await authenticatedRpc("lc_create_technician", {
      p_full_name: technicianName.value.trim(),
      p_nick: username,
      p_password: technicianPassword.value,
    });
    technicianForm.reset();
    await refreshRemoteState();
    showTechnicianMessage("Técnico criado.", "success");
    renderAll();
  } catch (error) {
    showTechnicianMessage(readableError(error));
  } finally {
    setFormBusy(technicianForm, false);
  }
}

async function handleAdminAccountSubmit(event) {
  event.preventDefault();
  clearAdminAccountMessage();

  if (!currentProfile || currentProfile.role !== "admin") return;

  const username = normalizeNick(adminAccountNick.value);
  if (!username) {
    showAdminAccountMessage("Digite um nick válido.");
    return;
  }

  if (!adminCurrentPassword.value) {
    showAdminAccountMessage("Digite sua senha atual.");
    return;
  }

  if (adminNewPassword.value && adminNewPassword.value.length < 6) {
    showAdminAccountMessage("A nova senha precisa ter pelo menos 6 caracteres.");
    return;
  }

  try {
    setFormBusy(adminAccountForm, true);
    const row = firstRow(await authenticatedRpc("lc_update_admin_credentials", {
      p_nick: username,
      p_current_password: adminCurrentPassword.value,
      p_new_password: adminNewPassword.value || null,
    }));
    currentProfile.username = row?.nick || username;
    adminAccountNick.value = currentProfile.username;
    adminCurrentPassword.value = "";
    adminNewPassword.value = "";
    sessionRole.textContent = `Admin · ${currentProfile.username}`;
    saveStoredSession(currentProfile);
    showAdminAccountMessage("Conta atualizada.", "success");
  } catch (error) {
    showAdminAccountMessage(readableError(error));
  } finally {
    setFormBusy(adminAccountForm, false);
  }
}

function openSettingsModal() {
  if (!currentProfile || currentProfile.role !== "admin") return;

  adminAccountNick.value = currentProfile.username || "";
  adminCurrentPassword.value = "";
  adminNewPassword.value = "";
  clearAdminAccountMessage();
  settingsModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => adminAccountNick.focus());
}

function closeSettingsModal() {
  if (!settingsModal || settingsModal.hidden) return;
  settingsModal.hidden = true;
  adminCurrentPassword.value = "";
  adminNewPassword.value = "";
  clearAdminAccountMessage();
  syncModalLock();
}

function handleManagementListClick(event) {
  const editButton = event.target.closest("[data-account-edit]");
  if (editButton) {
    openManagedAccountModal(editButton.dataset.accountEdit, editButton.dataset.accountId);
    return;
  }

  const technicianButton = event.target.closest("[data-technician-login]");
  if (technicianButton && currentProfile?.role === "admin") {
    guardUnsavedOptions(() => openTechnicianAsAdmin(technicianButton.dataset.technicianLogin));
    return;
  }

  const button = event.target.closest("[data-store-login]");
  if (!button || currentProfile?.role !== "admin") return;
  guardUnsavedOptions(() => openStoreAsAdmin(button.dataset.storeLogin));
}

function openManagedAccountModal(type, id) {
  if (currentProfile?.role !== "admin") return;

  const record = type === "store"
    ? stores.find((store) => store.id === id)
    : technicians.find((technician) => technician.id === id);
  if (!record) return;

  managedAccountType.value = type;
  managedAccountId.value = id;
  managedAccountTitle.textContent = type === "store" ? "Editar loja" : "Editar técnico";
  managedAccountNameLabel.textContent = type === "store" ? "Nome da loja" : "Nome do técnico";
  managedAccountName.value = type === "store" ? record.name : record.fullName || record.username;
  managedAccountNick.value = record.username || "";
  managedAccountPassword.value = "";
  clearManagedAccountMessage();
  managedAccountModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => managedAccountName.focus());
}

function closeManagedAccountModal() {
  if (!managedAccountModal || managedAccountModal.hidden) return;
  managedAccountModal.hidden = true;
  managedAccountForm.reset();
  clearManagedAccountMessage();
  syncModalLock();
}

async function handleManagedAccountSubmit(event) {
  event.preventDefault();
  clearManagedAccountMessage();

  if (currentProfile?.role !== "admin") return;

  const type = managedAccountType.value;
  const id = managedAccountId.value;
  const username = normalizeNick(managedAccountNick.value);
  const password = managedAccountPassword.value;

  if (!managedAccountName.value.trim()) {
    showManagedAccountMessage("Digite o nome.");
    return;
  }

  if (!username) {
    showManagedAccountMessage("Digite um nick válido.");
    return;
  }

  if (password && password.length < 6) {
    showManagedAccountMessage("A nova senha precisa ter pelo menos 6 caracteres.");
    return;
  }

  try {
    setFormBusy(managedAccountForm, true);
    if (type === "store") {
      await authenticatedRpc("lc_update_store_account", {
        p_store_id: id,
        p_name: managedAccountName.value.trim(),
        p_nick: username,
        p_password: password || null,
      });
    } else if (type === "technician") {
      await authenticatedRpc("lc_update_technician_account", {
        p_technician_id: id,
        p_full_name: managedAccountName.value.trim(),
        p_nick: username,
        p_password: password || null,
      });
    }

    await refreshRemoteState();
    renderAll();
    closeManagedAccountModal();
    showAppNotification("Atualizado");
  } catch (error) {
    showManagedAccountMessage(readableError(error));
  } finally {
    setFormBusy(managedAccountForm, false);
  }
}

function openStoreAsAdmin(storeId) {
  const store = stores.find((item) => item.id === storeId);
  if (!store) return;

  activeStoreContext = store;
  activeTechnicianContext = null;
  sessionRole.textContent = `Admin · ${store.name}`;
  backAdminButton.hidden = false;
  toggleOptionsEditButton.hidden = false;
  clearFormButton.hidden = true;
  adminView.hidden = true;
  storeView.hidden = false;
  resetLeadForm();
  renderAll();
}

function openTechnicianAsAdmin(technicianId) {
  const technician = technicians.find((item) => item.id === technicianId);
  if (!technician) return;

  activeStoreContext = null;
  activeTechnicianContext = technician;
  sessionRole.textContent = `Técnico · ${technician.fullName || technician.username}`;
  backAdminButton.hidden = false;
  adminView.hidden = false;
  storeView.hidden = true;
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
    p_notes: leadNotesInput.value.trim(),
    p_store_id: store.id,
  };
  if (customCategories.length) {
    payload.p_custom_values = buildCustomValuesPayload();
  }

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
    showFormMessage(wasEditing ? "Lead atualizado." : "Lead salvo.", "success");
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

  if (button.dataset.action === "view") openLeadDetailsModal(button.dataset.id);
  if (button.dataset.action === "edit") guardUnsavedOptions(() => editLead(button.dataset.id));
  if (button.dataset.action === "delete") confirmDeleteLead(button.dataset.id);
}

function editLead(id) {
  const lead = leads.find((item) => item.id === id);
  if (!lead) return;

  if (!storeOptionsPanel.hidden) toggleStoreOptionsMode(false);

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
  selectedCustomValues = { ...lead.customValues };
  purchaseAmountInput.value = lead.purchaseAmount ? formatCurrencyInput(lead.purchaseAmount) : "";
  serviceOrderInput.value = lead.serviceOrder || "";
  leadNotesInput.value = lead.notes || "";
  formTitle.textContent = "Editar lead";
  submitButton.textContent = "Atualizar lead";
  cancelEditButton.hidden = false;
  updatePurchaseDetailsVisibility();
  renderChoiceButtons();
}

function confirmDeleteLead(id) {
  const lead = leads.find((item) => item.id === id);
  if (!lead) return;

  openConfirmModal({
    eyebrow: "Excluir lead",
    title: "Excluir este lead?",
    message: `Essa ação remove o lead "${lead.name}" da loja ${lead.storeName || "selecionada"}.`,
    confirmText: "Excluir",
    action: () => deleteLead(id),
  });
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

function confirmLogout() {
  openConfirmModal({
    eyebrow: "Sair",
    title: "Deseja sair?",
    message: "Você vai encerrar esta sessão e voltar para a tela de login.",
    confirmText: "Sair",
    action: handleLogout,
  });
}

function openConfirmModal({ eyebrow = "Confirmação", title, message, confirmText = "Confirmar", action }) {
  pendingConfirmAction = action;
  confirmEyebrow.textContent = eyebrow;
  confirmTitle.textContent = title;
  confirmMessage.textContent = message;
  confirmAccept.textContent = confirmText;
  confirmModal.hidden = false;
}

function closeConfirmModal() {
  pendingConfirmAction = null;
  confirmModal.hidden = true;
}

async function runConfirmedAction() {
  const action = pendingConfirmAction;
  closeConfirmModal();
  if (action) await action();
}

function resetLeadForm() {
  form.reset();
  editingIdInput.value = "";
  selectedValues = createEmptySelection();
  selectedCustomValues = {};
  purchaseAmountInput.value = "";
  serviceOrderInput.value = "";
  leadNotesInput.value = "";
  formTitle.textContent = "Cadastrar lead";
  submitButton.textContent = "Salvar lead";
  cancelEditButton.hidden = true;
  if (!storeOptionsPanel.hidden) toggleStoreOptionsMode(false);
  updatePurchaseDetailsVisibility();
  renderChoiceButtons();
}

async function refreshRemoteState() {
  if (!currentProfile?.sessionToken) return;

  const technicianRowsRequest = currentProfile.role === "admin"
    ? authenticatedRpc("lc_list_technicians").catch((error) => {
        if (isMissingRpcError(error)) return [];
        throw error;
      })
    : Promise.resolve([]);

  const [storeRows, optionRows, customCategoryRows, leadRows, technicianRows] = await Promise.all([
    authenticatedRpc("lc_list_stores"),
    authenticatedRpc("lc_list_options"),
    authenticatedRpc("lc_list_custom_categories").catch((error) => {
      if (isMissingRpcError(error)) return [];
      throw error;
    }),
    authenticatedRpc("lc_list_leads"),
    technicianRowsRequest,
  ]);

  stores = (storeRows || []).map(mapStoreRow);
  applyOptionRows(optionRows || []);
  applyCustomCategoryRows(customCategoryRows || []);
  leads = (leadRows || []).map(mapLeadRow);
  technicians = (technicianRows || []).map(mapTechnicianRow);

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
  renderCustomChoiceButtons();
  renderFilters();
  renderCustomLeadFilters();
  renderOptionsEditors();
  renderAdminDashboard();
  renderLeadList();
  renderTodayCount();
}

function renderAdminDashboard() {
  const isTechnicianView = currentProfile?.role === "technician" || Boolean(activeTechnicianContext);
  const isAdmin = currentProfile?.role === "admin" && !activeTechnicianContext;
  storeForm.hidden = !isAdmin;
  technicianForm.hidden = !isAdmin;
  technicianListPanel.hidden = !isAdmin;
  settingsButton.hidden = !isAdmin;
  storeListPanel.hidden = isTechnicianView;
  $("#totalStores").textContent = stores.length;
  $("#adminTotalLeads").textContent = leads.length;
  $("#adminSalesCount").textContent = countByValue(leads, "bought", "Sim");
  $("#adminConversionRate").textContent = formatPercent(countByValue(leads, "bought", "Sim"), leads.length);
  renderStoreList();
  renderTechnicianList();
  renderAnalyticsFilters();
  renderAdminAnalytics();
}

function renderStoreList() {
  if (storeListPanel.hidden) {
    storeEmptyState.hidden = true;
    storeList.innerHTML = "";
    return;
  }

  const canEnterStore = currentProfile?.role === "admin" && !activeTechnicianContext;
  storeEmptyState.hidden = stores.length > 0;
  storeList.innerHTML = stores
    .map(
      (store) => `
        <article class="lead-card management-card">
          <div>
            <strong>${escapeHtml(store.name)}</strong>
            <span>${escapeHtml(store.username)}</span>
          </div>
          ${canEnterStore
            ? `<div class="card-actions">
                <button class="secondary-button" type="button" data-store-login="${store.id}">Entrar</button>
                <button class="mini-button" type="button" data-account-edit="store" data-account-id="${store.id}">Editar</button>
              </div>`
            : `<span class="readonly-pill">Somente métricas</span>`}
        </article>
      `,
    )
    .join("");

}

function renderTechnicianList() {
  if (!technicianList || technicianListPanel.hidden) return;

  technicianEmptyState.hidden = technicians.length > 0;
  technicianList.innerHTML = technicians
    .map((technician) => `
      <article class="lead-card technician-card">
        <div>
          <strong>${escapeHtml(technician.fullName || technician.username)}</strong>
        </div>
        <div class="card-actions">
          <button class="secondary-button" type="button" data-technician-login="${technician.id}">Acessar</button>
          <button class="mini-button" type="button" data-account-edit="technician" data-account-id="${technician.id}">Editar</button>
        </div>
      </article>
    `)
    .join("");
}

function renderLeadList() {
  const filteredLeads = getFilteredLeads();
  emptyState.hidden = filteredLeads.length > 0;
  leadList.innerHTML = filteredLeads
    .map(
      (lead) => `
        <article class="lead-card">
          <div class="lead-card-top">
            <div class="lead-person">
              <strong>${escapeHtml(lead.name)}</strong>
              <span>${escapeHtml(lead.storeName || "")}</span>
            </div>
          </div>
          <div class="lead-tags">
            ${renderTag(lead.channel)}
            ${renderTag(lead.campaign)}
            ${renderTag(lead.conclusion)}
            ${renderTag(lead.visited ? `Visitou: ${lead.visited}` : "")}
            ${renderTag(lead.bought ? `Comprou: ${lead.bought}` : "")}
            ${renderTag(lead.purchaseAmount ? `Valor: ${formatCurrency(lead.purchaseAmount)}` : "")}
            ${renderTag(lead.serviceOrder ? `OS: ${lead.serviceOrder}` : "")}
            ${renderCustomLeadTags(lead)}
          </div>
          ${renderLeadNotes(lead.notes)}
          <div class="card-actions">
            <a class="mini-button whatsapp-button" href="${formatWhatsAppUrl(lead.phone)}" target="_blank" rel="noopener noreferrer" aria-label="Chamar ${escapeHtml(lead.name)} no WhatsApp">
              <i class="fa-brands fa-whatsapp" aria-hidden="true"></i>
              WhatsApp
            </a>
            <button class="mini-button" type="button" data-action="edit" data-id="${lead.id}">Editar</button>
            <button class="mini-button danger" type="button" data-action="delete" data-id="${lead.id}">Excluir</button>
            <button class="mini-button view-button" type="button" data-action="view" data-id="${lead.id}">Visualizar</button>
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

function openLeadDetailsModal(id) {
  const lead = leads.find((item) => item.id === id);
  if (!lead) return;

  leadDetailsTitle.textContent = lead.name;
  leadDetailsContent.innerHTML = `
    <div class="lead-details-summary">
      <strong>${escapeHtml(lead.name)}</strong>
      <span>${escapeHtml(lead.storeName || "")}</span>
    </div>
    <div class="lead-details-section">
      <h3>Contato</h3>
      <div class="lead-details-grid">
        ${renderLeadDetailItem("Telefone", lead.phone)}
        ${renderLeadDetailItem("Registrado em", formatDateTime(lead.createdAt))}
      </div>
    </div>
    <div class="lead-details-section">
      <h3>Atendimento</h3>
      <div class="lead-details-grid">
        ${renderLeadDetailItem("Canal", lead.channel)}
        ${renderLeadDetailItem("Campanha", lead.campaign)}
        ${renderLeadDetailItem("Início da conversa", lead.conversationStart)}
        ${renderLeadDetailItem("Conclusão", lead.conclusion)}
        ${renderCustomLeadDetailItems(lead)}
      </div>
    </div>
    <div class="lead-details-section">
      <h3>Resultado</h3>
      <div class="lead-details-grid">
        ${renderLeadDetailItem("Visitou a loja", lead.visited)}
        ${renderLeadDetailItem("Comprou", lead.bought)}
        ${renderLeadDetailItem("Valor da compra", lead.purchaseAmount ? formatCurrency(lead.purchaseAmount) : "")}
        ${renderLeadDetailItem("OS", lead.serviceOrder)}
      </div>
    </div>
    <div class="lead-details-notes">
      <span>Observações</span>
      <p>${escapeHtml(lead.notes || "Sem observações.")}</p>
    </div>
    <div class="modal-actions">
      <a class="mini-button whatsapp-button" href="${formatWhatsAppUrl(lead.phone)}" target="_blank" rel="noopener noreferrer">
        <i class="fa-brands fa-whatsapp" aria-hidden="true"></i>
        WhatsApp
      </a>
      <button class="mini-button" type="button" data-detail-edit="${lead.id}">Editar</button>
    </div>
  `;

  const editButton = leadDetailsContent.querySelector("[data-detail-edit]");
  editButton.addEventListener("click", () => {
    closeLeadDetailsModal();
    guardUnsavedOptions(() => editLead(lead.id));
  });

  leadDetailsModal.hidden = false;
  syncModalLock();
}

function closeLeadDetailsModal() {
  leadDetailsModal.hidden = true;
  leadDetailsContent.innerHTML = "";
  syncModalLock();
}

function syncModalLock() {
  document.body.classList.toggle(
    "is-modal-open",
    !leadDetailsModal.hidden || !analyticsInspectorModal.hidden || !settingsModal.hidden || !managedAccountModal.hidden || !aiChatModal.hidden,
  );
}

function renderLeadDetailItem(label, value) {
  return `
    <div class="lead-detail-item">
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value || "-")}</strong>
    </div>
  `;
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

function renderCustomChoiceButtons() {
  if (!customLeadFields) return;

  customLeadFields.innerHTML = customCategories
    .map((category) => `
      <div class="choice-section custom-choice-section">
        <div class="section-title">
          <h3>${escapeHtml(category.name)}</h3>
          <span>Opcional</span>
        </div>
        <div class="choice-grid compact" data-custom-choice-category="${category.id}">
          ${category.options.length
            ? category.options.map((option) => {
                const isActive = selectedCustomValues[category.id] === option.value;
                return `<button class="choice-button${isActive ? " is-active" : ""}" type="button" data-custom-choice-value="${escapeHtml(option.value)}">${escapeHtml(option.value)}</button>`;
              }).join("")
            : `<span class="option-chip">Sem opções</span>`}
        </div>
      </div>
    `)
    .join("");

  customLeadFields.querySelectorAll("[data-custom-choice-value]").forEach((button) => {
    button.addEventListener("click", () => {
      const categoryId = button.closest("[data-custom-choice-category]")?.dataset.customChoiceCategory;
      if (!categoryId) return;
      selectedCustomValues[categoryId] =
        selectedCustomValues[categoryId] === button.dataset.customChoiceValue ? "" : button.dataset.customChoiceValue;
      renderCustomChoiceButtons();
    });
  });
}

function renderFilters() {
  fillSelect(channelFilter, options.channel, "Todos");
  fillSelect(campaignFilter, options.campaign, "Todos");
  fillSelect(conversationStartFilter, options.conversationStart, "Todos");
  fillSelect(conclusionFilter, options.conclusion, "Todos");
  fillSelectWithEntries(visitedFilter, withNoAnswer(options.visited), "Todos");
  fillSelectWithEntries(boughtFilter, withNoAnswer(options.bought), "Todos");
}

function renderCustomLeadFilters() {
  renderCustomFilters(customLeadFilters, "Todos");
}

function renderAnalyticsFilters() {
  const currentStore = analyticsStoreFilter.value;
  analyticsStoreFilter.innerHTML = '<option value="">Todas as lojas</option>' +
    stores.map((store) => `<option value="${store.id}">${escapeHtml(store.name)}</option>`).join("");
  analyticsStoreFilter.value = stores.some((store) => store.id === currentStore) ? currentStore : "";

  fillSelect(analyticsChannelFilter, options.channel, "Todos");
  fillSelect(analyticsCampaignFilter, options.campaign, "Todas");
  fillSelect(analyticsConclusionFilter, options.conclusion, "Todos");
  fillSelectWithEntries(analyticsVisitedFilter, withNoAnswer(options.visited), "Todas");
  fillSelectWithEntries(analyticsBoughtFilter, withNoAnswer(options.bought), "Todas");
  renderCustomFilters(analyticsCustomFilters, "Todas");
}

function renderCustomFilters(container, firstLabel) {
  if (!container) return;

  const currentValues = Object.fromEntries(
    Array.from(container.querySelectorAll("[data-custom-filter]")).map((select) => [select.dataset.customFilter, select.value]),
  );

  container.innerHTML = customCategories
    .map((category) => {
      const optionsHtml = withNoAnswer(category.options.map((option) => option.value))
        .map(({ value, label }) => `<option value="${escapeHtml(value)}">${escapeHtml(label)}</option>`)
        .join("");
      return `
        <label class="field">
          <span>${escapeHtml(category.name)}</span>
          <select data-custom-filter="${category.id}">
            <option value="">${firstLabel}</option>
            ${optionsHtml}
          </select>
        </label>
      `;
    })
    .join("");

  container.querySelectorAll("[data-custom-filter]").forEach((select) => {
    const currentValue = currentValues[select.dataset.customFilter];
    select.value = Array.from(select.options).some((option) => option.value === currentValue) ? currentValue : "";
  });
}

function renderOptionsEditors() {
  renderOptionsEditor(adminOptionsList, "admin");
  renderOptionsEditor(storeOptionsList, "store");
}

function renderOptionsEditor(container, scope) {
  const editableGroups = optionGroups.filter((group) => !fixedOptionGroups.has(group));

  const standardGroups = editableGroups
    .map((group) => {
      const isFixed = fixedOptionGroups.has(group);
      const chips = (optionRecords[group] || [])
        .map((record) =>
          isFixed || record.fixed
            ? `<span class="option-chip">${escapeHtml(record.value)}</span>`
            : `<div class="option-row${record.pending ? " is-pending" : ""}" data-group="${group}" data-option-id="${record.id}">
                <input value="${escapeHtml(dirtyOptionValues.get(record.id) ?? record.value)}" aria-label="${labels[group]}" />
                <button class="mini-button option-save" type="button" data-option-action="save" ${record.pending || dirtyOptionKeys.has(record.id) ? "" : "hidden"}>Salvar</button>
                <button class="mini-button danger" type="button" data-option-action="delete">Excluir</button>
              </div>`,
        )
        .join("");
      const addButton = isFixed
        ? ""
        : `<button class="mini-button option-add-button" type="button" data-option-action="add" data-group="${group}" aria-label="Adicionar ${labels[group]}" title="Adicionar ${labels[group]}">
            <i class="fa-solid fa-plus" aria-hidden="true"></i>
          </button>`;

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

  container.innerHTML = standardGroups + renderCustomCategoriesEditor(scope);
}

function renderCustomCategoriesEditor(scope) {
  const categoryCards = customCategories
    .map((category) => {
      const categoryKey = category.id;
      const categoryName = dirtyOptionValues.get(categoryKey) ?? category.name;
      const optionRows = category.options
        .map((option) => `
          <div class="option-row custom-option-row${option.pending ? " is-pending" : ""}" data-custom-category-id="${category.id}" data-option-id="${option.id}">
            <input value="${escapeHtml(dirtyOptionValues.get(option.id) ?? option.value)}" aria-label="${escapeHtml(category.name)}" />
            <button class="mini-button option-save" type="button" data-option-action="save-custom-option" ${option.pending || dirtyOptionKeys.has(option.id) ? "" : "hidden"}>Salvar</button>
            <button class="mini-button danger" type="button" data-option-action="delete-custom-option">Excluir</button>
          </div>
        `)
        .join("");

      return `
        <div class="custom-category-editor${category.pending ? " is-pending" : ""}" data-custom-category-id="${category.id}">
          <div class="custom-category-heading">
            <input value="${escapeHtml(categoryName)}" data-custom-category-name aria-label="Nome da categoria adicional" placeholder="Nome da categoria" />
            <button class="mini-button option-save" type="button" data-option-action="save-custom-category" ${category.pending || dirtyOptionKeys.has(categoryKey) ? "" : "hidden"}>Salvar</button>
            <button class="mini-button option-add-button" type="button" data-option-action="add-custom-option" ${category.pending ? "hidden" : ""} aria-label="Adicionar opção em ${escapeHtml(category.name)}" title="Adicionar opção">
              <i class="fa-solid fa-plus" aria-hidden="true"></i>
            </button>
            <button class="mini-button danger category-delete-button" type="button" data-option-action="delete-custom-category" aria-label="Excluir categoria ${escapeHtml(category.name)}" title="Excluir categoria">
              <i class="fa-solid fa-trash" aria-hidden="true"></i>
              <span>Excluir categoria</span>
            </button>
          </div>
          <div class="option-list custom-option-list">${optionRows || '<span class="option-chip">Sem opções</span>'}</div>
        </div>
      `;
    })
    .join("");

  return `
    <section class="option-group custom-category-group" data-scope="${scope}">
      <div class="option-group-heading">
        <strong>Categorias adicionais</strong>
        <button class="mini-button option-add-button" type="button" data-option-action="add-custom-category" aria-label="Adicionar categoria" title="Adicionar categoria">
          <i class="fa-solid fa-plus" aria-hidden="true"></i>
        </button>
      </div>
      <div class="custom-category-list">${categoryCards || '<span class="option-chip">Nenhuma categoria adicional</span>'}</div>
    </section>
  `;
}

function handleOptionsEditorInput(event) {
  const customCategory = event.target.closest(".custom-category-editor");
  if (customCategory && event.target.matches("[data-custom-category-name]")) {
    dirtyOptionKeys.add(customCategory.dataset.customCategoryId);
    dirtyOptionValues.set(customCategory.dataset.customCategoryId, event.target.value);
    const saveButton = customCategory.querySelector("[data-option-action='save-custom-category']");
    if (saveButton) saveButton.hidden = false;
    return;
  }

  const row = event.target.closest(".option-row");
  if (!row) return;

  dirtyOptionKeys.add(row.dataset.optionId);
  dirtyOptionValues.set(row.dataset.optionId, event.target.value);
  const saveButton = row.querySelector("[data-option-action='save'], [data-option-action='save-custom-option']");
  if (saveButton) saveButton.hidden = false;
}

function addPendingOption(group) {
  const id = `new-${group}-${Date.now()}-${newOptionCounter++}`;
  optionRecords[group].push({
    id,
    groupKey: group,
    value: "",
    sortOrder: Number.MAX_SAFE_INTEGER,
    fixed: false,
    pending: true,
  });
  dirtyOptionKeys.add(id);
  dirtyOptionValues.set(id, "");
  renderOptionsEditors();
  requestAnimationFrame(() => {
    const input = document.querySelector(`[data-option-id="${id}"] input`);
    input?.focus();
  });
}

function addPendingCustomCategory() {
  const id = `new-custom-category-${Date.now()}-${newOptionCounter++}`;
  customCategories.push({
    id,
    name: "",
    sortOrder: Number.MAX_SAFE_INTEGER,
    options: [],
    pending: true,
  });
  dirtyOptionKeys.add(id);
  dirtyOptionValues.set(id, "");
  renderOptionsEditors();
  requestAnimationFrame(() => {
    const input = document.querySelector(`[data-custom-category-id="${id}"] [data-custom-category-name]`);
    input?.focus();
  });
}

function addPendingCustomOption(categoryId) {
  const category = getCustomCategory(categoryId);
  if (!category || category.pending) return;

  const id = `new-custom-option-${Date.now()}-${newOptionCounter++}`;
  category.options.push({
    id,
    categoryId,
    value: "",
    sortOrder: Number.MAX_SAFE_INTEGER,
    pending: true,
  });
  dirtyOptionKeys.add(id);
  dirtyOptionValues.set(id, "");
  renderOptionsEditors();
  requestAnimationFrame(() => {
    const input = document.querySelector(`[data-option-id="${id}"] input`);
    input?.focus();
  });
}

function removePendingOption(group, optionId) {
  optionRecords[group] = (optionRecords[group] || []).filter((record) => record.id !== optionId);
  dirtyOptionKeys.delete(optionId);
  dirtyOptionValues.delete(optionId);
  renderOptionsEditors();
}

function removePendingCustomCategory(categoryId) {
  customCategories = customCategories.filter((category) => category.id !== categoryId);
  dirtyOptionKeys.delete(categoryId);
  dirtyOptionValues.delete(categoryId);
  renderOptionsEditors();
}

function removePendingCustomOption(categoryId, optionId) {
  const category = getCustomCategory(categoryId);
  if (!category) return;
  category.options = category.options.filter((option) => option.id !== optionId);
  dirtyOptionKeys.delete(optionId);
  dirtyOptionValues.delete(optionId);
  renderOptionsEditors();
}

function clearPendingOptions() {
  optionGroups.forEach((group) => {
    optionRecords[group] = (optionRecords[group] || []).filter((record) => !isPendingOption(record.id));
  });
  customCategories = customCategories
    .filter((category) => !isPendingOption(category.id))
    .map((category) => ({
      ...category,
      options: category.options.filter((option) => !isPendingOption(option.id)),
    }));
}

function isPendingOption(optionId) {
  return String(optionId || "").startsWith("new-");
}

function findOptionRecordById(optionId) {
  for (const group of optionGroups) {
    const record = (optionRecords[group] || []).find((item) => item.id === optionId);
    if (record) return { ...record, kind: "standard-option" };
  }
  return null;
}

function findEditableRecordById(recordId) {
  const standardRecord = findOptionRecordById(recordId);
  if (standardRecord) return standardRecord;

  const category = getCustomCategory(recordId);
  if (category) return { ...category, kind: "custom-category" };

  for (const item of customCategories) {
    const option = item.options.find((record) => record.id === recordId);
    if (option) return { ...option, categoryId: item.id, kind: "custom-option" };
  }

  return null;
}

function isDuplicateOptionValue(group, optionId, value) {
  const normalized = value.trim().toLowerCase();
  return (optionRecords[group] || []).some((record) =>
    record.id !== optionId &&
    !isPendingOption(record.id) &&
    record.value.trim().toLowerCase() === normalized
  );
}

function isDuplicateCustomCategoryName(categoryId, value) {
  const normalized = value.trim().toLowerCase();
  return customCategories.some((category) =>
    category.id !== categoryId &&
    !isPendingOption(category.id) &&
    category.name.trim().toLowerCase() === normalized
  );
}

function isDuplicateCustomOptionValue(categoryId, optionId, value) {
  const normalized = value.trim().toLowerCase();
  const category = getCustomCategory(categoryId);
  if (!category) return false;

  return category.options.some((option) =>
    option.id !== optionId &&
    !isPendingOption(option.id) &&
    option.value.trim().toLowerCase() === normalized
  );
}

async function handleOptionsEditorClick(event) {
  const button = event.target.closest("[data-option-action]");
  if (!button) return;

  const action = button.dataset.optionAction;
  if (action.startsWith("add-custom") || action.startsWith("save-custom") || action.startsWith("delete-custom")) {
    await handleCustomOptionsEditorClick(button);
    return;
  }

  const row = button.closest(".option-row");
  const group = button.dataset.group || row?.dataset.group;
  const messageTarget = button.closest("#adminOptionsList") ? adminOptionsMessage : storeOptionsMessage;

  if (fixedOptionGroups.has(group)) return;
  if (row && getOptionRecord(group, row.dataset.optionId)?.fixed) return;

  try {
    button.disabled = true;

    if (action === "add") {
      addPendingOption(group);
      return;
    }

    if (!row) return;

    if (action === "delete") {
      if (isPendingOption(row.dataset.optionId)) {
        removePendingOption(group, row.dataset.optionId);
        return;
      }

      await authenticatedRpc("lc_delete_option", { p_option_id: row.dataset.optionId });
      dirtyOptionKeys.delete(row.dataset.optionId);
      dirtyOptionValues.delete(row.dataset.optionId);
      await refreshOptions();
      showOptionsMessage(messageTarget, "Opção removida.", "success");
    }

    if (action === "save") {
      const value = row.querySelector("input").value.trim();
      if (!value) {
        showOptionsMessage(messageTarget, "Digite um valor.");
        row.querySelector("input").focus();
        return;
      }
      if (isDuplicateOptionValue(group, row.dataset.optionId, value)) {
        showOptionsMessage(messageTarget, "Essa opção já existe.");
        row.querySelector("input").focus();
        return;
      }
      if (isPendingOption(row.dataset.optionId)) {
        await authenticatedRpc("lc_add_option", {
          p_group_key: group,
          p_value: value,
        });
      } else {
        await authenticatedRpc("lc_update_option", {
          p_option_id: row.dataset.optionId,
          p_value: value,
        });
      }
      dirtyOptionKeys.delete(row.dataset.optionId);
      dirtyOptionValues.delete(row.dataset.optionId);
      await refreshOptions();
      showOptionsMessage(messageTarget, "Opção salva.", "success");
    }
  } catch (error) {
    showOptionsMessage(messageTarget, readableError(error));
  } finally {
    button.disabled = false;
  }
}

async function handleCustomOptionsEditorClick(button) {
  const action = button.dataset.optionAction;
  const editor = button.closest(".custom-category-editor");
  const row = button.closest(".custom-option-row");
  const categoryId = editor?.dataset.customCategoryId || row?.dataset.customCategoryId;
  const messageTarget = button.closest("#adminOptionsList") ? adminOptionsMessage : storeOptionsMessage;

  try {
    button.disabled = true;

    if (action === "add-custom-category") {
      addPendingCustomCategory();
      return;
    }

    if (action === "add-custom-option") {
      addPendingCustomOption(categoryId);
      return;
    }

    if (action === "delete-custom-category") {
      if (isPendingOption(categoryId)) {
        removePendingCustomCategory(categoryId);
        return;
      }
      await authenticatedRpc("lc_delete_custom_category", { p_category_id: categoryId });
      dirtyOptionKeys.delete(categoryId);
      dirtyOptionValues.delete(categoryId);
      await refreshRemoteState();
      renderAll();
      showOptionsMessage(messageTarget, "Categoria removida.", "success");
      return;
    }

    if (action === "delete-custom-option") {
      if (isPendingOption(row.dataset.optionId)) {
        removePendingCustomOption(categoryId, row.dataset.optionId);
        return;
      }
      await authenticatedRpc("lc_delete_custom_option", { p_option_id: row.dataset.optionId });
      dirtyOptionKeys.delete(row.dataset.optionId);
      dirtyOptionValues.delete(row.dataset.optionId);
      await refreshRemoteState();
      renderAll();
      showOptionsMessage(messageTarget, "Opção removida.", "success");
      return;
    }

    if (action === "save-custom-category") {
      const value = editor.querySelector("[data-custom-category-name]").value.trim();
      if (!value) {
        showOptionsMessage(messageTarget, "Digite o nome da categoria.");
        editor.querySelector("[data-custom-category-name]").focus();
        return;
      }
      if (isDuplicateCustomCategoryName(categoryId, value)) {
        showOptionsMessage(messageTarget, "Essa categoria já existe.");
        editor.querySelector("[data-custom-category-name]").focus();
        return;
      }
      if (isPendingOption(categoryId)) {
        await authenticatedRpc("lc_add_custom_category", { p_name: value });
      } else {
        await authenticatedRpc("lc_update_custom_category", { p_category_id: categoryId, p_name: value });
      }
      dirtyOptionKeys.delete(categoryId);
      dirtyOptionValues.delete(categoryId);
      await refreshRemoteState();
      renderAll();
      showOptionsMessage(messageTarget, "Categoria salva.", "success");
      return;
    }

    if (action === "save-custom-option") {
      const value = row.querySelector("input").value.trim();
      if (!value) {
        showOptionsMessage(messageTarget, "Digite um valor.");
        row.querySelector("input").focus();
        return;
      }
      if (isDuplicateCustomOptionValue(categoryId, row.dataset.optionId, value)) {
        showOptionsMessage(messageTarget, "Essa opção já existe.");
        row.querySelector("input").focus();
        return;
      }
      if (isPendingOption(row.dataset.optionId)) {
        await authenticatedRpc("lc_add_custom_option", { p_category_id: categoryId, p_value: value });
      } else {
        await authenticatedRpc("lc_update_custom_option", { p_option_id: row.dataset.optionId, p_value: value });
      }
      dirtyOptionKeys.delete(row.dataset.optionId);
      dirtyOptionValues.delete(row.dataset.optionId);
      await refreshRemoteState();
      renderAll();
      showOptionsMessage(messageTarget, "Opção salva.", "success");
    }
  } catch (error) {
    showOptionsMessage(messageTarget, readableError(error));
  } finally {
    button.disabled = false;
  }
}

function toggleStoreOptionsMode(forceOpen = null) {
  const shouldOpen = forceOpen === null ? storeOptionsPanel.hidden : forceOpen;
  storeOptionsPanel.hidden = !shouldOpen;
  form.classList.toggle("is-options-mode", shouldOpen);
  formTitle.textContent = shouldOpen ? "Editar opções" : "Cadastrar lead";
  toggleOptionsEditButton.innerHTML = shouldOpen
    ? '<i class="fa-solid fa-arrow-left" aria-hidden="true"></i> Sair'
    : "Editar opções";
  toggleOptionsEditButton.classList.toggle("is-exit-mode", shouldOpen);
  cancelEditButton.hidden = shouldOpen || !editingIdInput.value;
  clearFormButton.hidden = shouldOpen || clearFormButton.hidden;
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
  clearPendingOptions();
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

    const record = findEditableRecordById(optionId);
    if (!record) throw new Error("Alteração temporária não encontrada.");

    if (record.kind === "standard-option") {
      if (isDuplicateOptionValue(record.groupKey, optionId, value)) {
        throw new Error(`A opção "${value}" já existe.`);
      }
      if (isPendingOption(optionId)) {
        await authenticatedRpc("lc_add_option", {
          p_group_key: record.groupKey,
          p_value: value,
        });
      } else {
        await authenticatedRpc("lc_update_option", {
          p_option_id: optionId,
          p_value: value,
        });
      }
    }

    if (record.kind === "custom-category") {
      if (isDuplicateCustomCategoryName(optionId, value)) {
        throw new Error(`A categoria "${value}" já existe.`);
      }
      if (isPendingOption(optionId)) {
        await authenticatedRpc("lc_add_custom_category", { p_name: value });
      } else {
        await authenticatedRpc("lc_update_custom_category", {
          p_category_id: optionId,
          p_name: value,
        });
      }
    }

    if (record.kind === "custom-option") {
      if (isDuplicateCustomOptionValue(record.categoryId, optionId, value)) {
        throw new Error(`A opção "${value}" já existe.`);
      }
      if (isPendingOption(optionId)) {
        await authenticatedRpc("lc_add_custom_option", {
          p_category_id: record.categoryId,
          p_value: value,
        });
      } else {
        await authenticatedRpc("lc_update_custom_option", {
          p_option_id: optionId,
          p_value: value,
        });
      }
    }
  }

  dirtyOptionKeys.clear();
  dirtyOptionValues.clear();
  await refreshRemoteState();
  renderAll();
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

  analyticsSections.forEach((section) => {
    renderAnalyticsCategoryCards(section, filtered);
  });
  renderCustomAnalyticsSections(filtered);
  updateAiContextLabel(filtered);
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

function renderAnalyticsCategoryCards(section, rows) {
  const container = $(section.container);
  const summary = $(section.summary);
  if (!container || !summary) return;

  const ranking = buildAnalyticsRanking(rows, section.key);
  const total = rows.length;

  summary.innerHTML = ranking.length
    ? `<span><b>${ranking.length}</b> categorias</span><span><b>${total}</b> ${total === 1 ? "lead" : "leads"}</span>`
    : "<span>Sem registros no filtro atual</span>";

  if (!ranking.length) {
    container.innerHTML = `
      <div class="analytics-empty-card">
        <strong>Sem registros</strong>
        <span>Ajuste os filtros acima para encontrar leads.</span>
      </div>
    `;
    return;
  }

  container.innerHTML = ranking
    .map((item) => {
      return `
        <article class="analytics-category-card">
          <div class="analytics-lead-count-badge">
            <b>${item.count}</b>
            <span>${item.count === 1 ? "lead" : "leads"}</span>
          </div>
          <div class="analytics-category-main">
            <strong>${escapeHtml(item.value)}</strong>
          </div>
          <div class="analytics-category-meta">
            <span>${item.visited} visitas</span>
            <span>${item.bought} compras</span>
          </div>
          <button
            class="mini-button analytics-inspect-button"
            type="button"
            data-analytics-inspect
            data-analytics-section="${section.id}"
            data-analytics-value="${escapeHtml(item.value)}"
          >
            Listar
          </button>
        </article>
      `;
    })
    .join("");
}

function renderCustomAnalyticsSections(rows) {
  if (!analyticsCustomSections) return;

  analyticsCustomSections.innerHTML = customCategories
    .map((category) => `
      <article class="analytics-section-card">
        <div class="analytics-section-heading">
          <div>
            <span>${escapeHtml(category.name)}</span>
            <strong data-custom-analytics-summary="${category.id}">Sem dados</strong>
          </div>
        </div>
        <div class="analytics-category-list" data-custom-analytics-list="${category.id}"></div>
      </article>
    `)
    .join("");

  customCategories.forEach((category) => {
    renderAnalyticsCategoryCards({
      id: `custom:${category.id}`,
      label: category.name,
      key: `custom:${category.id}`,
      container: `[data-custom-analytics-list="${category.id}"]`,
      summary: `[data-custom-analytics-summary="${category.id}"]`,
    }, rows);
  });
}

function buildAnalyticsRanking(rows, key) {
  const groups = new Map();

  rows.forEach((lead) => {
    const value = getAnalyticsGroupValue(lead, key);
    const current = groups.get(value) || {
      value,
      count: 0,
      visited: 0,
      bought: 0,
      latestAt: "",
    };
    current.count += 1;
    if (lead.visited === "Sim") current.visited += 1;
    if (lead.bought === "Sim") current.bought += 1;
    if (!current.latestAt || lead.createdAt > current.latestAt) current.latestAt = lead.createdAt;
    groups.set(value, current);
  });

  return Array.from(groups.values()).sort((a, b) => {
    if (b.count !== a.count) return b.count - a.count;
    return String(b.latestAt).localeCompare(String(a.latestAt));
  });
}

function getAnalyticsGroupValue(lead, key) {
  if (key.startsWith("custom:")) {
    const categoryId = key.slice("custom:".length);
    return lead.customValues[categoryId] || "Sem resposta";
  }
  return lead[key] || "Sem resposta";
}

function handleAnalyticsClick(event) {
  const button = event.target.closest("[data-analytics-inspect]");
  if (!button) return;
  openAnalyticsInspector(button.dataset.analyticsSection, button.dataset.analyticsValue);
}

function openAnalyticsInspector(sectionId, value) {
  const section = getAnalyticsSections().find((item) => item.id === sectionId);
  if (!section) return;

  const filtered = getAnalyticsLeads();
  const categoryLeads = filtered
    .filter((lead) => getAnalyticsGroupValue(lead, section.key) === value)
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));

  analyticsInspectorEyebrow.textContent = section.label;
  analyticsInspectorTitle.textContent = value;
  analyticsInspectorSubtitle.textContent =
    `${categoryLeads.length} ${categoryLeads.length === 1 ? "lead encontrado" : "leads encontrados"} no filtro atual`;

  analyticsInspectorList.innerHTML = categoryLeads.length
    ? categoryLeads.map(renderAnalyticsLeadRow).join("")
    : `<div class="analytics-empty-card"><strong>Nenhum lead</strong><span>Esse recorte não tem registros.</span></div>`;

  analyticsInspectorModal.hidden = false;
  syncModalLock();
}

function closeAnalyticsInspector() {
  analyticsInspectorModal.hidden = true;
  analyticsInspectorList.innerHTML = "";
  syncModalLock();
}

function exportLeadsToExcel() {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;

  const exportRows = [...leads].sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  if (!exportRows.length) {
    showAppNotification("Nenhum lead para exportar.", "error");
    return;
  }

  const workbook = buildLeadsExcelWorkbook(exportRows);
  const blob = new Blob(["\ufeff", workbook], { type: "application/vnd.ms-excel;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `leads-${formatExportFileDate(new Date())}.xls`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  showAppNotification("Excel exportado.");
}

function buildLeadsExcelWorkbook(exportRows) {
  const visited = countByValue(exportRows, "visited", "Sim");
  const bought = countByValue(exportRows, "bought", "Sim");
  const totalRevenue = exportRows.reduce((sum, lead) => sum + Number(lead.purchaseAmount || 0), 0);
  const columns = buildLeadExportColumns();
  const summaryRows = [
    ["Gerado em", formatDateTime(new Date().toISOString())],
    ["Escopo", "Todos os leads carregados para este acesso"],
    ["Total de leads", exportRows.length],
    ["Visitaram a loja", visited],
    ["Compraram", bought],
    ["Conversão", formatPercent(bought, exportRows.length)],
    ["Receita registrada", formatCurrency(totalRevenue)],
  ];

  return `<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
    <style>
      body { font-family: Arial, sans-serif; color: #111111; }
      h1 { margin: 0 0 6px; font-size: 24px; }
      .subtitle { margin: 0 0 18px; color: #555555; }
      table { width: 100%; border-collapse: collapse; margin-bottom: 18px; }
      th, td { border: 1px solid #bfbfbf; padding: 8px; vertical-align: top; mso-number-format: "\\@"; }
      th { background: #111111; color: #ffffff; font-weight: 700; }
      .summary th { width: 220px; text-align: left; background: #16855f; }
      .summary td { font-weight: 700; }
      .currency { text-align: right; white-space: nowrap; }
      .date { white-space: nowrap; }
      .notes { min-width: 320px; }
    </style>
  </head>
  <body>
    <h1>Exportação de Leads</h1>
    <p class="subtitle">Controle de Leads | Ótica</p>
    <table class="summary">
      <tbody>
        ${summaryRows.map(([label, value]) => `<tr><th>${excelCell(label)}</th><td>${excelCell(value)}</td></tr>`).join("")}
      </tbody>
    </table>
    <table>
      <thead>
        <tr>${columns.map((column) => `<th>${excelCell(column.header)}</th>`).join("")}</tr>
      </thead>
      <tbody>
        ${exportRows.map((lead, index) => `
          <tr>
            ${columns.map((column) => `<td class="${column.className || ""}">${excelCell(column.value(lead, index))}</td>`).join("")}
          </tr>
        `).join("")}
      </tbody>
    </table>
  </body>
</html>`;
}

function buildLeadExportColumns() {
  return [
    { header: "#", value: (_lead, index) => index + 1 },
    { header: "Registrado em", className: "date", value: (lead) => formatDateTime(lead.createdAt) },
    { header: "Loja", value: (lead) => lead.storeName },
    { header: "Nome do lead", value: (lead) => lead.name },
    { header: "Telefone", value: (lead) => lead.phone },
    { header: "Canal", value: (lead) => lead.channel || "Sem resposta" },
    { header: "Campanha", value: (lead) => lead.campaign || "Sem resposta" },
    { header: "Início da conversa", value: (lead) => lead.conversationStart || "Sem resposta" },
    { header: "Conclusão", value: (lead) => lead.conclusion || "Sem resposta" },
    { header: "Visitou a loja", value: (lead) => lead.visited || "Sem resposta" },
    { header: "Comprou", value: (lead) => lead.bought || "Sem resposta" },
    { header: "Valor da compra", className: "currency", value: (lead) => lead.purchaseAmount ? formatCurrency(lead.purchaseAmount) : "" },
    { header: "OS", value: (lead) => lead.serviceOrder || "" },
    { header: "Inspecionado", value: (lead) => lead.inspected ? "Sim" : "Não" },
    ...customCategories.map((category) => ({
      header: category.name,
      value: (lead) => lead.customValues[category.id] || "Sem resposta",
    })),
    { header: "Observações", className: "notes", value: (lead) => lead.notes || "" },
    { header: "ID interno", value: (lead) => lead.id },
  ];
}

function excelCell(value) {
  const text = String(value ?? "");
  const protectedText = /^[=+\-@]/.test(text.trim()) ? `'${text}` : text;
  return escapeHtml(protectedText).replace(/\r?\n/g, "<br>");
}

function formatExportFileDate(date) {
  return date.toISOString().slice(0, 19).replace(/[:T]/g, "-");
}

function openAiChat() {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;

  updateAiContextLabel();
  renderAiMessages();
  aiChatDialogSettingsState();
  aiChatModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => aiChatInput.focus());
}

function closeAiChat() {
  aiChatModal.hidden = true;
  aiSettingsPanel.hidden = true;
  aiChatDialogSettingsState();
  clearAiSettingsMessage();
  syncModalLock();
}

function toggleAiSettingsPanel() {
  aiSettingsPanel.hidden = !aiSettingsPanel.hidden;
  aiChatDialogSettingsState();
  if (!aiSettingsPanel.hidden) {
    renderAiSettingsForm();
  }
}

function aiChatDialogSettingsState() {
  const isOpen = !aiSettingsPanel.hidden;
  aiChatModal.querySelector(".ai-chat-dialog")?.classList.toggle("is-settings-open", isOpen);
  aiSettingsToggle.setAttribute("aria-expanded", String(isOpen));
}

function handleAiProviderChange() {
  const provider = aiProvider.value;
  renderAiModelOptions(provider);
  aiModel.value = aiSettings.models[provider] || aiProviderOptions[provider]?.models[0] || "";
  aiApiKey.value = aiSettings.apiKeys[provider] || "";
}

function handleAiSettingsSubmit(event) {
  event.preventDefault();
  const provider = aiProvider.value;
  aiSettings.provider = provider;
  aiSettings.models[provider] = aiModel.value;
  aiSettings.apiKeys[provider] = aiApiKey.value.trim();
  aiSettings.systemPrompt = aiSystemPrompt.value.trim() || DEFAULT_AI_SYSTEM_PROMPT;
  saveAiSettings();
  showAiSettingsMessage("Configuração salva.", "success");
}

async function handleAiChatSubmit(event) {
  event.preventDefault();
  const content = aiChatInput.value.trim();
  if (!content || aiIsSending) return;

  const provider = aiSettings.provider;
  const apiKey = aiSettings.apiKeys[provider];
  if (!apiKey) {
    aiSettingsPanel.hidden = false;
    aiChatDialogSettingsState();
    renderAiSettingsForm();
    showAiSettingsMessage("Informe a chave de API.", "error");
    return;
  }

  aiMessages.push({ role: "user", content });
  aiChatInput.value = "";
  renderAiMessages();
  setAiSending(true);

  try {
    const answer = await requestAiAnalysis();
    aiMessages.push({ role: "assistant", content: answer });
  } catch (error) {
    aiMessages.push({ role: "assistant", content: readableError(error) });
  } finally {
    setAiSending(false);
    renderAiMessages();
  }
}

async function requestAiAnalysis() {
  const provider = aiSettings.provider;
  const model = aiSettings.models[provider] || aiProviderOptions[provider]?.models[0];
  const context = buildAiLeadContext(getAnalyticsLeads());
  const systemPrompt = `${aiSettings.systemPrompt || DEFAULT_AI_SYSTEM_PROMPT}\n\nContexto atual dos leads filtrados:\n${context}`;

  if (provider === "gemini") {
    return requestGeminiAnalysis({ model, systemPrompt, messages: aiMessages, apiKey: aiSettings.apiKeys.gemini });
  }

  if (provider === "deepseek") {
    return requestDeepSeekAnalysis({ model, systemPrompt, messages: aiMessages, apiKey: aiSettings.apiKeys.deepseek });
  }

  throw new Error("Provedor de IA inválido.");
}

async function requestGeminiAnalysis({ model, systemPrompt, messages, apiKey }) {
  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: {
          parts: [{ text: systemPrompt }],
        },
        contents: messages.map((message) => ({
          role: message.role === "assistant" ? "model" : "user",
          parts: [{ text: message.content }],
        })),
        generationConfig: {
          temperature: 0.35,
        },
      }),
    },
  );

  const data = await readAiResponse(response);
  const text = data?.candidates?.[0]?.content?.parts
    ?.map((part) => part.text || "")
    .join("")
    .trim();

  if (!text) throw new Error("A IA não retornou texto.");
  return text;
}

async function requestDeepSeekAnalysis({ model, systemPrompt, messages, apiKey }) {
  const response = await fetch("https://api.deepseek.com/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: systemPrompt },
        ...messages.map((message) => ({
          role: message.role === "assistant" ? "assistant" : "user",
          content: message.content,
        })),
      ],
      stream: false,
      temperature: 0.35,
    }),
  });

  const data = await readAiResponse(response);
  const text = data?.choices?.[0]?.message?.content?.trim();
  if (!text) throw new Error("A IA não retornou texto.");
  return text;
}

async function readAiResponse(response) {
  const text = await response.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }

  if (!response.ok) {
    const message = data?.error?.message || data?.message || text || "Erro ao chamar a IA.";
    throw new Error(message);
  }

  return data;
}

function buildAiLeadContext(filteredLeads) {
  const total = filteredLeads.length;
  const bought = countByValue(filteredLeads, "bought", "Sim");
  const visited = countByValue(filteredLeads, "visited", "Sim");

  return JSON.stringify({
    gerado_em: new Date().toISOString(),
    filtros: buildAnalyticsFilterSnapshot(),
    resumo: {
      leads: total,
      visitaram: visited,
      compraram: bought,
      conversao: formatPercent(bought, total),
    },
    leads: filteredLeads.map(leadToAiRecord),
  }, null, 2);
}

function buildAnalyticsFilterSnapshot() {
  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  return {
    loja: getSelectedOptionText(analyticsStoreFilter),
    canal: getSelectedOptionText(analyticsChannelFilter),
    campanha: getSelectedOptionText(analyticsCampaignFilter),
    resultado: getSelectedOptionText(analyticsConclusionFilter),
    visita: getSelectedOptionText(analyticsVisitedFilter),
    compra: getSelectedOptionText(analyticsBoughtFilter),
    data: mode === "single"
      ? { modo: "data_especifica", dia: analyticsSingleDate.value || null }
      : { modo: "periodo", inicio: analyticsStartDate.value || null, fim: analyticsEndDate.value || null },
    categorias_adicionais: getCustomFilterValues(analyticsCustomFilters).map(({ categoryId, value }) => ({
      categoria: customCategories.find((category) => category.id === categoryId)?.name || categoryId,
      valor: value,
    })),
  };
}

function leadToAiRecord(lead) {
  return {
    id: lead.id,
    nome: lead.name,
    telefone: lead.phone,
    loja: lead.storeName,
    canal: lead.channel || null,
    campanha: lead.campaign || null,
    inicio_da_conversa: lead.conversationStart || null,
    conclusao: lead.conclusion || null,
    visitou_a_loja: lead.visited || null,
    comprou: lead.bought || null,
    valor_da_compra: lead.purchaseAmount,
    valor_da_compra_formatado: lead.purchaseAmount ? formatCurrency(lead.purchaseAmount) : null,
    os: lead.serviceOrder || null,
    observacoes: lead.notes || null,
    inspecionado: Boolean(lead.inspected),
    categorias_adicionais: Object.fromEntries(
      lead.customValueRows.map((item) => [item.categoryName, item.value]),
    ),
    registrado_em: lead.createdAt,
    registrado_em_formatado: formatDateTime(lead.createdAt),
  };
}

function renderAiMessages() {
  if (!aiChatMessages) return;

  if (!aiMessages.length) {
    aiChatMessages.innerHTML = `
      <div class="ai-empty-state">
        <i class="fa-solid fa-wand-magic-sparkles" aria-hidden="true"></i>
        <strong>Pronta para analisar.</strong>
        <span>O recorte atual de métricas será usado como contexto.</span>
      </div>
    `;
    return;
  }

  aiChatMessages.innerHTML = aiMessages
    .map((message) => `
      <article class="ai-message ${message.role === "assistant" ? "assistant" : "user"}">
        <span>${message.role === "assistant" ? "IA" : "Você"}</span>
        <p>${escapeHtml(message.content)}</p>
      </article>
    `)
    .join("");
  scrollAiChatToBottom();
}

function setAiSending(isSending) {
  aiIsSending = isSending;
  aiChatSend.disabled = isSending;
  aiChatInput.disabled = isSending;
  aiChatSend.innerHTML = isSending
    ? '<i class="fa-solid fa-spinner fa-spin" aria-hidden="true"></i> Analisando'
    : '<i class="fa-solid fa-paper-plane" aria-hidden="true"></i> Enviar';
}

function scrollAiChatToBottom() {
  requestAnimationFrame(() => {
    aiChatMessages.scrollTop = aiChatMessages.scrollHeight;
  });
}

function updateAiContextLabel(rows = getAnalyticsLeads()) {
  if (!aiLeadContextLabel) return;
  const total = rows.length;
  aiLeadContextLabel.textContent = `${total} ${total === 1 ? "lead" : "leads"} no filtro atual`;
}

function loadAiSettings() {
  try {
    aiSettings = normalizeAiSettings(JSON.parse(localStorage.getItem(AI_SETTINGS_STORAGE_KEY) || "null"));
  } catch {
    aiSettings = createDefaultAiSettings();
  }
}

function saveAiSettings() {
  localStorage.setItem(AI_SETTINGS_STORAGE_KEY, JSON.stringify(aiSettings));
}

function normalizeAiSettings(saved) {
  const defaults = createDefaultAiSettings();
  if (!saved || typeof saved !== "object") return defaults;

  const provider = aiProviderOptions[saved.provider] ? saved.provider : defaults.provider;
  return {
    provider,
    models: {
      ...defaults.models,
      ...(saved.models || {}),
    },
    apiKeys: {
      ...defaults.apiKeys,
      ...(saved.apiKeys || {}),
    },
    systemPrompt: typeof saved.systemPrompt === "string" && saved.systemPrompt.trim()
      ? saved.systemPrompt
      : defaults.systemPrompt,
  };
}

function createDefaultAiSettings() {
  return {
    provider: "gemini",
    models: {
      gemini: aiProviderOptions.gemini.models[0],
      deepseek: aiProviderOptions.deepseek.models[0],
    },
    apiKeys: {
      gemini: "",
      deepseek: "",
    },
    systemPrompt: DEFAULT_AI_SYSTEM_PROMPT,
  };
}

function renderAiSettingsForm() {
  aiProvider.value = aiSettings.provider;
  renderAiModelOptions(aiSettings.provider);
  aiModel.value = aiSettings.models[aiSettings.provider] || aiProviderOptions[aiSettings.provider].models[0];
  aiApiKey.value = aiSettings.apiKeys[aiSettings.provider] || "";
  aiSystemPrompt.value = aiSettings.systemPrompt || DEFAULT_AI_SYSTEM_PROMPT;
}

function renderAiModelOptions(provider) {
  const models = aiProviderOptions[provider]?.models || [];
  const current = aiSettings.models[provider] || models[0] || "";
  const entries = models.includes(current) ? models : [...models, current].filter(Boolean);
  aiModel.innerHTML = entries
    .map((model) => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`)
    .join("");
}

function showAiSettingsMessage(message, type = "error") {
  aiSettingsMessage.textContent = message;
  aiSettingsMessage.classList.toggle("success", type === "success");
}

function clearAiSettingsMessage() {
  showAiSettingsMessage("");
}

async function handleAnalyticsInspectorClick(event) {
  const inspectedToggle = event.target.closest("[data-inspected-toggle]");
  if (inspectedToggle) {
    await toggleLeadInspected(inspectedToggle);
    return;
  }

  const button = event.target.closest("[data-inspector-lead-id]");
  if (!button) return;
  openLeadDetailsModal(button.dataset.inspectorLeadId);
}

function renderAnalyticsLeadRow(lead) {
  const createdAt = formatDateTime(lead.createdAt);
  return `
    <article class="analytics-lead-item${lead.inspected ? " is-inspected" : ""}">
      <button class="analytics-lead-open" type="button" data-inspector-lead-id="${lead.id}">
        <span class="analytics-lead-avatar" aria-hidden="true">
          <i class="fa-solid fa-user"></i>
        </span>
        <span class="analytics-lead-identity">
          <strong>${escapeHtml(lead.name)}</strong>
          <span>${escapeHtml(lead.storeName || "Loja não informada")}</span>
          <time datetime="${escapeHtml(lead.createdAt)}">${createdAt}</time>
        </span>
      </button>
      <label class="analytics-inspected-toggle">
        <input
          type="checkbox"
          data-inspected-toggle
          data-lead-id="${lead.id}"
          ${lead.inspected ? "checked" : ""}
        />
        <span>Inspecionado</span>
      </label>
    </article>
  `;
}

async function toggleLeadInspected(input) {
  const lead = leads.find((item) => item.id === input.dataset.leadId);
  if (!lead) return;

  const nextValue = input.checked;
  const previousValue = Boolean(lead.inspected);
  lead.inspected = nextValue;
  input.closest(".analytics-lead-item")?.classList.toggle("is-inspected", nextValue);

  try {
    await authenticatedRpc("lc_set_lead_inspected", {
      p_lead_id: lead.id,
      p_inspected: nextValue,
    });
    showAppNotification("Atualizado");
  } catch (error) {
    lead.inspected = previousValue;
    input.checked = previousValue;
    input.closest(".analytics-lead-item")?.classList.toggle("is-inspected", previousValue);
    showAppNotification(readableError(error), "error");
  }
}

function getAnalyticsSections() {
  return [
    ...analyticsSections,
    ...customCategories.map((category) => ({
      id: `custom:${category.id}`,
      label: category.name,
      key: `custom:${category.id}`,
    })),
  ];
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
      matchesFilter(lead.visited || "sem-resposta", visitedFilter.value) &&
      matchesFilter(lead.bought || "sem-resposta", boughtFilter.value);
    const matchesCustomFilters = getCustomFilterValues(customLeadFilters)
      .every(({ categoryId, value }) => matchesFilter(lead.customValues[categoryId] || "sem-resposta", value));
    const createdDate = lead.createdAt.slice(0, 10);
    const matchesStart = !startDateFilter.value || createdDate >= startDateFilter.value;
    const matchesEnd = !endDateFilter.value || createdDate <= endDateFilter.value;

    return matchesSearch && matchesSimpleFilters && matchesCustomFilters && matchesStart && matchesEnd;
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
  if (analyticsChannelFilter.value) {
    result = result.filter((lead) => lead.channel === analyticsChannelFilter.value);
  }
  if (analyticsCampaignFilter.value) {
    result = result.filter((lead) => lead.campaign === analyticsCampaignFilter.value);
  }
  if (analyticsConclusionFilter.value) {
    result = result.filter((lead) => lead.conclusion === analyticsConclusionFilter.value);
  }
  if (analyticsVisitedFilter.value) {
    result = result.filter((lead) => (lead.visited || "sem-resposta") === analyticsVisitedFilter.value);
  }
  if (analyticsBoughtFilter.value) {
    result = result.filter((lead) => (lead.bought || "sem-resposta") === analyticsBoughtFilter.value);
  }

  getCustomFilterValues(analyticsCustomFilters).forEach(({ categoryId, value }) => {
    result = result.filter((lead) => (lead.customValues[categoryId] || "sem-resposta") === value);
  });

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
  analyticsQuickRangeField.hidden = mode !== "range";
  renderAdminAnalytics();
}

function setAnalyticsQuickRange(range) {
  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  if (mode !== "range") return;
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
  customLeadFilters.querySelectorAll("[data-custom-filter]").forEach((element) => {
    element.value = "";
  });
  renderLeadList();
}

function renderTodayCount() {
  setTodayLabel();
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

function mapTechnicianRow(row) {
  return {
    id: row.id,
    username: row.nick,
    fullName: row.full_name,
    createdAt: row.created_at,
    isActive: row.is_active !== false,
  };
}

function mapLeadRow(row) {
  const customValueRows = normalizeCustomValueRows(row.custom_values);
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
    notes: row.notes || "",
    inspected: Boolean(row.inspected),
    customValueRows,
    customValues: Object.fromEntries(customValueRows.map((item) => [item.categoryId, item.value])),
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

function applyCustomCategoryRows(rows) {
  customCategories = (rows || [])
    .map((row) => ({
      id: row.id,
      name: row.name,
      sortOrder: row.sort_order,
      options: normalizeCustomOptions(row.options),
    }))
    .sort((a, b) => a.sortOrder - b.sortOrder);
}

function normalizeCustomOptions(optionsValue) {
  const rows = Array.isArray(optionsValue) ? optionsValue : [];
  return rows
    .map((option) => ({
      id: option.id,
      categoryId: option.category_id,
      value: option.value,
      sortOrder: option.sort_order,
    }))
    .sort((a, b) => a.sortOrder - b.sortOrder);
}

function normalizeCustomValueRows(value) {
  const rows = Array.isArray(value) ? value : [];
  return rows.map((item) => ({
    categoryId: item.category_id,
    categoryName: item.category_name,
    value: item.value,
  }));
}

function buildCustomValuesPayload() {
  return customCategories
    .map((category) => ({
      category_id: category.id,
      value: selectedCustomValues[category.id] || "",
    }))
    .filter((item) => item.value);
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
  targetForm.querySelectorAll("button, input, select, textarea").forEach((element) => {
    element.disabled = isBusy;
  });
}

function fillSelect(select, values, firstLabel) {
  const currentValue = select.value;
  select.innerHTML = `<option value="">${firstLabel}</option>` +
    values.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join("");
  select.value = values.includes(currentValue) ? currentValue : "";
}

function fillSelectWithEntries(select, entries, firstLabel) {
  const currentValue = select.value;
  select.innerHTML = `<option value="">${firstLabel}</option>` +
    entries.map(({ value, label }) => `<option value="${escapeHtml(value)}">${escapeHtml(label)}</option>`).join("");
  select.value = entries.some((entry) => entry.value === currentValue) ? currentValue : "";
}

function getSelectedOptionText(select) {
  const option = select.options[select.selectedIndex];
  return option?.textContent || "";
}

function withNoAnswer(values) {
  const entries = values.map((value) => ({
    value,
    label: value === "sem-resposta" ? "Sem resposta" : value,
  }));
  if (values.includes("sem-resposta")) return entries;
  return [...entries, { value: "sem-resposta", label: "Sem resposta" }];
}

function matchesFilter(value, filterValue) {
  return !filterValue || value === filterValue;
}

function getCustomFilterValues(container) {
  if (!container) return [];
  return Array.from(container.querySelectorAll("[data-custom-filter]"))
    .map((select) => ({
      categoryId: select.dataset.customFilter,
      value: select.value,
    }))
    .filter((item) => item.value);
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

function formatDateTime(value) {
  if (!value) return "";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
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
  const channelBrand = group === "channel" ? getChannelBrand(value) : "";
  if (channelBrand) return `choice-${channelBrand}`;
  if ((group === "visited" || group === "bought") && value === "Sim") return "choice-yes";
  if ((group === "visited" || group === "bought") && value === "Não") return "choice-no";
  return "";
}

function getChoiceLabel(group, value) {
  const escapedValue = escapeHtml(value);
  const channelBrand = group === "channel" ? getChannelBrand(value) : "";
  if (channelBrand === "instagram") {
    return `<span class="choice-brand-mark" aria-hidden="true">${getInstagramLogoSvg()}</span><span>${escapedValue}</span>`;
  }
  if (channelBrand === "facebook") {
    return `<span class="choice-brand-mark" aria-hidden="true">${getFacebookLogoSvg()}</span><span>${escapedValue}</span>`;
  }
  if (channelBrand === "google") {
    return `<span class="choice-brand-mark" aria-hidden="true">${getGoogleAdsLogoSvg()}</span><span>${escapedValue}</span>`;
  }
  if (channelBrand === "linkedin") {
    return `<span class="choice-brand-mark" aria-hidden="true">${getLinkedInLogoSvg()}</span><span>${escapedValue}</span>`;
  }
  return escapedValue;
}

function getChannelBrand(value) {
  const normalized = String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  if (normalized.includes("instagram")) return "instagram";
  if (normalized.includes("facebook")) return "facebook";
  if (normalized.includes("google")) return "google";
  if (normalized.includes("linkedin")) return "linkedin";
  return "";
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
      <path class="brand-fill" d="M14.4 8.1h2.15V4.55A27.7 27.7 0 0 0 13.42 4c-3.1 0-5.22 1.9-5.22 5.36v3H4.75v3.97H8.2V24h4.22v-7.67h3.3l.62-3.97h-3.92V9.75c0-1.15.31-1.65 1.98-1.65Z"></path>
    </svg>
  `;
}

function getGoogleAdsLogoSvg() {
  return `
    <svg viewBox="0 0 28 24" focusable="false" aria-hidden="true">
      <path class="logo-color" fill="#4285f4" d="M10.7 2.1a3.7 3.7 0 0 1 5.05 1.35l9.4 16.25a3.7 3.7 0 1 1-6.4 3.7L9.35 7.15A3.7 3.7 0 0 1 10.7 2.1Z"></path>
      <path class="logo-color" fill="#34a853" d="M10.78 3.36a3.72 3.72 0 0 1 6.44 3.72L7.65 23.63a3.72 3.72 0 0 1-6.44-3.72L10.78 3.36Z"></path>
      <circle class="logo-color" fill="#fbbc04" cx="4.38" cy="20.08" r="3.72"></circle>
    </svg>
  `;
}

function getLinkedInLogoSvg() {
  return `
    <svg viewBox="0 0 24 24" focusable="false" aria-hidden="true">
      <path class="brand-fill" d="M20.45 20.45h-3.56v-5.58c0-1.33-.02-3.04-1.85-3.04-1.85 0-2.13 1.45-2.13 2.95v5.67H9.35V9h3.42v1.56h.05c.48-.9 1.64-1.85 3.37-1.85 3.6 0 4.26 2.37 4.26 5.45v6.29ZM5.34 7.43a2.06 2.06 0 1 1 0-4.13 2.06 2.06 0 0 1 0 4.13Zm1.78 13.02H3.55V9h3.57v11.45ZM22.22 0H1.78C.8 0 0 .78 0 1.74v20.52C0 23.22.8 24 1.78 24h20.44c.98 0 1.78-.78 1.78-1.74V1.74C24 .78 23.2 0 22.22 0Z"></path>
    </svg>
  `;
}

function getOptionRecord(group, optionId) {
  return (optionRecords[group] || []).find((record) => record.id === optionId) || null;
}

function getCustomCategory(categoryId) {
  return customCategories.find((category) => category.id === categoryId) || null;
}

function renderTag(value) {
  return value ? `<span>${escapeHtml(value)}</span>` : "";
}

function renderCustomLeadTags(lead) {
  return lead.customValueRows
    .map((item) => renderTag(`${item.categoryName}: ${item.value}`))
    .join("");
}

function renderCustomLeadDetailItems(lead) {
  return lead.customValueRows
    .map((item) => renderLeadDetailItem(item.categoryName, item.value))
    .join("");
}

function renderLeadNotes(notes) {
  return notes
    ? `<p class="lead-notes lead-notes-preview"><strong>Observações:</strong> ${escapeHtml(notes)}</p>`
    : "";
}

function formatWhatsAppUrl(phone) {
  const digits = String(phone || "").replace(/\D/g, "");
  const normalized = digits.startsWith("55") && digits.length >= 12 ? digits : `55${digits}`;
  return `https://wa.me/${normalized}`;
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
  const label = isPassword ? "Ocultar senha" : "Mostrar senha";
  button.setAttribute("aria-label", label);
  button.title = label;
  button.innerHTML = `<i class="fa-solid ${isPassword ? "fa-eye-slash" : "fa-eye"}" aria-hidden="true"></i>`;
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
  const label = isDark ? "Modo claro" : "Modo escuro";
  themeToggle.setAttribute("aria-label", label);
  themeToggle.title = label;
  themeToggle.innerHTML = `<i class="fa-solid ${isDark ? "fa-sun" : "fa-moon"}" aria-hidden="true"></i>`;
  themeToggle.setAttribute("aria-pressed", String(isDark));
}

function readableError(error) {
  return error?.message || String(error || "Erro inesperado.");
}

function isMissingRpcError(error) {
  const message = readableError(error).toLowerCase();
  return message.includes("could not find the function") || message.includes("function") && message.includes("does not exist");
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

function showTechnicianMessage(message, type = "error") {
  technicianMessage.textContent = message;
  technicianMessage.classList.toggle("success", type === "success");
  if (type === "success") showAppNotification(message, "success");
}

function clearTechnicianMessage() {
  showTechnicianMessage("");
}

function showAdminAccountMessage(message, type = "error") {
  adminAccountMessage.textContent = message;
  adminAccountMessage.classList.toggle("success", type === "success");
  if (type === "success") showAppNotification(message, "success");
}

function clearAdminAccountMessage() {
  showAdminAccountMessage("");
}

function showManagedAccountMessage(message, type = "error") {
  managedAccountMessage.textContent = message;
  managedAccountMessage.classList.toggle("success", type === "success");
}

function clearManagedAccountMessage() {
  showManagedAccountMessage("");
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
