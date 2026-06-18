const SUPABASE_URL = "https://menlvmsgkhgqxiydphbn.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1lbmx2bXNna2hncXhpeWRwaGJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEyNTYxNzEsImV4cCI6MjA5NjgzMjE3MX0.ylQcT5KnVDvdP3Wa8ZKdI6FpXWnjXAkpzpfzRw0FP30";
const SESSION_STORAGE_KEY = "lead-control-session";
const THEME_STORAGE_KEY = "lead-control-theme";
const AI_SETTINGS_STORAGE_KEY = "lead-control-ai-settings";
const AI_CHAT_STORAGE_KEY = "lead-control-ai-chats";

const LEGACY_AI_SYSTEM_PROMPT = `Você é uma IA especialista em análise comercial de leads para óticas. Analise os registros filtrados, encontre padrões, gargalos e oportunidades, compare lojas, canais, campanhas e resultados, e responda com recomendações objetivas para aumentar visitas, compras e conversão. Use apenas os dados fornecidos no contexto, indique quando houver pouca amostra e priorize ações práticas.`;
const DEFAULT_AI_SYSTEM_PROMPT = `Você é uma IA especialista em análise comercial de leads para óticas. Responda somente ao que o usuário perguntou, sem antecipar análises, recomendações ou assuntos que não foram pedidos. Se o usuário apenas cumprimentar, cumprimente de volta de forma breve e pergunte como pode ajudar. Quando o usuário pedir análise, use os leads filtrados como contexto, encontre padrões, gargalos e oportunidades, compare lojas, canais, campanhas e resultados quando isso for relevante para a pergunta, indique quando houver pouca amostra e priorize ações práticas. Use apenas os dados fornecidos no contexto.`;

const aiProviderOptions = {
  gemini: {
    label: "Google Gemini",
    models: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.5-pro"],
  },
  deepseek: {
    label: "DeepSeek",
    models: ["deepseek-chat", "deepseek-v4-flash", "deepseek-v4-pro"],
  },
};

const labels = {
  channel: "Canal",
  campaign: "Campanha",
  conversationStart: "Início da conversa",
  conclusion: "Conclusão",
  scheduled: "Agendou visita",
  visited: "Visitou a loja",
  bought: "Comprou",
};

const optionGroups = Object.keys(labels);
const fixedOptionGroups = new Set(["scheduled", "visited", "bought"]);
const fixedChannelOptions = new Set(["Instagram", "Facebook"]);
const nativeYesNoOptions = ["Sim", "Não"];
const defaultOptions = {
  channel: ["WhatsApp", "Instagram", "Facebook", "Ligação"],
  campaign: ["Orgânico", "Anúncio", "Indicação"],
  conversationStart: ["Preço", "Consulta", "Armação", "Lente"],
  conclusion: ["Aguardando", "Retornar", "Finalizado"],
  scheduled: nativeYesNoOptions,
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
let aiChats = [];
let activeAiChatId = null;
let aiMessages = [];
let aiIsSending = false;
let aiAbortController = null;
let currentAiResponseMessage = null;
let editingAiMessageIndex = null;
let appointmentModalMode = "lead-form";
let appointmentMonitorLeadId = null;
const expandedAnalyticsSections = new Set();
let analyticsChartsVisible = false;
let analyticsChartType = "line";
let analyticsChartSectionId = "campaign";
let analyticsChartValue = "";
let analyticsComparePrevious = false;
const analyticsPiePalette = [
  "#00d084",
  "#2f8cff",
  "#ff9f0a",
  "#ff3b6b",
  "#8b5cf6",
  "#12d6d6",
  "#ff6b35",
  "#a3e635",
  "#facc15",
  "#38bdf8",
];

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
const analyticsScheduledFilter = $("#analyticsScheduledFilter");
const analyticsBoughtFilter = $("#analyticsBoughtFilter");
const analyticsSingleDate = $("#analyticsSingleDate");
const analyticsStartDate = $("#analyticsStartDate");
const analyticsEndDate = $("#analyticsEndDate");
const analyticsSingleDateField = $(".analytics-single-date");
const analyticsRangeDateFields = $$(".analytics-range-date");
const analyticsQuickRangeField = $(".quick-range-field");
const analyticsCustomFilters = $("#analyticsCustomFilters");
const analyticsCustomSections = $("#analyticsCustomSections");
const analyticsActions = $(".analytics-ai-row");
const analyticsKpis = $("#analyticsKpis");
const analyticsBoard = $("#analyticsBoard");
const analyticsChartsPanel = $("#analyticsChartsPanel");
const analyticsDateModeButtons = $$("[data-analytics-date-mode]");
const analyticsQuickRangeButtons = $$("[data-analytics-range]");
const exportLeadsButton = $("#exportLeadsButton");
const aiInsightsButton = $("#aiInsightsButton");
const analyticsChartsButton = $("#analyticsChartsButton");
const aiChatModal = $("#aiChatModal");
const aiChatClose = $("#aiChatClose");
const aiNewChatButton = $("#aiNewChatButton");
const aiHistoryToggle = $("#aiHistoryToggle");
const aiHistoryPanel = $("#aiHistoryPanel");
const aiHistoryNewChat = $("#aiHistoryNewChat");
const aiChatHistoryList = $("#aiChatHistoryList");
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
const aiValidateKeyButton = $("#aiValidateKeyButton");
const aiKeyStatus = $("#aiKeyStatus");
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
const contactDateInput = $("#contactDate");
const searchInput = $("#search");
const appointmentMonitorToggle = $("#appointmentMonitorToggle");
const appointmentMonitorBadge = $("#appointmentMonitorBadge");
const appointmentMonitorPanel = $("#appointmentMonitorPanel");
const appointmentMonitorEmpty = $("#appointmentMonitorEmpty");
const appointmentMonitorList = $("#appointmentMonitorList");
const appointmentMonitorMessage = $("#appointmentMonitorMessage");
const filtersPanel = $("#filtersPanel");
const toggleFiltersButton = $("#toggleFilters");
const channelFilter = $("#channelFilter");
const campaignFilter = $("#campaignFilter");
const conversationStartFilter = $("#conversationStartFilter");
const conclusionFilter = $("#conclusionFilter");
const visitedFilter = $("#visitedFilter");
const scheduledFilter = $("#scheduledFilter");
const boughtFilter = $("#boughtFilter");
const startDateFilter = $("#startDateFilter");
const endDateFilter = $("#endDateFilter");
const clearFiltersButton = $("#clearFilters");
const emptyState = $("#emptyState");
const leadList = $("#leadList");
const customLeadFields = $("#customLeadFields");
const customLeadFilters = $("#customLeadFilters");
const appointmentDetails = $("#appointmentDetails");
const appointmentSummary = $("#appointmentSummary");
const appointmentEdit = $("#appointmentEdit");
const appointmentModal = $("#appointmentModal");
const appointmentClose = $("#appointmentClose");
const appointmentCancel = $("#appointmentCancel");
const appointmentForm = $("#appointmentForm");
const appointmentTitle = $("#appointmentTitle");
const appointmentDateInput = $("#appointmentDate");
const appointmentTimeInput = $("#appointmentTime");
const appointmentMessage = $("#appointmentMessage");
const appointmentSubmit = $("#appointmentSubmit");
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
  { id: "campaign", label: "Campanhas", key: "campaign", optionGroup: "campaign", container: "#analyticsCampaignCards", summary: "#analyticsCampaignSummary" },
  { id: "store", label: "Lojas", key: "storeName", container: "#analyticsStoreCards", summary: "#analyticsStoreSummary" },
  { id: "channel", label: "Canais", key: "channel", optionGroup: "channel", container: "#analyticsChannelCards", summary: "#analyticsChannelSummary" },
  { id: "start", label: "Início da conversa", key: "conversationStart", optionGroup: "conversationStart", container: "#analyticsStartCards", summary: "#analyticsStartSummary" },
  { id: "conclusion", label: "Resultado", key: "conclusion", optionGroup: "conclusion", container: "#analyticsConclusionCards", summary: "#analyticsConclusionSummary" },
  { id: "visited", label: "Visitas", key: "visited", optionGroup: "visited", container: "#analyticsVisitedCards", summary: "#analyticsVisitedSummary" },
  { id: "scheduled", label: "Agendamentos", key: "scheduled", optionGroup: "scheduled", container: "#analyticsScheduledCards", summary: "#analyticsScheduledSummary" },
  { id: "bought", label: "Compras", key: "bought", optionGroup: "bought", container: "#analyticsBoughtCards", summary: "#analyticsBoughtSummary" },
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
  appointmentEdit.addEventListener("click", openAppointmentModal);
  appointmentClose.addEventListener("click", () => closeAppointmentModal());
  appointmentCancel.addEventListener("click", () => closeAppointmentModal());
  appointmentModal.addEventListener("click", (event) => {
    if (event.target === appointmentModal) closeAppointmentModal();
  });
  appointmentForm.addEventListener("submit", handleAppointmentSubmit);
  [appointmentDateInput, appointmentTimeInput].forEach((element) => {
    element.addEventListener("input", () => {
      clearAppointmentMessage();
      updateAppointmentDetailsVisibility();
    });
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
  appointmentMonitorToggle.addEventListener("click", toggleAppointmentMonitorPanel);
  appointmentMonitorList.addEventListener("click", handleAppointmentMonitorClick);
  analyticsToggle.addEventListener("click", toggleAnalytics);
  analyticsToggleLabel.addEventListener("click", toggleAnalytics);
  exportLeadsButton.addEventListener("click", exportLeadsToExcel);
  aiInsightsButton.addEventListener("click", openAiChat);
  analyticsChartsButton.addEventListener("click", toggleAnalyticsChartsMode);
  analyticsChartsPanel.addEventListener("input", handleAnalyticsChartInput);
  analyticsChartsPanel.addEventListener("click", handleAnalyticsChartClick);
  aiChatClose.addEventListener("click", closeAiChat);
  aiNewChatButton.addEventListener("click", handleAiNewChat);
  aiHistoryToggle.addEventListener("click", toggleAiHistoryPanel);
  aiHistoryNewChat.addEventListener("click", handleAiNewChat);
  aiChatHistoryList.addEventListener("click", handleAiHistoryClick);
  aiChatModal.addEventListener("click", (event) => {
    if (event.target === aiChatModal) closeAiChat();
  });
  aiSettingsToggle.addEventListener("click", toggleAiSettingsPanel);
  aiProvider.addEventListener("input", handleAiProviderChange);
  aiModel.addEventListener("input", clearAiKeyStatus);
  aiApiKey.addEventListener("input", clearAiKeyStatus);
  aiValidateKeyButton.addEventListener("click", handleAiValidateKey);
  aiSettingsForm.addEventListener("submit", handleAiSettingsSubmit);
  aiChatMessages.addEventListener("click", handleAiMessageClick);
  aiChatForm.addEventListener("submit", handleAiChatSubmit);
  aiChatInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      aiChatForm.requestSubmit();
    }
  });
  aiChatInput.addEventListener("input", autoResizeAiInput);
  [
    analyticsStoreFilter,
    analyticsChannelFilter,
    analyticsCampaignFilter,
    analyticsConclusionFilter,
    analyticsVisitedFilter,
    analyticsScheduledFilter,
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
    scheduledFilter,
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
  loadAiChatSessions();

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
  appointmentMonitorToggle.hidden = true;
  appointmentMonitorPanel.hidden = true;
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
  appointmentMonitorToggle.hidden = false;
  toggleOptionsEditButton.hidden = false;
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
    aiChats = [];
    activeAiChatId = null;
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
  appointmentMonitorToggle.hidden = false;
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
    p_contact_date: contactDateInput.value || null,
    p_channel: selectedValues.channel,
    p_campaign: selectedValues.campaign,
    p_conversation_start: selectedValues.conversationStart,
    p_conclusion: selectedValues.conclusion,
    p_scheduled: selectedValues.scheduled,
    p_scheduled_visit_date: selectedValues.scheduled === "Sim" ? appointmentDateInput.value : null,
    p_scheduled_visit_time: selectedValues.scheduled === "Sim" ? appointmentTimeInput.value || null : null,
    p_visited: selectedValues.visited,
    p_bought: selectedValues.bought,
    p_purchase_amount: selectedValues.bought === "Sim" ? parseCurrencyInput(purchaseAmountInput.value) : null,
    p_service_order: selectedValues.bought === "Sim" ? serviceOrderInput.value.trim() : null,
    p_notes: leadNotesInput.value.trim(),
    p_custom_values: buildCustomValuesPayload(),
    p_store_id: store.id,
  };

  if (!payload.p_name || !payload.p_phone) {
    showFormMessage("Preencha nome e telefone.");
    return;
  }

  if (!payload.p_scheduled) {
    showFormMessage("Informe se o lead agendou visita ou não.");
    return;
  }

  if (payload.p_scheduled === "Sim" && !payload.p_scheduled_visit_date) {
    showFormMessage("Informe a data da visita agendada.");
    openAppointmentModal();
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
  contactDateInput.value = lead.contactDate || "";
  selectedValues = {
    channel: lead.channel || "",
    campaign: lead.campaign || "",
    conversationStart: lead.conversationStart || "",
    conclusion: lead.conclusion || "",
    scheduled: lead.scheduled || "",
    visited: lead.visited || "",
    bought: lead.bought || "",
  };
  selectedCustomValues = { ...lead.customValues };
  appointmentDateInput.value = lead.scheduledVisitDate || "";
  appointmentTimeInput.value = lead.scheduledVisitTime || "";
  purchaseAmountInput.value = lead.purchaseAmount ? formatCurrencyInput(lead.purchaseAmount) : "";
  serviceOrderInput.value = lead.serviceOrder || "";
  leadNotesInput.value = lead.notes || "";
  formTitle.textContent = "Editar lead";
  submitButton.textContent = "Atualizar lead";
  cancelEditButton.hidden = false;
  updateAppointmentDetailsVisibility();
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
    if (!analyticsInspectorModal.hidden) {
      closeAnalyticsInspector();
    }
    if (!leadDetailsModal.hidden) {
      closeLeadDetailsModal();
    }
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
  document.body.appendChild(confirmModal);
  confirmModal.hidden = false;
  syncModalLock();
}

function closeConfirmModal() {
  pendingConfirmAction = null;
  confirmModal.hidden = true;
  syncModalLock();
}

async function runConfirmedAction() {
  const action = pendingConfirmAction;
  closeConfirmModal();
  if (action) await action();
}

function openAppointmentModal() {
  appointmentModalMode = "lead-form";
  appointmentMonitorLeadId = null;
  appointmentTitle.textContent = "Data da visita";
  appointmentSubmit.textContent = "Salvar data";
  selectedValues.scheduled = "Sim";
  clearAppointmentMessage();
  appointmentModal.hidden = false;
  renderChoiceButtons();
  updateAppointmentDetailsVisibility();
  syncModalLock();
  requestAnimationFrame(() => appointmentDateInput.focus());
}

function closeAppointmentModal() {
  const wasMonitorMode = appointmentModalMode === "monitor";
  appointmentModal.hidden = true;
  clearAppointmentMessage();
  if (appointmentModalMode === "lead-form" && selectedValues.scheduled === "Sim" && !appointmentDateInput.value) {
    selectedValues.scheduled = "";
    renderChoiceButtons();
  }
  if (wasMonitorMode) {
    appointmentDateInput.value = "";
    appointmentTimeInput.value = "";
  }
  appointmentModalMode = "lead-form";
  appointmentMonitorLeadId = null;
  appointmentTitle.textContent = "Data da visita";
  appointmentSubmit.textContent = "Salvar data";
  updateAppointmentDetailsVisibility();
  syncModalLock();
}

function openAppointmentMonitorModal(lead) {
  appointmentModalMode = "monitor";
  appointmentMonitorLeadId = lead.id;
  appointmentTitle.textContent = "Reagendar visita";
  appointmentSubmit.textContent = "Reagendar";
  appointmentDateInput.value = "";
  appointmentTimeInput.value = "";
  clearAppointmentMessage();
  appointmentModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => appointmentDateInput.focus());
}

async function handleAppointmentSubmit(event) {
  event.preventDefault();

  if (!appointmentDateInput.value) {
    showAppointmentMessage("Informe a data da visita.");
    appointmentDateInput.focus();
    return;
  }

  if (appointmentModalMode === "monitor") {
    await rescheduleAppointmentMonitorLead();
    return;
  }

  selectedValues.scheduled = "Sim";
  appointmentModal.hidden = true;
  clearAppointmentMessage();
  renderChoiceButtons();
  updateAppointmentDetailsVisibility();
  syncModalLock();
}

async function rescheduleAppointmentMonitorLead() {
  const lead = leads.find((item) => item.id === appointmentMonitorLeadId);
  if (!lead) return;

  try {
    setFormBusy(appointmentForm, true);
    await authenticatedRpc("lc_upsert_lead", buildLeadUpsertPayload(lead, {
      p_scheduled: "Sim",
      p_scheduled_visit_date: appointmentDateInput.value,
      p_scheduled_visit_time: appointmentTimeInput.value || null,
      p_visited: "Não",
    }));
    appointmentModal.hidden = true;
    appointmentModalMode = "lead-form";
    appointmentMonitorLeadId = null;
    appointmentDateInput.value = "";
    appointmentTimeInput.value = "";
    clearAppointmentMessage();
    await refreshRemoteState();
    renderAll();
    showAppointmentMonitorMessage("Visita reagendada.", "success");
    showAppNotification("Visita reagendada.");
    syncModalLock();
  } catch (error) {
    showAppointmentMessage(readableError(error));
  } finally {
    setFormBusy(appointmentForm, false);
  }
}

function showAppointmentMessage(message) {
  appointmentMessage.textContent = message;
}

function clearAppointmentMessage() {
  appointmentMessage.textContent = "";
}

function resetLeadForm() {
  form.reset();
  editingIdInput.value = "";
  selectedValues = createEmptySelection();
  selectedCustomValues = {};
  appointmentDateInput.value = "";
  appointmentTimeInput.value = "";
  contactDateInput.value = "";
  purchaseAmountInput.value = "";
  serviceOrderInput.value = "";
  leadNotesInput.value = "";
  formTitle.textContent = "Cadastrar lead";
  submitButton.textContent = "Salvar lead";
  cancelEditButton.hidden = true;
  if (!storeOptionsPanel.hidden) toggleStoreOptionsMode(false);
  closeAppointmentModal();
  updatePurchaseDetailsVisibility();
  updateAppointmentDetailsVisibility();
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
  renderAppointmentMonitor();
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
  $("#adminScheduledCount").textContent = countByValue(leads, "scheduled", "Sim");
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
            ${renderTag(formatLeadContactDate(lead) ? `Contato: ${formatLeadContactDate(lead)}` : "")}
            ${renderTag(lead.campaign)}
            ${renderTag(lead.conclusion)}
            ${renderTag(lead.scheduled ? `Agendou: ${lead.scheduled}` : "")}
            ${renderTag(getScheduledVisitLabel(lead) ? `Visita: ${getScheduledVisitLabel(lead)}` : "")}
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
  $("#storeScheduled").textContent = countByValue(storeLeads, "scheduled", "Sim");
  $("#salesCount").textContent = countByValue(storeLeads, "bought", "Sim");
  $("#conversionRate").textContent = formatPercent(countByValue(storeLeads, "bought", "Sim"), storeLeads.length);
}

function renderAppointmentMonitor() {
  if (!appointmentMonitorToggle || storeView.hidden) return;

  const dueLeads = getDueAppointmentLeads();
  const count = dueLeads.length;
  appointmentMonitorBadge.textContent = count;
  appointmentMonitorBadge.hidden = count === 0;
  appointmentMonitorToggle.classList.toggle("has-notifications", count > 0);
  appointmentMonitorToggle.setAttribute("aria-expanded", String(!appointmentMonitorPanel.hidden));
  appointmentMonitorEmpty.hidden = count > 0;
  appointmentMonitorList.innerHTML = dueLeads.map(renderAppointmentMonitorCard).join("");

  if (count === 0 && !appointmentMonitorPanel.hidden) {
    appointmentMonitorPanel.hidden = true;
    appointmentMonitorToggle.setAttribute("aria-expanded", "false");
  }
}

function renderAppointmentMonitorCard(lead) {
  const scheduledLabel = getScheduledVisitLabel(lead) || formatDateInputValue(lead.scheduledVisitDate);
  return `
    <article class="appointment-monitor-card">
      <div class="appointment-monitor-main">
        <strong>${escapeHtml(lead.name)}</strong>
        <span>${escapeHtml(lead.phone || "Telefone não informado")}</span>
        <small>Agendado para ${escapeHtml(scheduledLabel || "-")}</small>
      </div>
      <div class="appointment-monitor-actions">
        <a class="mini-button whatsapp-button" href="${formatWhatsAppUrl(lead.phone)}" target="_blank" rel="noopener noreferrer">
          <i class="fa-brands fa-whatsapp" aria-hidden="true"></i>
          WhatsApp
        </a>
        <button class="mini-button choice-yes" type="button" data-appointment-monitor-action="visited" data-lead-id="${lead.id}">
          Veio
        </button>
        <button class="mini-button" type="button" data-appointment-monitor-action="reschedule" data-lead-id="${lead.id}">
          Não veio / reagendar
        </button>
        <button class="mini-button view-button" type="button" data-appointment-monitor-action="edit" data-lead-id="${lead.id}">
          Editar
        </button>
      </div>
    </article>
  `;
}

function getDueAppointmentLeads() {
  const today = toLocalDateInput(new Date());
  return getVisibleStoreLeads()
    .filter((lead) =>
      lead.scheduled === "Sim" &&
      lead.scheduledVisitDate &&
      lead.scheduledVisitDate < today &&
      lead.visited !== "Sim"
    )
    .sort((a, b) => {
      if (a.scheduledVisitDate !== b.scheduledVisitDate) {
        return String(a.scheduledVisitDate).localeCompare(String(b.scheduledVisitDate));
      }
      return String(a.name).localeCompare(String(b.name), "pt-BR");
    });
}

function toggleAppointmentMonitorPanel() {
  appointmentMonitorPanel.hidden = !appointmentMonitorPanel.hidden;
  appointmentMonitorToggle.setAttribute("aria-expanded", String(!appointmentMonitorPanel.hidden));
  clearAppointmentMonitorMessage();
}

async function handleAppointmentMonitorClick(event) {
  const button = event.target.closest("[data-appointment-monitor-action]");
  if (!button) return;

  const lead = leads.find((item) => item.id === button.dataset.leadId);
  if (!lead) return;

  const action = button.dataset.appointmentMonitorAction;
  if (action === "visited") {
    await markAppointmentLeadVisited(lead, button);
  }
  if (action === "reschedule") {
    openAppointmentMonitorModal(lead);
  }
  if (action === "edit") {
    guardUnsavedOptions(() => editLead(lead.id));
  }
}

async function markAppointmentLeadVisited(lead, button) {
  try {
    button.disabled = true;
    await authenticatedRpc("lc_upsert_lead", buildLeadUpsertPayload(lead, {
      p_visited: "Sim",
      p_bought: lead.bought || "Não",
    }));
    await refreshRemoteState();
    renderAll();
    showAppointmentMonitorMessage("Visita confirmada.", "success");
    showAppNotification("Visita confirmada.");
  } catch (error) {
    showAppointmentMonitorMessage(readableError(error));
  } finally {
    button.disabled = false;
  }
}

function showAppointmentMonitorMessage(message, type = "error") {
  appointmentMonitorMessage.textContent = message;
  appointmentMonitorMessage.classList.toggle("success", type === "success");
}

function clearAppointmentMonitorMessage() {
  showAppointmentMonitorMessage("");
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
        ${renderLeadDetailItem("Data do contato", formatLeadContactDate(lead))}
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
        ${renderLeadDetailItem("Agendou visita", lead.scheduled)}
        ${renderLeadDetailItem("Data da visita agendada", getScheduledVisitLabel(lead))}
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
    !leadDetailsModal.hidden ||
      !analyticsInspectorModal.hidden ||
      !settingsModal.hidden ||
      !managedAccountModal.hidden ||
      !appointmentModal.hidden ||
      !aiChatModal.hidden,
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
            fixedOptionGroups.has(group) && selectedValues[group] && !isActive ? "is-dimmed" : "",
            getChoiceClass(group, value),
          ].filter(Boolean).join(" ");
          return `<button class="${className}" type="button" data-choice="${group}" data-value="${escapeHtml(value)}">${getChoiceLabel(group, value)}</button>`;
        })
        .join("");

      container.querySelectorAll("[data-choice]").forEach((button) => {
        button.addEventListener("click", () => {
          if (group === "scheduled") {
            selectedValues.scheduled = button.dataset.value;
            if (selectedValues.scheduled === "Sim") {
              openAppointmentModal();
            } else {
              appointmentDateInput.value = "";
              appointmentTimeInput.value = "";
              renderChoiceButtons();
              updateAppointmentDetailsVisibility();
            }
            return;
          }

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
  fillSelectWithEntries(scheduledFilter, withNoAnswer(options.scheduled), "Todos");
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
  fillSelectWithEntries(analyticsScheduledFilter, withNoAnswer(options.scheduled), "Todos");
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
          <span><i class="fa-solid fa-tags" aria-hidden="true"></i>${escapeHtml(category.name)}</span>
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
  const scheduled = countByValue(filtered, "scheduled", "Sim");
  const bought = countByValue(filtered, "bought", "Sim");

  $("#analyticsTotalLeads").textContent = total;
  $("#analyticsVisitedLeads").textContent = visited;
  $("#analyticsScheduledLeads").textContent = scheduled;
  $("#analyticsBoughtLeads").textContent = bought;
  $("#analyticsConversionRate").textContent = formatPercent(bought, total);

  analyticsSections.forEach((section) => {
    renderAnalyticsCategoryCards(section, filtered);
  });
  renderCustomAnalyticsSections(filtered);
  renderAnalyticsChartsPanel();
  syncAnalyticsViewMode();
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

  const ranking = buildAnalyticsRanking(rows, section);
  const total = rows.length;
  const activeRanking = ranking.filter((item) => item.count > 0);

  summary.innerHTML = total
    ? `<span><b>${activeRanking.length}</b> categorias</span><span><b>${total}</b> ${total === 1 ? "lead" : "leads"}</span>`
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

  container.innerHTML = `
    ${renderAnalyticsPie(section, activeRanking, total)}
  `;
}

function renderAnalyticsPie(section, ranking, total) {
  const topItem = ranking[0];
  const gradient = buildAnalyticsPieGradient(ranking, total);
  const hasData = total > 0 && ranking.length > 0;
  const topLabel = topItem
    ? `${topItem.value} lidera com ${formatPercent(topItem.count, total)}`
    : "Sem dados para comparar";

  return `
    <div class="analytics-pie-layout${hasData ? "" : " is-empty"}">
      <div class="analytics-chart-top">
        <div>
          <span>Participação por leads</span>
          <strong>${escapeHtml(topLabel)}</strong>
        </div>
      </div>
      ${hasData
        ? `
          <div class="analytics-pie-body">
            <div class="analytics-pie-visual">
              <div class="analytics-pie-wrap">
                <div
                  class="analytics-pie"
                  style="--analytics-pie:${gradient}"
                  role="img"
                  aria-label="${escapeHtml(`Gráfico de ${section.label} com ${total} ${total === 1 ? "lead" : "leads"}`)}"
                ></div>
              </div>
            </div>
            <div class="analytics-pie-legend">
              ${ranking.map((item, index) => renderAnalyticsLegendRow(section, item, index, total)).join("")}
            </div>
          </div>
        `
        : `
          <div class="analytics-pie-empty">
            <strong>Sem registros</strong>
            <span>Ajuste os filtros acima para carregar o gráfico.</span>
          </div>
        `}
    </div>
  `;
}

function renderAnalyticsLegendRow(section, item, index, total) {
  const color = getAnalyticsPieColor(index);
  const textColor = getAnalyticsPieTextColor(color);
  return `
    <div class="analytics-legend-row">
      <b
        class="analytics-legend-count"
        style="--legend-color:${color}; --legend-ink:${textColor}"
        aria-label="${item.count} ${item.count === 1 ? "lead" : "leads"}"
      >${item.count}</b>
      <div>
        <strong>${escapeHtml(item.value)}</strong>
        <span>${formatPercent(item.count, total)} dos leads</span>
      </div>
      <button
        class="analytics-legend-list-button"
        type="button"
        data-analytics-inspect
        data-analytics-section="${escapeHtml(section.id)}"
        data-analytics-value="${escapeHtml(item.value)}"
        aria-label="${escapeHtml(`Listar leads de ${item.value}`)}"
        title="Listar"
      >
        <i class="fa-solid fa-list-ul" aria-hidden="true"></i>
      </button>
    </div>
  `;
}

function renderAnalyticsRankingPanel(section, ranking) {
  const isExpanded = expandedAnalyticsSections.has(section.id);
  const visibleLimit = 4;
  const visibleRanking = isExpanded ? ranking : ranking.slice(0, visibleLimit);
  const hasHiddenItems = ranking.length > visibleLimit;

  return `
    <div class="analytics-ranking-panel">
      <div class="analytics-ranking-heading">
        <span>Ranking detalhado</span>
        <strong>${ranking.length} ${ranking.length === 1 ? "item" : "itens"}</strong>
      </div>
      ${visibleRanking.map((item) => renderAnalyticsRankingCard(section, item)).join("")}
      ${hasHiddenItems
        ? `
          <button
            class="analytics-expand-button"
            type="button"
            data-analytics-expand-section="${escapeHtml(section.id)}"
          >
            <i class="fa-solid ${isExpanded ? "fa-chevron-up" : "fa-chevron-down"}" aria-hidden="true"></i>
            ${isExpanded ? "Recolher ranking" : `Ver todos (${ranking.length})`}
          </button>
        `
        : ""}
    </div>
  `;
}

function renderAnalyticsRankingCard(section, item) {
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
        <span>${item.scheduled} agend.</span>
        <span>${item.bought} compras</span>
      </div>
      <button
        class="mini-button analytics-inspect-button"
        type="button"
        data-analytics-inspect
        data-analytics-section="${escapeHtml(section.id)}"
        data-analytics-value="${escapeHtml(item.value)}"
      >
        Listar
      </button>
    </article>
  `;
}

function buildAnalyticsPieGradient(ranking, total) {
  if (!ranking.length || total <= 0) {
    return "conic-gradient(from -90deg, #d7d7d7 0% 100%)";
  }

  let cursor = 0;
  const stops = ranking.map((item, index) => {
    const start = cursor;
    const end = index === ranking.length - 1
      ? 100
      : cursor + (item.count / total) * 100;
    cursor = end;
    return `${getAnalyticsPieColor(index)} ${formatCssPercent(start)}% ${formatCssPercent(end)}%`;
  });

  return `conic-gradient(from -90deg, ${stops.join(", ")})`;
}

function getAnalyticsPieColor(index) {
  return analyticsPiePalette[index % analyticsPiePalette.length];
}

function getAnalyticsPieTextColor(color) {
  const hex = String(color || "").replace("#", "");
  if (hex.length !== 6) return "#ffffff";
  const red = parseInt(hex.slice(0, 2), 16);
  const green = parseInt(hex.slice(2, 4), 16);
  const blue = parseInt(hex.slice(4, 6), 16);
  const brightness = (red * 299 + green * 587 + blue * 114) / 1000;
  return brightness > 150 ? "#111111" : "#ffffff";
}

function formatCssPercent(value) {
  return Math.max(0, Math.min(100, value)).toFixed(3).replace(/\.?0+$/, "");
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
      customCategoryId: category.id,
      container: `[data-custom-analytics-list="${category.id}"]`,
      summary: `[data-custom-analytics-summary="${category.id}"]`,
    }, rows);
  });
}

function renderAnalyticsChartsPanel() {
  if (!analyticsChartsPanel) return;

  const sections = getAnalyticsChartSections();
  if (!sections.length) {
    analyticsChartsPanel.innerHTML = "";
    return;
  }

  if (!sections.some((section) => section.id === analyticsChartSectionId)) {
    analyticsChartSectionId = sections[0].id;
    analyticsChartValue = "";
  }

  const section = sections.find((item) => item.id === analyticsChartSectionId) || sections[0];
  const baseRows = getAnalyticsBaseLeads();
  const currentRange = getAnalyticsSelectedDateRange(baseRows);
  const previousRange = getPreviousDateRange(currentRange);
  const currentRows = filterLeadsByDateRange(baseRows, currentRange.start, currentRange.end);
  const previousRows = analyticsComparePrevious
    ? filterLeadsByDateRange(baseRows, previousRange.start, previousRange.end)
    : [];
  const values = getAnalyticsChartValues(section, currentRows, previousRows);

  if (analyticsChartType !== "line" && analyticsChartType !== "bar") analyticsChartType = "line";
  if (analyticsChartType === "bar" && analyticsChartValue && !values.some((item) => item.value === analyticsChartValue)) {
    analyticsChartValue = "";
  }

  const chartHtml = analyticsChartType === "line"
    ? renderAnalyticsLineChart(section, values, currentRows, previousRows, currentRange, previousRange)
    : renderAnalyticsBarChart(section, analyticsChartValue, currentRows, previousRows, currentRange, previousRange);

  analyticsChartsPanel.innerHTML = `
    <div class="analytics-chart-studio">
      <div class="analytics-chart-studio-heading">
        <div>
          <span>Laboratório de gráficos</span>
          <strong>${escapeHtml(section.label)}</strong>
        </div>
        <div class="analytics-chart-periods">
          <span><i class="fa-solid fa-calendar-days" aria-hidden="true"></i>${escapeHtml(formatChartRangeLabel(currentRange))}</span>
          ${analyticsComparePrevious ? `<span class="is-compare"><i class="fa-solid fa-clock-rotate-left" aria-hidden="true"></i>${escapeHtml(formatChartRangeLabel(previousRange))}</span>` : ""}
        </div>
      </div>

      <div class="analytics-chart-controls">
        <label class="field">
          <span><i class="fa-solid fa-layer-group" aria-hidden="true"></i>Categoria</span>
          <select data-analytics-chart-section>
            ${sections.map((item) => `<option value="${escapeHtml(item.id)}" ${item.id === section.id ? "selected" : ""}>${escapeHtml(item.label)}</option>`).join("")}
          </select>
        </label>

        <div class="field analytics-chart-type-field">
          <span><i class="fa-solid fa-chart-line" aria-hidden="true"></i>Modelo</span>
          <div class="segmented-control analytics-chart-type-toggle" role="group" aria-label="Modelo do gráfico">
            <button class="segment-button${analyticsChartType === "line" ? " is-active" : ""}" type="button" data-analytics-chart-type="line">
              Linhas
            </button>
            <button class="segment-button${analyticsChartType === "bar" ? " is-active" : ""}" type="button" data-analytics-chart-type="bar">
              Barras
            </button>
          </div>
        </div>

        <label class="field analytics-chart-value-field" ${analyticsChartType === "line" ? "hidden" : ""}>
          <span><i class="fa-solid fa-tag" aria-hidden="true"></i>Subcategoria</span>
          <select data-analytics-chart-value ${values.length ? "" : "disabled"}>
            ${values.length
              ? `<option value="">Escolha uma subcategoria</option>` + values.map((item) => `<option value="${escapeHtml(item.value)}" ${item.value === analyticsChartValue ? "selected" : ""}>${escapeHtml(item.value)}</option>`).join("")
              : '<option value="">Sem dados</option>'}
          </select>
        </label>

        <button
          class="analytics-compare-button${analyticsComparePrevious ? " is-active" : ""}"
          type="button"
          data-analytics-chart-compare
          aria-pressed="${analyticsComparePrevious}"
        >
          <i class="fa-solid fa-code-compare" aria-hidden="true"></i>
          <span>Comparar período anterior</span>
        </button>
      </div>

      ${chartHtml}
    </div>
  `;
}

function renderAnalyticsBarChart(section, value, currentRows, previousRows, currentRange, previousRange) {
  const buckets = buildAnalyticsDateBuckets(currentRange);
  const color = getAnalyticsPieColor(getAnalyticsChartValueIndex(section, value));
  const currentCounts = buckets.map((bucket) => countAnalyticsBucket(currentRows, section, value, bucket.start, bucket.end));
  const previousCounts = analyticsComparePrevious
    ? buckets.map((bucket) => {
        const shifted = shiftBucketToRange(bucket, currentRange, previousRange);
        return countAnalyticsBucket(previousRows, section, value, shifted.start, shifted.end);
      })
    : [];
  const max = Math.max(...currentCounts, ...previousCounts, 1);
  const total = currentCounts.reduce((sum, count) => sum + count, 0);
  const previousTotal = previousCounts.reduce((sum, count) => sum + count, 0);

  if (!value) {
    return `
      <div class="analytics-chart-empty">
        <strong>Escolha uma subcategoria</strong>
        <span>No gráfico de barras, selecione exatamente uma subcategoria para analisar por período.</span>
      </div>
    `;
  }

  return `
    <div class="analytics-chart-card">
      <div class="analytics-chart-card-heading">
        <div>
          <span>Barras por período</span>
          <strong>${escapeHtml(value)}</strong>
        </div>
        <div class="analytics-chart-legend">
          <span><i style="--legend-color:${color}" aria-hidden="true"></i>${total} ${total === 1 ? "lead" : "leads"}</span>
          ${analyticsComparePrevious ? `<span><i class="is-previous" aria-hidden="true"></i>${previousTotal} anterior</span>` : ""}
        </div>
      </div>

      <div class="analytics-bar-chart" style="--bar-color:${color}">
        ${buckets.map((bucket, index) => {
          const current = currentCounts[index] || 0;
          const previous = previousCounts[index] || 0;
          return `
            <div class="analytics-bar-group">
              <div class="analytics-bar-stack${analyticsComparePrevious ? " has-compare" : ""}">
                ${analyticsComparePrevious ? `<i class="analytics-bar is-previous" style="height:${Math.max((previous / max) * 100, previous ? 5 : 0)}%" title="Anterior: ${previous}"></i>` : ""}
                <i class="analytics-bar is-current" style="height:${Math.max((current / max) * 100, current ? 5 : 0)}%" title="Atual: ${current}"></i>
              </div>
              <strong>${current}</strong>
              <span>${escapeHtml(bucket.label)}</span>
            </div>
          `;
        }).join("")}
      </div>
    </div>
  `;
}

function renderAnalyticsLineChart(section, values, currentRows, previousRows, currentRange, previousRange) {
  const buckets = buildAnalyticsDateBuckets(currentRange);
  const visibleValues = values.map((item) => item.value);
  const series = visibleValues.map((value, index) => ({
    value,
    color: getAnalyticsPieColor(index),
    counts: buckets.map((bucket) => countAnalyticsBucket(currentRows, section, value, bucket.start, bucket.end)),
    previousCounts: analyticsComparePrevious
      ? buckets.map((bucket) => {
          const shifted = shiftBucketToRange(bucket, currentRange, previousRange);
          return countAnalyticsBucket(previousRows, section, value, shifted.start, shifted.end);
        })
      : [],
  }));
  const max = Math.max(...series.flatMap((item) => [...item.counts, ...item.previousCounts]), 1);

  if (!series.length) {
    return `
      <div class="analytics-chart-empty">
        <strong>Sem dados para linhas</strong>
        <span>Ajuste filtros ou período para comparar as subcategorias.</span>
      </div>
    `;
  }

  const left = 42;
  const right = 810;
  const top = 26;
  const bottom = 238;
  const width = right - left;
  const height = bottom - top;
  const tickEvery = Math.max(1, Math.ceil(buckets.length / 6));
  const yTicks = [0, 0.25, 0.5, 0.75, 1].map((ratio) => {
    const value = Math.round(max * ratio);
    const y = bottom - ratio * height;
    return { value, y };
  });

  return `
    <div class="analytics-chart-card">
      <div class="analytics-chart-card-heading">
        <div>
          <span>Linhas no mesmo gráfico</span>
          <strong>${series.length} ${series.length === 1 ? "subcategoria" : "subcategorias"}</strong>
        </div>
        <div class="analytics-chart-legend">
          <span><i aria-hidden="true"></i>Atual</span>
          ${analyticsComparePrevious ? '<span><i class="is-previous" aria-hidden="true"></i>Anterior tracejado</span>' : ""}
        </div>
      </div>

      <div class="analytics-line-chart-wrap">
        <svg class="analytics-line-chart" viewBox="0 0 850 280" role="img" aria-label="${escapeHtml(`Gráfico de linhas de ${section.label}`)}">
          ${yTicks.map((tick) => `
            <line x1="${left}" y1="${tick.y}" x2="${right}" y2="${tick.y}" class="analytics-chart-grid-line"></line>
            <text x="12" y="${tick.y + 4}" class="analytics-chart-axis-label">${tick.value}</text>
          `).join("")}
          ${buckets.map((bucket, index) => {
            if (index % tickEvery !== 0 && index !== buckets.length - 1) return "";
            const x = buckets.length === 1 ? left + width / 2 : left + (index / (buckets.length - 1)) * width;
            return `<text x="${x}" y="270" class="analytics-chart-axis-label is-x">${escapeHtml(bucket.label)}</text>`;
          }).join("")}
          ${series.map((item) => {
            const points = getAnalyticsLinePoints(item.counts, max, left, width, top, height);
            const previousPoints = analyticsComparePrevious
              ? getAnalyticsLinePoints(item.previousCounts, max, left, width, top, height)
              : [];
            return `
              ${analyticsComparePrevious ? renderAnalyticsSvgPath(previousPoints, item.color, true) : ""}
              ${renderAnalyticsSvgPath(points, item.color, false)}
            `;
          }).join("")}
        </svg>
      </div>

      <div class="analytics-line-series-list">
        ${series.map((item) => `
          <span><i style="--legend-color:${item.color}" aria-hidden="true"></i>${escapeHtml(item.value)}</span>
        `).join("")}
      </div>
    </div>
  `;
}

function renderAnalyticsSvgPath(points, color, isPrevious) {
  if (!points.length) return "";
  if (points.length === 1) {
    return `<circle cx="${points[0].x}" cy="${points[0].y}" r="5" fill="${color}" class="${isPrevious ? "is-previous" : ""}"></circle>`;
  }
  const path = points.map((point, index) => `${index ? "L" : "M"} ${point.x.toFixed(2)} ${point.y.toFixed(2)}`).join(" ");
  const circles = points.map((point) => `<circle cx="${point.x.toFixed(2)}" cy="${point.y.toFixed(2)}" r="${isPrevious ? 2.6 : 3.4}" fill="${color}" class="${isPrevious ? "is-previous" : ""}"></circle>`).join("");
  return `
    <path d="${path}" style="--series-color:${color}" class="analytics-line-path${isPrevious ? " is-previous" : ""}"></path>
    ${circles}
  `;
}

function getAnalyticsLinePoints(counts, max, left, width, top, height) {
  return counts.map((count, index) => ({
    x: counts.length === 1 ? left + width / 2 : left + (index / (counts.length - 1)) * width,
    y: top + height - (count / max) * height,
  }));
}

function getAnalyticsChartSections() {
  return [
    ...analyticsSections,
    ...customCategories.map((category) => ({
      id: `custom:${category.id}`,
      label: category.name,
      key: `custom:${category.id}`,
      customCategoryId: category.id,
    })),
  ];
}

function getAnalyticsChartValues(section, currentRows, previousRows = []) {
  const rows = [...currentRows, ...previousRows];
  const groups = new Map();

  buildAnalyticsRanking(rows, section).forEach((item) => {
    if (item.count > 0) groups.set(item.value, item);
  });

  return Array.from(groups.values()).sort((a, b) => {
    const currentA = currentRows.filter((lead) => getAnalyticsGroupValue(lead, section.key) === a.value).length;
    const currentB = currentRows.filter((lead) => getAnalyticsGroupValue(lead, section.key) === b.value).length;
    if (currentB !== currentA) return currentB - currentA;
    return b.count - a.count;
  });
}

function getAnalyticsChartValueIndex(section, value) {
  const values = getAnalyticsChartValues(section, getAnalyticsLeads());
  return Math.max(values.findIndex((item) => item.value === value), 0);
}

function getAnalyticsSelectedDateRange(rows) {
  const extent = getLeadDateExtent(rows);
  const today = toLocalDateInput(new Date());
  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  let start = "";
  let end = "";

  if (mode === "single" && analyticsSingleDate.value) {
    start = analyticsSingleDate.value;
    end = analyticsSingleDate.value;
  } else if (mode === "range") {
    start = analyticsStartDate.value || extent.start;
    end = analyticsEndDate.value || extent.end;
  } else {
    start = extent.start;
    end = extent.end;
  }

  start = start || end || today;
  end = end || start || today;
  if (start > end) [start, end] = [end, start];
  return { start, end };
}

function getLeadDateExtent(rows) {
  const dates = rows
    .map((lead) => getLeadDateValue(lead))
    .filter(Boolean)
    .sort();
  return {
    start: dates[0] || "",
    end: dates[dates.length - 1] || "",
  };
}

function getPreviousDateRange(range) {
  const days = getDateDiffDays(range.start, range.end) + 1;
  const end = addDaysToDateValue(range.start, -1);
  const start = addDaysToDateValue(end, -(days - 1));
  return { start, end };
}

function filterLeadsByDateRange(rows, start, end) {
  return rows.filter((lead) => {
    const date = getLeadDateValue(lead);
    return date && date >= start && date <= end;
  });
}

function buildAnalyticsDateBuckets(range) {
  const totalDays = getDateDiffDays(range.start, range.end) + 1;
  const step = totalDays <= 45 ? 1 : totalDays <= 210 ? 7 : 30;
  const buckets = [];
  let start = range.start;

  while (start <= range.end) {
    const end = minDateValue(addDaysToDateValue(start, step - 1), range.end);
    buckets.push({
      start,
      end,
      label: formatBucketLabel(start, end, step),
    });
    start = addDaysToDateValue(end, 1);
  }

  return buckets.length ? buckets : [{ start: range.start, end: range.end, label: formatDateInputValue(range.start) }];
}

function countAnalyticsBucket(rows, section, value, start, end) {
  return rows.filter((lead) => {
    const date = getLeadDateValue(lead);
    return date && date >= start && date <= end && getAnalyticsGroupValue(lead, section.key) === value;
  }).length;
}

function shiftBucketToRange(bucket, currentRange, targetRange) {
  const startOffset = getDateDiffDays(currentRange.start, bucket.start);
  const endOffset = getDateDiffDays(currentRange.start, bucket.end);
  return {
    start: addDaysToDateValue(targetRange.start, startOffset),
    end: addDaysToDateValue(targetRange.start, endOffset),
  };
}

function formatChartRangeLabel(range) {
  return range.start === range.end
    ? formatDateInputValue(range.start)
    : `${formatDateInputValue(range.start)} a ${formatDateInputValue(range.end)}`;
}

function formatBucketLabel(start, end, step) {
  if (start === end) return formatDateInputValue(start).slice(0, 5);
  const startLabel = formatDateInputValue(start).slice(0, 5);
  const endLabel = formatDateInputValue(end).slice(0, 5);
  return step >= 30 ? `${startLabel}-${endLabel}` : `${startLabel} ${endLabel}`;
}

function parseDateValue(value) {
  const [year, month, day] = String(value).split("-").map(Number);
  return new Date(year || 1970, (month || 1) - 1, day || 1);
}

function addDaysToDateValue(value, days) {
  const date = parseDateValue(value);
  date.setDate(date.getDate() + days);
  return toLocalDateInput(date);
}

function getDateDiffDays(start, end) {
  const diff = parseDateValue(end).getTime() - parseDateValue(start).getTime();
  return Math.max(0, Math.round(diff / 86400000));
}

function minDateValue(a, b) {
  return a < b ? a : b;
}

function buildAnalyticsRanking(rows, sectionOrKey) {
  const section = typeof sectionOrKey === "string" ? { key: sectionOrKey } : sectionOrKey;
  const key = section.key;
  const groups = new Map();

  getAnalyticsKnownValues(section).forEach((value) => {
    groups.set(value, {
      value,
      count: 0,
      visited: 0,
      scheduled: 0,
      bought: 0,
      latestAt: "",
    });
  });

  rows.forEach((lead) => {
    const value = getAnalyticsGroupValue(lead, key);
    const current = groups.get(value) || {
      value,
      count: 0,
      visited: 0,
      scheduled: 0,
      bought: 0,
      latestAt: "",
    };
    current.count += 1;
    if (lead.visited === "Sim") current.visited += 1;
    if (lead.scheduled === "Sim") current.scheduled += 1;
    if (lead.bought === "Sim") current.bought += 1;
    const leadDate = getLeadSortDate(lead);
    if (!current.latestAt || leadDate > current.latestAt) current.latestAt = leadDate;
    groups.set(value, current);
  });

  return Array.from(groups.values()).sort((a, b) => {
    if (b.count !== a.count) return b.count - a.count;
    if (a.count === 0 && b.count === 0) return String(a.value).localeCompare(String(b.value), "pt-BR");
    return String(b.latestAt).localeCompare(String(a.latestAt));
  });
}

function getAnalyticsKnownValues(section) {
  if (section.id === "store") {
    return stores.map((store) => store.name).filter(Boolean);
  }

  if (section.customCategoryId) {
    const category = getCustomCategory(section.customCategoryId);
    return category?.options.map((option) => option.value).filter(Boolean) || [];
  }

  if (section.optionGroup) {
    return (optionRecords[section.optionGroup] || []).map((item) => item.value).filter(Boolean);
  }

  return [];
}

function getAnalyticsGroupValue(lead, key) {
  if (key.startsWith("custom:")) {
    const categoryId = key.slice("custom:".length);
    return lead.customValues[categoryId] || "Sem resposta";
  }
  return lead[key] || "Sem resposta";
}

function toggleAnalyticsChartsMode() {
  analyticsChartsVisible = !analyticsChartsVisible;
  if (analyticsChartsVisible) analyticsChartType = analyticsChartType || "line";
  renderAnalyticsChartsPanel();
  syncAnalyticsViewMode();
}

function syncAnalyticsViewMode() {
  if (!analyticsKpis || !analyticsBoard || !analyticsChartsPanel || !analyticsChartsButton) return;
  analyticsKpis.hidden = analyticsChartsVisible;
  analyticsBoard.hidden = analyticsChartsVisible;
  analyticsChartsPanel.hidden = !analyticsChartsVisible;
  analyticsChartsButton.classList.toggle("is-active", analyticsChartsVisible);
  analyticsChartsButton.setAttribute("aria-pressed", String(analyticsChartsVisible));
}

function handleAnalyticsChartInput(event) {
  const sectionSelect = event.target.closest("[data-analytics-chart-section]");
  if (sectionSelect) {
    analyticsChartSectionId = sectionSelect.value;
    analyticsChartValue = "";
    renderAnalyticsChartsPanel();
    return;
  }

  const valueSelect = event.target.closest("[data-analytics-chart-value]");
  if (valueSelect) {
    analyticsChartValue = valueSelect.value;
    renderAnalyticsChartsPanel();
  }
}

function handleAnalyticsChartClick(event) {
  const typeButton = event.target.closest("[data-analytics-chart-type]");
  if (typeButton) {
    analyticsChartType = typeButton.dataset.analyticsChartType;
    if (analyticsChartType === "bar") analyticsChartValue = "";
    renderAnalyticsChartsPanel();
    return;
  }

  const compareButton = event.target.closest("[data-analytics-chart-compare]");
  if (compareButton) {
    analyticsComparePrevious = !analyticsComparePrevious;
    renderAnalyticsChartsPanel();
  }
}

function handleAnalyticsClick(event) {
  const expandButton = event.target.closest("[data-analytics-expand-section]");
  if (expandButton) {
    const sectionId = expandButton.dataset.analyticsExpandSection;
    if (expandedAnalyticsSections.has(sectionId)) {
      expandedAnalyticsSections.delete(sectionId);
    } else {
      expandedAnalyticsSections.add(sectionId);
    }
    renderAdminAnalytics();
    return;
  }

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
    .sort((a, b) => getLeadSortDate(b).localeCompare(getLeadSortDate(a)));

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

  const exportRows = [...leads].sort((a, b) => getLeadSortDate(b).localeCompare(getLeadSortDate(a)));
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
  const scheduled = countByValue(exportRows, "scheduled", "Sim");
  const bought = countByValue(exportRows, "bought", "Sim");
  const totalRevenue = exportRows.reduce((sum, lead) => sum + Number(lead.purchaseAmount || 0), 0);
  const columns = buildLeadExportColumns();
  const summaryRows = [
    ["Gerado em", formatDateTime(new Date().toISOString())],
    ["Escopo", "Todos os leads carregados para este acesso"],
    ["Total de leads", exportRows.length],
    ["Agendaram visita", scheduled],
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
    { header: "Data do contato", className: "date", value: (lead) => formatLeadContactDate(lead) },
    { header: "Registrado em", className: "date", value: (lead) => formatDateTime(lead.createdAt) },
    { header: "Loja", value: (lead) => lead.storeName },
    { header: "Nome do lead", value: (lead) => lead.name },
    { header: "Telefone", value: (lead) => lead.phone },
    { header: "Canal", value: (lead) => lead.channel || "Sem resposta" },
    { header: "Campanha", value: (lead) => lead.campaign || "Sem resposta" },
    { header: "Início da conversa", value: (lead) => lead.conversationStart || "Sem resposta" },
    { header: "Conclusão", value: (lead) => lead.conclusion || "Sem resposta" },
    { header: "Agendou visita", value: (lead) => lead.scheduled || "Sem resposta" },
    { header: "Data da visita agendada", className: "date", value: (lead) => getScheduledVisitLabel(lead) || "" },
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

  ensureActiveAiChat();
  updateAiContextLabel();
  renderAiMessages();
  renderAiHistoryList();
  aiChatDialogSettingsState();
  aiChatModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => {
    autoResizeAiInput();
    aiChatInput.focus();
  });
}

function closeAiChat() {
  stopAiResponse({ silent: true });
  editingAiMessageIndex = null;
  aiChatForm.classList.remove("is-editing-message");
  aiMessages.forEach((message) => {
    message.isStreaming = false;
    message.isThinking = false;
  });
  saveActiveAiChatMessages();
  aiChatModal.hidden = true;
  aiSettingsPanel.hidden = true;
  aiHistoryPanel.hidden = true;
  aiChatDialogSettingsState();
  clearAiSettingsMessage();
  syncModalLock();
}

function toggleAiSettingsPanel() {
  aiSettingsPanel.hidden = !aiSettingsPanel.hidden;
  if (!aiSettingsPanel.hidden) {
    aiHistoryPanel.hidden = true;
  }
  aiChatDialogSettingsState();
  if (!aiSettingsPanel.hidden) {
    renderAiSettingsForm();
  }
}

function aiChatDialogSettingsState() {
  const isOpen = !aiSettingsPanel.hidden;
  const isHistoryOpen = !aiHistoryPanel.hidden;
  const dialog = aiChatModal.querySelector(".ai-chat-dialog");
  dialog?.classList.toggle("is-settings-open", isOpen);
  dialog?.classList.toggle("is-history-open", isHistoryOpen);
  dialog?.classList.toggle("is-side-open", isOpen || isHistoryOpen);
  aiSettingsToggle.setAttribute("aria-expanded", String(isOpen));
  aiHistoryToggle.setAttribute("aria-expanded", String(isHistoryOpen));
}

function toggleAiHistoryPanel() {
  aiHistoryPanel.hidden = !aiHistoryPanel.hidden;
  if (!aiHistoryPanel.hidden) {
    aiSettingsPanel.hidden = true;
    renderAiHistoryList();
  }
  aiChatDialogSettingsState();
}

function handleAiNewChat() {
  stopAiResponse({ silent: true });
  editingAiMessageIndex = null;
  aiChatForm.classList.remove("is-editing-message");
  createAiChatSession();
  aiHistoryPanel.hidden = true;
  aiSettingsPanel.hidden = true;
  aiChatDialogSettingsState();
  renderAiMessages();
  renderAiHistoryList();
  requestAnimationFrame(() => aiChatInput.focus());
}

function handleAiHistoryClick(event) {
  const deleteButton = event.target.closest("[data-ai-chat-delete]");
  if (deleteButton) {
    event.stopPropagation();
    deleteAiChatSession(deleteButton.dataset.aiChatDelete);
    return;
  }

  const button = event.target.closest("[data-ai-chat-id]");
  if (!button) return;
  stopAiResponse({ silent: true });
  editingAiMessageIndex = null;
  aiChatForm.classList.remove("is-editing-message");
  activateAiChat(button.dataset.aiChatId);
  aiHistoryPanel.hidden = true;
  aiChatDialogSettingsState();
  renderAiMessages();
  renderAiHistoryList();
  requestAnimationFrame(() => aiChatInput.focus());
}

function ensureActiveAiChat() {
  if (!activeAiChatId || !getActiveAiChat()) {
    createAiChatSession();
    return;
  }
  aiMessages = getActiveAiChat().messages;
}

function createAiChatSession() {
  const now = new Date().toISOString();
  aiChats = aiChats.filter(hasAiChatMessages);
  const chat = {
    id: createLocalAiChatId(),
    title: "Novo chat",
    createdAt: now,
    updatedAt: now,
    messages: [],
  };
  aiChats = [chat, ...aiChats].slice(0, 40);
  activeAiChatId = chat.id;
  aiMessages = chat.messages;
  return chat;
}

function activateAiChat(chatId) {
  const chat = aiChats.find((item) => item.id === chatId);
  if (!chat) return;
  activeAiChatId = chat.id;
  aiMessages = chat.messages;
  saveAiChatSessions();
}

function getActiveAiChat() {
  return aiChats.find((chat) => chat.id === activeAiChatId) || null;
}

function saveActiveAiChatMessages() {
  const chat = getActiveAiChat();
  if (!chat) return;

  chat.messages = sanitizeAiMessages(aiMessages);
  if (!chat.messages.length) {
    aiChats = aiChats.filter((item) => item.id !== chat.id);
    if (activeAiChatId === chat.id) {
      activeAiChatId = aiChats.find(hasAiChatMessages)?.id || null;
    }
    saveAiChatSessions();
    renderAiHistoryList();
    return;
  }

  chat.updatedAt = new Date().toISOString();
  chat.title = buildAiChatTitle(chat.messages);
  aiMessages = chat.messages;
  aiChats = [chat, ...aiChats.filter((item) => item.id !== chat.id)].slice(0, 40);
  saveAiChatSessions();
  renderAiHistoryList();
}

function renderAiHistoryList() {
  if (!aiChatHistoryList) return;
  const visibleChats = aiChats.filter(hasAiChatMessages);

  if (!visibleChats.length) {
    aiChatHistoryList.innerHTML = `
      <div class="ai-history-empty">
        <strong>Nenhum chat salvo.</strong>
        <span>Comece uma conversa para criar histórico.</span>
      </div>
    `;
    return;
  }

  aiChatHistoryList.innerHTML = visibleChats
    .map((chat) => {
      const totalMessages = chat.messages.filter((message) => ["user", "assistant"].includes(message.role)).length;
      return `
        <div class="ai-history-item${chat.id === activeAiChatId ? " is-active" : ""}">
          <button class="ai-history-open" type="button" data-ai-chat-id="${escapeHtml(chat.id)}">
            <span>${escapeHtml(chat.title || "Novo chat")}</span>
            <small>${formatDateTime(chat.updatedAt)} · ${totalMessages} ${totalMessages === 1 ? "mensagem" : "mensagens"}</small>
          </button>
          <button class="ai-history-delete" type="button" data-ai-chat-delete="${escapeHtml(chat.id)}" aria-label="Excluir chat" title="Excluir chat">
            <i class="fa-solid fa-trash" aria-hidden="true"></i>
          </button>
        </div>
      `;
    })
    .join("");
}

function deleteAiChatSession(chatId) {
  const wasActive = activeAiChatId === chatId;
  aiChats = aiChats.filter((chat) => chat.id !== chatId);

  if (wasActive) {
    const nextChat = aiChats.find(hasAiChatMessages) || null;
    activeAiChatId = nextChat?.id || null;
    aiMessages = nextChat?.messages || [];
    if (!nextChat) createAiChatSession();
  }

  saveAiChatSessions();
  renderAiMessages();
  renderAiHistoryList();
}

function loadAiChatSessions() {
  const ownerKey = getAiChatOwnerKey();
  const storage = readAiChatStorage();
  const saved = storage[ownerKey] || {};
  aiChats = normalizeAiChats(saved.chats);
  activeAiChatId = aiChats.some((chat) => chat.id === saved.activeId)
    ? saved.activeId
    : aiChats[0]?.id || null;
  aiMessages = getActiveAiChat()?.messages || [];
}

function saveAiChatSessions() {
  const ownerKey = getAiChatOwnerKey();
  if (!ownerKey) return;
  const storage = readAiChatStorage();
  const persistableChats = aiChats.filter(hasAiChatMessages).slice(0, 40);
  const activeId = persistableChats.some((chat) => chat.id === activeAiChatId) ? activeAiChatId : null;
  storage[ownerKey] = {
    activeId,
    chats: persistableChats.map((chat) => ({
      ...chat,
      messages: sanitizeAiMessages(chat.messages),
    })),
  };
  localStorage.setItem(AI_CHAT_STORAGE_KEY, JSON.stringify(storage));
}

function readAiChatStorage() {
  try {
    const value = JSON.parse(localStorage.getItem(AI_CHAT_STORAGE_KEY) || "{}");
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
  } catch {
    return {};
  }
}

function normalizeAiChats(chats) {
  if (!Array.isArray(chats)) return [];
  return chats
    .map((chat) => ({
      id: typeof chat.id === "string" && chat.id ? chat.id : createLocalAiChatId(),
      title: typeof chat.title === "string" && chat.title.trim() ? chat.title.trim() : "Novo chat",
      createdAt: chat.createdAt || new Date().toISOString(),
      updatedAt: chat.updatedAt || chat.createdAt || new Date().toISOString(),
      messages: sanitizeAiMessages(chat.messages),
    }))
    .sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime())
    .slice(0, 40);
}

function sanitizeAiMessages(messages) {
  if (!Array.isArray(messages)) return [];
  return messages
    .filter((message) => ["user", "assistant"].includes(message.role) && typeof message.content === "string")
    .map((message) => ({
      role: message.role,
      content: message.content,
    }))
    .filter((message) => message.content.trim());
}

function hasAiChatMessages(chat) {
  return sanitizeAiMessages(chat?.messages).length > 0;
}

function buildAiChatTitle(messages) {
  const firstUserMessage = messages.find((message) => message.role === "user")?.content.trim();
  if (!firstUserMessage) return "Novo chat";
  return firstUserMessage.length > 42 ? `${firstUserMessage.slice(0, 42)}...` : firstUserMessage;
}

function createLocalAiChatId() {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `ai-chat-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function getAiChatOwnerKey() {
  if (!currentProfile) return "guest";
  return `${currentProfile.role}:${currentProfile.id || currentProfile.username || "current"}`;
}

function handleAiProviderChange() {
  const provider = aiProvider.value;
  renderAiModelOptions(provider);
  aiModel.value = aiSettings.models[provider] || aiProviderOptions[provider]?.models[0] || "";
  aiApiKey.value = aiSettings.apiKeys[provider] || "";
  clearAiKeyStatus();
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

async function handleAiValidateKey() {
  const provider = aiProvider.value;
  const apiKey = aiApiKey.value.trim();
  if (!apiKey) {
    showAiKeyStatus("Informe uma chave para validar.", "error");
    return;
  }

  aiValidateKeyButton.disabled = true;
  showAiKeyStatus("Validando chave...", "pending");

  try {
    await validateAiApiKey(provider, apiKey);
    showAiKeyStatus("Chave válida.", "success");
  } catch (error) {
    showAiKeyStatus(readableError(error), "error");
  } finally {
    aiValidateKeyButton.disabled = false;
  }
}

async function validateAiApiKey(provider, apiKey) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);

  try {
    if (provider === "gemini") {
      const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(apiKey)}`, {
        signal: controller.signal,
      });
      await readAiValidationResponse(response);
      return;
    }

    if (provider === "deepseek") {
      const response = await fetch("https://api.deepseek.com/models", {
        signal: controller.signal,
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
      });
      await readAiValidationResponse(response);
      return;
    }

    throw new Error("Provedor inválido.");
  } catch (error) {
    if (isAbortError(error)) {
      throw new Error("Tempo de validação esgotado.");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function readAiValidationResponse(response) {
  let payload = null;
  const text = await response.text();
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = null;
  }

  if (!response.ok) {
    const message = payload?.error?.message || payload?.message || "Chave inválida ou sem permissão.";
    throw new Error(message);
  }
}

function showAiKeyStatus(message, type = "") {
  aiKeyStatus.textContent = message;
  aiKeyStatus.classList.toggle("is-success", type === "success");
  aiKeyStatus.classList.toggle("is-error", type === "error");
  aiKeyStatus.classList.toggle("is-pending", type === "pending");
}

function clearAiKeyStatus() {
  showAiKeyStatus("");
}

async function handleAiChatSubmit(event) {
  event.preventDefault();
  if (aiIsSending) {
    stopAiResponse();
    return;
  }

  const content = aiChatInput.value.trim();
  if (!content) return;

  const provider = aiSettings.provider;
  const apiKey = aiSettings.apiKeys[provider];
  if (!apiKey) {
    aiSettingsPanel.hidden = false;
    aiChatDialogSettingsState();
    renderAiSettingsForm();
    showAiSettingsMessage("Informe a chave de API.", "error");
    return;
  }

  ensureActiveAiChat();
  if (editingAiMessageIndex !== null) {
    aiMessages = aiMessages.slice(0, editingAiMessageIndex);
    editingAiMessageIndex = null;
    aiChatForm.classList.remove("is-editing-message");
  }
  aiMessages.push({ role: "user", content });
  saveActiveAiChatMessages();
  aiChatInput.value = "";
  autoResizeAiInput();
  renderAiMessages();
  setAiSending(true);
  aiAbortController = new AbortController();
  const assistantMessage = beginAiAssistantStream();
  currentAiResponseMessage = assistantMessage;
  let wasInterrupted = false;

  try {
    await requestAiAnalysis({
      onChunk: (chunk) => appendAiStreamChunk(assistantMessage, chunk),
      signal: aiAbortController.signal,
    });
  } catch (error) {
    wasInterrupted = isAbortError(error);
    if (!wasInterrupted) {
      assistantMessage.isThinking = false;
      assistantMessage.isStreaming = false;
      assistantMessage.content = readableError(error);
      renderAiMessages();
    }
  } finally {
    await finishAiAssistantStream(assistantMessage, { interrupted: wasInterrupted });
    if (currentAiResponseMessage === assistantMessage) currentAiResponseMessage = null;
    aiAbortController = null;
    setAiSending(false);
    saveActiveAiChatMessages();
    renderAiMessages();
  }
}

async function requestAiAnalysis({ onChunk, signal } = {}) {
  const provider = aiSettings.provider;
  const model = aiSettings.models[provider] || aiProviderOptions[provider]?.models[0];
  const context = buildAiLeadContext(getAnalyticsLeads());
  const systemPrompt = `${aiSettings.systemPrompt || DEFAULT_AI_SYSTEM_PROMPT}\n\nContexto atual dos leads filtrados:\n${context}`;
  const conversationMessages = aiMessages.filter((message) => !message.isThinking && !message.isStreaming);

  if (provider === "gemini") {
    return requestGeminiAnalysis({ model, systemPrompt, messages: conversationMessages, apiKey: aiSettings.apiKeys.gemini, onChunk, signal });
  }

  if (provider === "deepseek") {
    return requestDeepSeekAnalysis({ model, systemPrompt, messages: conversationMessages, apiKey: aiSettings.apiKeys.deepseek, onChunk, signal });
  }

  throw new Error("Provedor de IA inválido.");
}

async function requestGeminiAnalysis({ model, systemPrompt, messages, apiKey, onChunk, signal }) {
  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:streamGenerateContent?alt=sse&key=${encodeURIComponent(apiKey)}`,
    {
      method: "POST",
      signal,
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

  const text = await readAiStream(response, (data) => {
    const chunk = data?.candidates?.[0]?.content?.parts
      ?.map((part) => part.text || "")
      .join("") || "";
    if (chunk) onChunk?.(chunk);
    return chunk;
  });
  if (!text) throw new Error("A IA não retornou texto.");
  return text;
}

async function requestDeepSeekAnalysis({ model, systemPrompt, messages, apiKey, onChunk, signal }) {
  const response = await fetch("https://api.deepseek.com/chat/completions", {
    method: "POST",
    signal,
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
      stream: true,
      temperature: 0.35,
    }),
  });

  const text = await readAiStream(response, (data) => {
    const chunk = data?.choices?.[0]?.delta?.content || "";
    if (chunk) onChunk?.(chunk);
    return chunk;
  });
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

async function readAiStream(response, extractChunk) {
  if (!response.ok) {
    await readAiResponse(response);
  }

  if (!response.body) {
    const data = await readAiResponse(response);
    return extractChunk(data) || "";
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let fullText = "";
  let eventDataLines = [];

  const flushEvent = () => {
    if (!eventDataLines.length) return;
    const payload = eventDataLines.join("\n").trim();
    eventDataLines = [];
    if (!payload || payload === "[DONE]") return;
    try {
      const chunk = extractChunk(JSON.parse(payload)) || "";
      fullText += chunk;
    } catch {
      // Ignore malformed keep-alive chunks.
    }
  };

  const consumeLine = (line) => {
    const normalizedLine = line.endsWith("\r") ? line.slice(0, -1) : line;
    if (!normalizedLine) {
      flushEvent();
      return;
    }
    if (normalizedLine.startsWith(":")) return;
    if (normalizedLine.startsWith("data:")) {
      eventDataLines.push(normalizedLine.slice(5).trimStart());
    }
  };

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    lines.forEach(consumeLine);
  }

  buffer += decoder.decode();
  if (buffer) consumeLine(buffer);
  flushEvent();

  return fullText.trim();
}

function buildAiLeadContext(filteredLeads) {
  const total = filteredLeads.length;
  const bought = countByValue(filteredLeads, "bought", "Sim");
  const visited = countByValue(filteredLeads, "visited", "Sim");
  const scheduled = countByValue(filteredLeads, "scheduled", "Sim");

  return JSON.stringify({
    gerado_em: new Date().toISOString(),
    filtros: buildAnalyticsFilterSnapshot(),
    resumo: {
      leads: total,
      agendaram: scheduled,
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
    agendamento: getSelectedOptionText(analyticsScheduledFilter),
    compra: getSelectedOptionText(analyticsBoughtFilter),
    campo_data: "data_do_contato",
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
    data_do_contato: lead.contactDate || null,
    data_do_contato_formatada: formatLeadContactDate(lead) || null,
    canal: lead.channel || null,
    campanha: lead.campaign || null,
    inicio_da_conversa: lead.conversationStart || null,
    conclusao: lead.conclusion || null,
    agendou_visita: lead.scheduled || null,
    visita_agendada: getScheduledVisitLabel(lead) || null,
    data_visita_agendada: lead.scheduledVisitDate || null,
    hora_visita_agendada: lead.scheduledVisitTime || null,
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
        <strong>Como posso ajudar?</strong>
        <span>Use o recorte atual de métricas para pedir padrões, gargalos, ranking de oportunidades ou ações para melhorar conversão.</span>
      </div>
    `;
    return;
  }

  aiChatMessages.innerHTML = aiMessages
    .map((message, index) => `
      <div class="ai-message-row ${message.role === "assistant" ? "assistant" : "user"}">
        <article class="ai-message ${message.role === "assistant" ? "assistant" : "user"}${message.isThinking ? " is-thinking" : ""}">
          <span>${message.role === "assistant" ? "IA" : "Você"}</span>
          ${message.isThinking
            ? `<div class="ai-thinking"><strong>Pensando</strong><span><i></i><i></i><i></i></span></div>`
            : `<div class="ai-message-content">${renderAiFormattedContent(message.content)}${message.isStreaming ? '<i class="ai-typing-caret" aria-hidden="true"></i>' : ""}</div>`}
        </article>
        ${renderAiMessageActions(message, index)}
      </div>
    `)
    .join("");
  scrollAiChatToBottom();
}

function renderAiMessageActions(message, index) {
  if (message.isThinking || message.isStreaming || !message.content.trim()) return "";

  if (message.role === "assistant") {
    return `
      <div class="ai-message-actions">
              <button class="ai-copy-message" type="button" data-ai-copy-index="${index}">
                <i class="fa-solid fa-copy" aria-hidden="true"></i>
                Copiar
              </button>
            </div>
    `;
  }

  if (message.role === "user") {
    return `
      <div class="ai-message-actions">
        <button class="ai-edit-message" type="button" data-ai-edit-index="${index}">
          <i class="fa-solid fa-pen" aria-hidden="true"></i>
          Editar
        </button>
      </div>
    `;
  }

  return "";
}

async function handleAiMessageClick(event) {
  const editButton = event.target.closest("[data-ai-edit-index]");
  if (editButton) {
    startAiMessageEdit(Number(editButton.dataset.aiEditIndex));
    return;
  }

  const copyButton = event.target.closest("[data-ai-copy-index]");
  if (!copyButton) return;

  const message = aiMessages[Number(copyButton.dataset.aiCopyIndex)];
  if (!message?.content) return;

  try {
    await copyTextToClipboard(message.content);
    copyButton.classList.add("is-copied");
    copyButton.innerHTML = '<i class="fa-solid fa-check" aria-hidden="true"></i> Copiado';
    setTimeout(() => {
      copyButton.classList.remove("is-copied");
      copyButton.innerHTML = '<i class="fa-solid fa-copy" aria-hidden="true"></i> Copiar';
    }, 1500);
  } catch (error) {
    showAppNotification(readableError(error), "error");
  }
}

async function copyTextToClipboard(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  document.body.appendChild(textarea);
  textarea.select();

  const copied = document.execCommand("copy");
  textarea.remove();
  if (!copied) throw new Error("Não foi possível copiar.");
}

function startAiMessageEdit(index) {
  const message = aiMessages[index];
  if (!message || message.role !== "user" || aiIsSending) return;

  editingAiMessageIndex = index;
  aiChatInput.disabled = false;
  aiChatInput.value = message.content;
  autoResizeAiInput();
  aiChatInput.focus();
  aiChatForm.classList.add("is-editing-message");
}

function setAiSending(isSending) {
  aiIsSending = isSending;
  aiChatSend.disabled = false;
  aiChatInput.disabled = isSending;
  aiChatForm.classList.toggle("is-busy", isSending);
  aiChatSend.setAttribute("aria-label", isSending ? "Parar resposta" : "Enviar");
  aiChatSend.title = isSending ? "Parar resposta" : "Enviar";
  aiChatSend.innerHTML = isSending
    ? '<i class="fa-solid fa-stop" aria-hidden="true"></i>'
    : '<i class="fa-solid fa-paper-plane" aria-hidden="true"></i>';
}

function stopAiResponse({ silent = false } = {}) {
  if (!aiIsSending && !currentAiResponseMessage) return;

  if (aiAbortController) {
    aiAbortController.abort();
  }

  if (currentAiResponseMessage) {
    currentAiResponseMessage.isThinking = false;
    currentAiResponseMessage.isStreaming = false;
    if (silent && !currentAiResponseMessage.content) {
      aiMessages = aiMessages.filter((message) => message !== currentAiResponseMessage);
    }
    if (!currentAiResponseMessage.content && !silent) {
      currentAiResponseMessage.content = "Resposta interrompida.";
    }
    currentAiResponseMessage = null;
  }

  aiAbortController = null;
  setAiSending(false);
  renderAiMessages();
}

function scrollAiChatToBottom() {
  requestAnimationFrame(() => {
    aiChatMessages.scrollTop = aiChatMessages.scrollHeight;
  });
}

function beginAiAssistantStream() {
  const message = { role: "assistant", content: "", isThinking: true, isStreaming: true };
  aiMessages.push(message);
  renderAiMessages();
  return message;
}

function appendAiStreamChunk(message, chunk) {
  if (!message || !chunk) return;
  message.isThinking = false;
  message.isStreaming = true;
  message.content += chunk;
  renderAiMessages();
}

async function finishAiAssistantStream(message, { interrupted = false } = {}) {
  if (!message) return;
  if (!interrupted && !message.content.trim()) {
    message.content = "A IA não retornou texto.";
  }
  message.isThinking = false;
  message.isStreaming = false;
}

function autoResizeAiInput() {
  const minHeight = 62;
  const maxHeight = 132;
  aiChatInput.style.height = `${minHeight}px`;
  const nextHeight = Math.min(Math.max(aiChatInput.scrollHeight, minHeight), maxHeight);
  aiChatInput.style.height = `${nextHeight}px`;
  aiChatInput.style.overflowY = aiChatInput.scrollHeight > maxHeight ? "auto" : "hidden";
  aiChatForm.classList.toggle("is-expanded", nextHeight > minHeight + 10);
}

function renderAiFormattedContent(content) {
  const lines = String(content || "").split(/\r?\n/);
  const html = [];
  let listType = "";

  const closeList = () => {
    if (!listType) return;
    html.push(`</${listType}>`);
    listType = "";
  };

  lines.forEach((line) => {
    const trimmed = line.trim();
    if (!trimmed) {
      closeList();
      return;
    }

    const heading = trimmed.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      closeList();
      const level = Math.min(heading[1].length + 2, 4);
      html.push(`<h${level}>${formatInlineMarkdown(heading[2])}</h${level}>`);
      return;
    }

    const unordered = trimmed.match(/^[-*]\s+(.+)$/);
    if (unordered) {
      if (listType !== "ul") {
        closeList();
        html.push("<ul>");
        listType = "ul";
      }
      html.push(`<li>${formatInlineMarkdown(unordered[1])}</li>`);
      return;
    }

    const ordered = trimmed.match(/^\d+[.)]\s+(.+)$/);
    if (ordered) {
      if (listType !== "ol") {
        closeList();
        html.push("<ol>");
        listType = "ol";
      }
      html.push(`<li>${formatInlineMarkdown(ordered[1])}</li>`);
      return;
    }

    closeList();
    html.push(`<p>${formatInlineMarkdown(trimmed)}</p>`);
  });

  closeList();
  return html.join("");
}

function formatInlineMarkdown(text) {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/__([^_]+)__/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/_([^_]+)_/g, "<em>$1</em>");
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
  const savedModels = saved.models || {};
  const deepseekModel = savedModels.deepseek === "deepseek-v4-flash"
    ? "deepseek-chat"
    : savedModels.deepseek;
  const savedPrompt = typeof saved.systemPrompt === "string" ? saved.systemPrompt.trim() : "";
  return {
    provider,
    models: {
      ...defaults.models,
      ...savedModels,
      deepseek: deepseekModel || defaults.models.deepseek,
    },
    apiKeys: {
      ...defaults.apiKeys,
      ...(saved.apiKeys || {}),
    },
    systemPrompt: savedPrompt && savedPrompt !== LEGACY_AI_SYSTEM_PROMPT
      ? savedPrompt
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
  clearAiKeyStatus();
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
  const deleteButton = event.target.closest("[data-inspector-delete-lead]");
  if (deleteButton) {
    event.preventDefault();
    event.stopPropagation();
    confirmDeleteLead(deleteButton.dataset.inspectorDeleteLead);
    return;
  }

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
  const contactDate = formatLeadContactDate(lead);
  const dateTimeValue = getLeadDateValue(lead) || lead.createdAt;
  return `
    <article class="analytics-lead-item${lead.inspected ? " is-inspected" : ""}">
      <button class="analytics-lead-open" type="button" data-inspector-lead-id="${lead.id}">
        <span class="analytics-lead-avatar" aria-hidden="true">
          <i class="fa-solid fa-user"></i>
        </span>
        <span class="analytics-lead-identity">
          <strong>${escapeHtml(lead.name)}</strong>
          <span>${escapeHtml(lead.storeName || "Loja não informada")}</span>
          <time datetime="${escapeHtml(dateTimeValue)}">${escapeHtml(contactDate ? `Contato: ${contactDate}` : createdAt)}</time>
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
      <button class="mini-button danger analytics-lead-delete" type="button" data-inspector-delete-lead="${lead.id}">
        <i class="fa-solid fa-trash" aria-hidden="true"></i>
        Excluir
      </button>
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
  const search = normalizeSearchText(searchInput.value.trim());

  if (search) {
    return visible.filter((lead) => matchesLeadSearch(lead, search));
  }

  return visible.filter((lead) => {
    const matchesSimpleFilters =
      matchesFilter(lead.channel, channelFilter.value) &&
      matchesFilter(lead.campaign, campaignFilter.value) &&
      matchesFilter(lead.conversationStart, conversationStartFilter.value) &&
      matchesFilter(lead.conclusion, conclusionFilter.value) &&
      matchesFilter(lead.visited || "sem-resposta", visitedFilter.value) &&
      matchesFilter(lead.scheduled || "sem-resposta", scheduledFilter.value) &&
      matchesFilter(lead.bought || "sem-resposta", boughtFilter.value);
    const matchesCustomFilters = getCustomFilterValues(customLeadFilters)
      .every(({ categoryId, value }) => matchesFilter(lead.customValues[categoryId] || "sem-resposta", value));
    const contactDate = getLeadDateValue(lead);
    const matchesStart = !startDateFilter.value || contactDate >= startDateFilter.value;
    const matchesEnd = !endDateFilter.value || contactDate <= endDateFilter.value;

    return matchesSimpleFilters && matchesCustomFilters && matchesStart && matchesEnd;
  });
}

function matchesLeadSearch(lead, search) {
  const customValues = lead.customValueRows.flatMap((item) => [item.categoryName, item.value]);
  const searchableValues = [
    lead.id,
    lead.name,
    lead.phone,
    onlyDigits(lead.phone),
    lead.storeName,
    lead.channel,
    lead.campaign,
    lead.conversationStart,
    lead.conclusion,
    lead.scheduled,
    getScheduledVisitLabel(lead),
    lead.visited,
    lead.bought,
    lead.purchaseAmount ? formatCurrency(lead.purchaseAmount) : "",
    lead.serviceOrder,
    lead.notes,
    formatLeadContactDate(lead),
    formatDateTime(lead.createdAt),
    ...customValues,
  ];

  return searchableValues.some((value) => normalizeSearchText(value).includes(search));
}

function getVisibleStoreLeads() {
  const store = getActiveStore();
  if (!store) return currentProfile?.role === "admin" ? leads : [];
  return leads.filter((lead) => lead.storeId === store.id);
}

function getAnalyticsBaseLeads() {
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
  if (analyticsScheduledFilter.value) {
    result = result.filter((lead) => (lead.scheduled || "sem-resposta") === analyticsScheduledFilter.value);
  }
  if (analyticsBoughtFilter.value) {
    result = result.filter((lead) => (lead.bought || "sem-resposta") === analyticsBoughtFilter.value);
  }

  getCustomFilterValues(analyticsCustomFilters).forEach(({ categoryId, value }) => {
    result = result.filter((lead) => (lead.customValues[categoryId] || "sem-resposta") === value);
  });

  return result;
}

function getAnalyticsLeads() {
  let result = getAnalyticsBaseLeads();
  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  if (mode === "single" && analyticsSingleDate.value) {
    result = result.filter((lead) => getLeadDateValue(lead) === analyticsSingleDate.value);
  }
  if (mode === "range") {
    if (analyticsStartDate.value) result = result.filter((lead) => getLeadDateValue(lead) >= analyticsStartDate.value);
    if (analyticsEndDate.value) result = result.filter((lead) => getLeadDateValue(lead) <= analyticsEndDate.value);
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
  analyticsActions.hidden = analyticsContent.hidden;
  analyticsToggle.setAttribute("aria-expanded", String(!analyticsContent.hidden));
  analyticsToggleLabel.setAttribute("aria-expanded", String(!analyticsContent.hidden));
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
  [searchInput, channelFilter, campaignFilter, conversationStartFilter, conclusionFilter, visitedFilter, scheduledFilter, boughtFilter, startDateFilter, endDateFilter].forEach((element) => {
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
    scheduled: row.scheduled || "",
    scheduledVisitDate: row.scheduled_visit_date || "",
    scheduledVisitTime: normalizeTimeValue(row.scheduled_visit_time),
    contactDate: row.contact_date || row.created_at?.slice(0, 10) || "",
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
    if (!optionRecords[group].length && defaultOptions[group]) {
      optionRecords[group] = defaultOptions[group].map((value, index) => ({
        id: `default-${group}-${index}`,
        groupKey: group,
        value,
        sortOrder: (index + 1) * 10,
        fixed: fixedOptionGroups.has(group) || fixedChannelOptions.has(value),
      }));
    }
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

function buildLeadCustomValuesPayload(lead) {
  return customCategories
    .map((category) => ({
      category_id: category.id,
      value: lead.customValues[category.id] || "",
    }))
    .filter((item) => item.value);
}

function buildLeadUpsertPayload(lead, overrides = {}) {
  const scheduled = overrides.p_scheduled ?? lead.scheduled;
  const bought = overrides.p_bought ?? lead.bought;
  return {
    p_lead_id: lead.id,
    p_name: lead.name,
    p_phone: lead.phone,
    p_contact_date: (overrides.p_contact_date ?? lead.contactDate) || null,
    p_channel: lead.channel,
    p_campaign: lead.campaign,
    p_conversation_start: lead.conversationStart,
    p_conclusion: lead.conclusion,
    p_scheduled: scheduled,
    p_scheduled_visit_date: scheduled === "Sim"
      ? (overrides.p_scheduled_visit_date ?? lead.scheduledVisitDate) || null
      : null,
    p_scheduled_visit_time: scheduled === "Sim"
      ? (overrides.p_scheduled_visit_time ?? lead.scheduledVisitTime) || null
      : null,
    p_visited: overrides.p_visited ?? lead.visited,
    p_bought: bought,
    p_purchase_amount: bought === "Sim" ? lead.purchaseAmount : null,
    p_service_order: bought === "Sim" ? lead.serviceOrder : null,
    p_notes: lead.notes,
    p_custom_values: buildLeadCustomValuesPayload(lead),
    p_store_id: lead.storeId,
    ...overrides,
  };
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

function normalizeSearchText(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

function onlyDigits(value) {
  return String(value || "").replace(/\D/g, "");
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

function toLocalDateInput(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function formatDateTime(value) {
  if (!value) return "";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

function normalizeTimeValue(value) {
  if (!value) return "";
  return String(value).slice(0, 5);
}

function formatDateInputValue(value) {
  if (!value) return "";
  const [year, month, day] = String(value).slice(0, 10).split("-");
  if (!year || !month || !day) return "";
  return `${day}/${month}/${year}`;
}

function getLeadDateValue(lead) {
  return lead?.contactDate || lead?.createdAt?.slice(0, 10) || "";
}

function getLeadSortDate(lead) {
  const date = getLeadDateValue(lead);
  const createdAt = lead?.createdAt || "";
  return date && createdAt ? `${date}T${createdAt.slice(11)}` : date || createdAt;
}

function formatLeadContactDate(lead) {
  return formatDateInputValue(getLeadDateValue(lead));
}

function getScheduledVisitLabel(lead) {
  const date = formatDateInputValue(lead?.scheduledVisitDate);
  if (!date) return "";
  return lead.scheduledVisitTime ? `${date} ${lead.scheduledVisitTime}` : date;
}

function getCurrentAppointmentLabel() {
  const date = formatDateInputValue(appointmentDateInput.value);
  if (!date) return "";
  return appointmentTimeInput.value ? `${date} ${appointmentTimeInput.value}` : date;
}

function updateAppointmentDetailsVisibility() {
  const isScheduled = selectedValues.scheduled === "Sim";
  appointmentDetails.hidden = !isScheduled;
  appointmentSummary.textContent = getCurrentAppointmentLabel() || "Escolha a data";
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
  if (fixedOptionGroups.has(group) && value === "Sim") return "choice-yes";
  if (fixedOptionGroups.has(group) && value === "Não") return "choice-no";
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

function isAbortError(error) {
  return error?.name === "AbortError" || readableError(error).toLowerCase().includes("abort");
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
