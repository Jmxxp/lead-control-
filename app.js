const SUPABASE_URL = "https://menlvmsgkhgqxiydphbn.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1lbmx2bXNna2hncXhpeWRwaGJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEyNTYxNzEsImV4cCI6MjA5NjgzMjE3MX0.ylQcT5KnVDvdP3Wa8ZKdI6FpXWnjXAkpzpfzRw0FP30";
const SESSION_STORAGE_KEY = "lead-control-session";
const THEME_STORAGE_KEY = "lead-control-theme";
const AI_CHAT_STORAGE_KEY = "lead-control-ai-chats";
const BACKUP_DB_NAME = "lead-control-backup";
const BACKUP_DB_VERSION = 2;
const BACKUP_HANDLE_STORE = "directory-handles";
const BACKUP_MANIFEST_STORE = "backup-manifests";
const BACKUP_ROOT_FOLDER = "Controle de Leads";
const BACKUP_SCHEDULE_HOUR = 20;
const SYSTEM_MODULE_STORAGE_PREFIX = "lead-control-module";

const LEGACY_AI_SYSTEM_PROMPT = `Você é uma IA especialista em análise comercial de leads para óticas. Analise os registros filtrados, encontre padrões, gargalos e oportunidades, compare lojas, canais, campanhas e resultados, e responda com recomendações objetivas para aumentar visitas, compras e conversão. Use apenas os dados fornecidos no contexto, indique quando houver pouca amostra e priorize ações práticas.`;
const LEGACY_MULTI_STORE_AI_SYSTEM_PROMPT = `Você é uma IA especialista em análise comercial de leads para óticas. Responda somente ao que o usuário perguntou, sem antecipar análises, recomendações ou assuntos que não foram pedidos. Se o usuário apenas cumprimentar, cumprimente de volta de forma breve e pergunte como pode ajudar. Quando o usuário pedir análise, use os leads filtrados como contexto, encontre padrões, gargalos e oportunidades, compare lojas, canais, campanhas e resultados quando isso for relevante para a pergunta, indique quando houver pouca amostra e priorize ações práticas. Use apenas os dados fornecidos no contexto.`;
const DEFAULT_AI_SYSTEM_PROMPT = `Você é uma IA especialista em análise comercial de leads para óticas. Responda somente ao que o usuário perguntou, sem antecipar análises, recomendações ou assuntos que não foram pedidos. Se o usuário apenas cumprimentar, cumprimente de volta de forma breve e pergunte como pode ajudar. Cada conversa recebe dados de uma única loja selecionada. Nunca combine, compare ou pressuponha dados de outras lojas. Quando o usuário pedir análise, use somente os leads filtrados dessa loja, encontre padrões, gargalos e oportunidades, indique quando houver pouca amostra e priorize ações práticas.`;

const aiProviderOptions = {
  gemini: {
    label: "Google Gemini",
    models: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.1-pro-preview"],
  },
  deepseek: {
    label: "DeepSeek",
    models: ["deepseek-chat"],
  },
};

const defaultLabels = Object.freeze({
  channel: "Plataforma / canal",
  campaign: "Campanha",
  conversationStart: "Início da conversa",
  conclusion: "Conclusão",
  scheduled: "Agendou visita",
  visited: "Visitou a loja",
  bought: "Comprou",
});

const labels = { ...defaultLabels };
const optionGroups = Object.keys(defaultLabels);
const fixedOptionGroups = new Set(["scheduled", "visited", "bought"]);
const nativeYesNoOptions = ["Sim", "Não"];
const defaultOptions = {
  channel: [],
  campaign: [],
  conversationStart: [],
  conclusion: [],
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
let activeSystemModule = "leads";
let leadModuleSnapshot = null;
let attendanceStoreSelectionId = "";
let accountUsage = null;
let companyWorkspaceSection = "clients";
let selectedAnalyticsStoreId = "";
let managedAccountCurrentAvatar = "";
let stores = [];
let leads = [];
let leadIntelligenceRows = [];
let adDailyMetrics = [];
let marketingTargets = [];
let marketingConnections = [];
let technicians = [];
let profileAvatars = [];
let customCategories = [];
let legalAcceptanceOverview = { activeVersion: "", total: 0, accepted: 0, pending: 0, accounts: [] };
let pendingLegalTerms = null;
let legalTermsGateResolve = null;
let legalTermsRecheckInFlight = false;
let agencyWhatsappGateResolve = null;
let agencyWhatsappContext = null;
let legalSignatureHasInk = false;
let legalSignatureDrawing = false;
let currentLegalDocument = null;
let pendingUnsavedAction = null;
const dirtyOptionKeys = new Set();
const dirtyOptionValues = new Map();
const dirtyGroupLabels = new Map();
let newOptionCounter = 0;
let selectedValues = createEmptySelection();
let selectedCustomValues = {};
let aiSettings = createDefaultAiSettings();
let aiChats = [];
let activeAiChatId = null;
let aiChatStoreScopeId = "";
let aiMessages = [];
let aiIsSending = false;
let aiAbortController = null;
let currentAiResponseMessage = null;
let editingAiMessageIndex = null;
let backupDirectoryHandle = null;
let backupManifest = createEmptyBackupManifest();
let backupSchedulerTimer = null;
let backupIsRunning = false;
let backupAutoAttemptDate = "";
let backupPermissionState = "prompt";
let appointmentModalMode = "lead-form";
let appointmentMonitorLeadId = null;
let leadPanelResizeObserver = null;
let leadPanelSyncFrame = 0;
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
const prospectionView = $("#prospectionView");
const whatsappView = $("#whatsappView");
const attendanceView = $("#attendanceView");
const appMainTitle = $("#appMainTitle");
const moduleLeadsButton = $("#moduleLeadsButton");
const moduleProspectionsButton = $("#moduleProspectionsButton");
const moduleWhatsAppButton = $("#moduleWhatsAppButton");
const moduleAttendancesButton = $("#moduleAttendancesButton");
const moduleSwitcher = $("#moduleSwitcher");
const sessionRole = $("#sessionRole");
const sessionAvatar = $("#sessionAvatar");
const appNotification = $("#appNotification");
const themeToggle = $("#themeToggle");
const logoutButton = $("#logoutButton");
const backAdminButton = $("#backAdminButton");
const settingsButton = $("#settingsButton");
const loginForm = $("#loginForm");
const authMessage = $("#authMessage");
const loginNick = $("#loginNick");
const loginPassword = $("#loginPassword");
const storeForm = $("#storeForm");
const storeName = $("#storeName");
const storeNick = $("#storeNick");
const storePassword = $("#storePassword");
const storeAvatar = $("#storeAvatar");
const storeAvatarPreview = $("#storeAvatarPreview");
const storeMessage = $("#storeMessage");
const storeTechnicianField = $("#storeTechnicianField");
const storeTechnician = $("#storeTechnician");
const storeFormEyebrow = $("#storeFormEyebrow");
const storeFormTitle = $("#storeFormTitle");
const technicianForm = $("#technicianForm");
const technicianName = $("#technicianName");
const technicianNick = $("#technicianNick");
const technicianPassword = $("#technicianPassword");
const technicianWhatsapp = $("#technicianWhatsapp");
const technicianAvatar = $("#technicianAvatar");
const technicianAvatarPreview = $("#technicianAvatarPreview");
const technicianStoreLimit = $("#technicianStoreLimit");
const technicianProspectionLimit = $("#technicianProspectionLimit");
const technicianWhatsappLimit = $("#technicianWhatsappLimit");
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
const adminAiSettingsForm = $("#adminAiSettingsForm");
const adminAiProvider = $("#adminAiProvider");
const adminAiModel = $("#adminAiModel");
const adminAiApiKey = $("#adminAiApiKey");
const adminAiSystemPrompt = $("#adminAiSystemPrompt");
const adminAiSavedStatus = $("#adminAiSavedStatus");
const adminAiSettingsMessage = $("#adminAiSettingsMessage");
const adminAiValidateButton = $("#adminAiValidateButton");
const managedAccountModal = $("#managedAccountModal");
const managedAccountClose = $("#managedAccountClose");
const managedAccountCancel = $("#managedAccountCancel");
const managedAccountForm = $("#managedAccountForm");
const managedAccountTitle = $("#managedAccountTitle");
const managedAccountType = $("#managedAccountType");
const managedAccountId = $("#managedAccountId");
const managedAccountName = $("#managedAccountName");
const managedAccountNameLabel = $("#managedAccountNameLabel");
const managedAccountWhatsappField = $("#managedAccountWhatsappField");
const managedAccountWhatsapp = $("#managedAccountWhatsapp");
const managedAccountTechnicianField = $("#managedAccountTechnicianField");
const managedAccountTechnician = $("#managedAccountTechnician");
const managedAccountNick = $("#managedAccountNick");
const managedAccountPassword = $("#managedAccountPassword");
const managedAccountAvatar = $("#managedAccountAvatar");
const managedAccountAvatarPreview = $("#managedAccountAvatarPreview");
const managedAccountLimitField = $("#managedAccountLimitField");
const managedAccountLimit = $("#managedAccountLimit");
const managedAccountProspectionLimitField = $("#managedAccountProspectionLimitField");
const managedAccountProspectionLimit = $("#managedAccountProspectionLimit");
const managedAccountProspectionLimitHelp = $("#managedAccountProspectionLimitHelp");
const managedAccountProspectionField = $("#managedAccountProspectionField");
const managedAccountProspectionAccess = $("#managedAccountProspectionAccess");
const managedAccountProspectionHelp = $("#managedAccountProspectionHelp");
const managedAccountProspectionStatus = $("#managedAccountProspectionStatus");
const managedAccountWhatsappLimitField = $("#managedAccountWhatsappLimitField");
const managedAccountWhatsappLimit = $("#managedAccountWhatsappLimit");
const managedAccountWhatsappLimitHelp = $("#managedAccountWhatsappLimitHelp");
const managedAccountWhatsappAccessField = $("#managedAccountWhatsappAccessField");
const managedAccountWhatsappAccess = $("#managedAccountWhatsappAccess");
const managedAccountWhatsappAccessHelp = $("#managedAccountWhatsappAccessHelp");
const managedAccountWhatsappAccessStatus = $("#managedAccountWhatsappAccessStatus");
const managedAccountMessage = $("#managedAccountMessage");
const agencyContactForm = $("#agencyContactForm");
const agencyContactWhatsapp = $("#agencyContactWhatsapp");
const agencyContactMessage = $("#agencyContactMessage");
const agencyWhatsappModal = $("#agencyWhatsappModal");
const agencyWhatsappForm = $("#agencyWhatsappForm");
const agencyWhatsappInput = $("#agencyWhatsappInput");
const agencyWhatsappMessage = $("#agencyWhatsappMessage");
const agencyWhatsappLogout = $("#agencyWhatsappLogout");
const clientCapacityPanel = $("#clientCapacityPanel");
const clientCapacityEyebrow = $("#clientCapacityEyebrow");
const clientCapacityTitle = $("#clientCapacityTitle");
const clientCapacityHint = $("#clientCapacityHint");
const clientCapacityProgress = $("#clientCapacityProgress");
const clientCapacityPercent = $("#clientCapacityPercent");
const featureCapacitySummary = $("#featureCapacitySummary");
const prospectionCapacityBadge = $("#prospectionCapacityBadge");
const whatsappCapacityBadge = $("#whatsappCapacityBadge");
const totalStoresLabel = $("#totalStoresLabel");
const totalStoresHint = $("#totalStoresHint");
const storeListTitle = $("#storeListTitle");
const clientWalletSearch = $("#clientWalletSearch");
const clearClientWalletSearch = $("#clearClientWalletSearch");
const storeEmptyTitle = $("#storeEmptyTitle");
const storeEmptyText = $("#storeEmptyText");
const companyWorkspaceNav = $("#companyWorkspaceNav");
const companyWorkspaceButtons = $$('[data-company-section]');
const backupCenter = $("#backupCenter");
const backupSupportBadge = $("#backupSupportBadge");
const backupDirectoryLabel = $("#backupDirectoryLabel");
const backupDirectoryHint = $("#backupDirectoryHint");
const backupLastRun = $("#backupLastRun");
const backupChooseDirectory = $("#backupChooseDirectory");
const backupRunNow = $("#backupRunNow");
const backupClientsTitle = $("#backupClientsTitle");
const backupClientList = $("#backupClientList");
const backupMessage = $("#backupMessage");
const legalTermsNavButton = $("#legalTermsNavButton");
const legalAdminCenter = $("#legalAdminCenter");
const legalActiveVersion = $("#legalActiveVersion");
const legalTotalAccounts = $("#legalTotalAccounts");
const legalAcceptedAccounts = $("#legalAcceptedAccounts");
const legalPendingAccounts = $("#legalPendingAccounts");
const legalAcceptanceSearch = $("#legalAcceptanceSearch");
const legalAcceptanceRoleFilter = $("#legalAcceptanceRoleFilter");
const legalAcceptanceStatusFilter = $("#legalAcceptanceStatusFilter");
const legalAcceptanceList = $("#legalAcceptanceList");
const legalAcceptanceEmpty = $("#legalAcceptanceEmpty");
const analyticsClientPicker = $("#analyticsClientPicker");
const analyticsClientSelect = $("#analyticsClientSelect");
const analyticsClientSelectTrigger = $("#analyticsClientSelectTrigger");
const analyticsClientDropdown = $("#analyticsClientDropdown");
const analyticsClientSearch = $("#analyticsClientSearch");
const analyticsClientOptions = $("#analyticsClientOptions");
const analyticsClientOptionsEmpty = $("#analyticsClientOptionsEmpty");
const analyticsClientSelector = $("#analyticsClientSelector");
const analyticsClientAvatar = $("#analyticsClientAvatar");
const analyticsClientTitle = $("#analyticsClientTitle");
const analyticsClientSubtitle = $("#analyticsClientSubtitle");
const analyticsSelectionEmpty = $("#analyticsSelectionEmpty");
const adminAnalyticsSummary = $("#adminAnalyticsSummary");
const adminAnalyticsPanel = $("#adminAnalyticsPanel");
const clientManagementArea = $("#clientManagementArea");
const analyticsStoreField = $("#analyticsStoreField");
const storeEmptyState = $("#storeEmptyState");
const storeList = $("#storeList");
const analyticsContent = $("#analyticsContent");
const analyticsStoreFilter = $("#analyticsStoreFilter");
const analyticsChannelFilter = $("#analyticsChannelFilter");
const analyticsCampaignFilter = $("#analyticsCampaignFilter");
const analyticsConclusionFilter = $("#analyticsConclusionFilter");
const analyticsLifecycleFilter = $("#analyticsLifecycleFilter");
const analyticsQualifiedFilter = $("#analyticsQualifiedFilter");
const analyticsVisitedFilter = $("#analyticsVisitedFilter");
const analyticsScheduledFilter = $("#analyticsScheduledFilter");
const analyticsBoughtFilter = $("#analyticsBoughtFilter");
const analyticsSingleDate = $("#analyticsSingleDate");
const analyticsStartDate = $("#analyticsStartDate");
const analyticsEndDate = $("#analyticsEndDate");
const analyticsApplyFiltersButton = $("#analyticsApplyFiltersButton");
const analyticsFilterStatus = $("#analyticsFilterStatus");
const analyticsSingleDateField = $(".analytics-single-date");
const analyticsRangeDateFields = $$(".analytics-range-date");
const analyticsQuickRangeField = $(".quick-range-field");
const analyticsCustomFilters = $("#analyticsCustomFilters");
const analyticsCustomSections = $("#analyticsCustomSections");
const analyticsActions = $(".analytics-ai-row");
const analyticsKpis = $("#analyticsKpis");
const marketingIntelligencePanel = $("#marketingIntelligencePanel");
const marketingFunnel = $("#marketingFunnel");
const marketingDataBadge = $("#marketingDataBadge");
const marketingGoalSummary = $("#marketingGoalSummary");
const marketingSourcePerformanceList = $("#marketingSourcePerformanceList");
const adMetricForm = $("#adMetricForm");
const adMetricDate = $("#adMetricDate");
const adMetricPlatform = $("#adMetricPlatform");
const adMetricCampaign = $("#adMetricCampaign");
const adMetricSpend = $("#adMetricSpend");
const adMetricImpressions = $("#adMetricImpressions");
const adMetricReach = $("#adMetricReach");
const adMetricClicks = $("#adMetricClicks");
const adMetricMessage = $("#adMetricMessage");
const marketingTargetsForm = $("#marketingTargetsForm");
const marketingMonthlyBudget = $("#marketingMonthlyBudget");
const marketingLeadGoal = $("#marketingLeadGoal");
const marketingQualifiedGoal = $("#marketingQualifiedGoal");
const marketingSalesGoal = $("#marketingSalesGoal");
const marketingRevenueGoal = $("#marketingRevenueGoal");
const marketingTargetRoas = $("#marketingTargetRoas");
const marketingTargetsMessage = $("#marketingTargetsMessage");
const analyticsBoard = $("#analyticsBoard");
const analyticsChartsPanel = $("#analyticsChartsPanel");
const analyticsDateModeButtons = $$("[data-analytics-date-mode]");
const analyticsQuickRangeButtons = $$("[data-analytics-range]");
const exportLeadsButton = $("#exportLeadsButton");
const storeExportLeadsButton = $("#storeExportLeadsButton");
const storeExportStartDate = $("#storeExportStartDate");
const storeExportEndDate = $("#storeExportEndDate");
const storeExportButton = $("#storeExportButton");
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
const legalTermsModal = $("#legalTermsModal");
const legalTermsTitle = $("#legalTermsTitle");
const legalTermsVersion = $("#legalTermsVersion");
const legalTermsContent = $("#legalTermsContent");
const legalTermsForm = $("#legalTermsForm");
const legalTermsLogout = $("#legalTermsLogout");
const legalTermsRetry = $("#legalTermsRetry");
const legalSignerName = $("#legalSignerName");
const legalSignerRole = $("#legalSignerRole");
const legalSignerCpf = $("#legalSignerCpf");
const legalSignatureCanvas = $("#legalSignatureCanvas");
const legalSignatureClear = $("#legalSignatureClear");
const legalConfirmRead = $("#legalConfirmRead");
const legalConfirmAuthority = $("#legalConfirmAuthority");
const legalConfirmEvidence = $("#legalConfirmEvidence");
const legalTermsMessage = $("#legalTermsMessage");
const legalDocumentModal = $("#legalDocumentModal");
const legalDocumentTitle = $("#legalDocumentTitle");
const legalDocumentSubtitle = $("#legalDocumentSubtitle");
const legalDocumentContent = $("#legalDocumentContent");
const legalDocumentEvidence = $("#legalDocumentEvidence");
const legalDocumentClose = $("#legalDocumentClose");
const legalDocumentDownload = $("#legalDocumentDownload");
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
const registeredLeadsPanel = $("#registeredLeadsPanel");
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
const leadLifecycleStatus = $("#leadLifecycleStatus");
const leadOwnerName = $("#leadOwnerName");
const leadEmail = $("#leadEmail");
const leadLossReasonField = $("#leadLossReasonField");
const leadLossReason = $("#leadLossReason");
const leadQualified = $("#leadQualified");
const leadReturningCustomer = $("#leadReturningCustomer");
const leadMarketingConsent = $("#leadMarketingConsent");
const leadUtmSource = $("#leadUtmSource");
const leadUtmMedium = $("#leadUtmMedium");
const leadUtmCampaign = $("#leadUtmCampaign");
const leadUtmContent = $("#leadUtmContent");
const leadCampaignExternalId = $("#leadCampaignExternalId");
const leadAdsetExternalId = $("#leadAdsetExternalId");
const leadAdExternalId = $("#leadAdExternalId");
const leadGoogleClickId = $("#leadGoogleClickId");
const leadMetaClickId = $("#leadMetaClickId");
const leadLandingPage = $("#leadLandingPage");
const storeOptionsPanel = $("#storeOptionsPanel");
const storeOptionsList = $("#storeOptionsList");
const storeOptionsMessage = $("#storeOptionsMessage");
const storeOptionsTitle = $("#storeOptionsTitle");
const storeOptionsSubtitle = $("#storeOptionsSubtitle");
const storeOptionsClose = $("#storeOptionsClose");
const storeOptionsDone = $("#storeOptionsDone");
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
  { id: "channel", label: "Plataformas / canais", key: "channel", optionGroup: "channel", container: "#analyticsChannelCards", summary: "#analyticsChannelSummary" },
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
  bindFocusModality();
  loadAiSettings();
  setTodayLabel();
  if (adMetricDate) adMetricDate.value = toLocalDateInput(new Date());
  syncLeadIntelligenceVisibility();
  bindEvents();
  initializeLeadWorkspaceSizing();
  showAuth();
  renderAiSettingsForm();
  renderAiMessages();
  renderAll();
  initializeSupabase();
  window.MarketingAttributionModule?.initialize?.({
    rpc: authenticatedRpc,
    edge: callMarketingEdge,
    notify: showAppNotification,
    supabaseUrl: SUPABASE_URL,
  });

  if (!isSupabaseReady()) {
    showAuthMessage("Cole a URL e a chave pública/anon do Supabase no topo do app.js.");
    return;
  }

  await restoreSession();
}

function bindEvents() {
  $$("[data-toggle-password]").forEach((button) => {
    button.addEventListener("click", () => togglePassword(button));
  });

  loginForm.addEventListener("submit", handleLogin);
  moduleLeadsButton.addEventListener("click", () => guardUnsavedOptions(() => setSystemModule("leads")));
  moduleProspectionsButton.addEventListener("click", () => guardUnsavedOptions(() => setSystemModule("prospections")));
  moduleWhatsAppButton.addEventListener("click", () => guardUnsavedOptions(() => setSystemModule("whatsapp")));
  moduleAttendancesButton.addEventListener("click", () => guardUnsavedOptions(() => setSystemModule("attendances")));
  moduleSwitcher.addEventListener("keydown", handleModuleSwitcherKeydown);
  logoutButton.addEventListener("click", () => guardUnsavedOptions(confirmLogout));
  backAdminButton.addEventListener("click", () => guardUnsavedOptions(returnToAdmin));
  settingsButton.addEventListener("click", openSettingsModal);
  settingsClose.addEventListener("click", closeSettingsModal);
  settingsCancel.addEventListener("click", closeSettingsModal);
  settingsModal.addEventListener("click", (event) => {
    if (event.target === settingsModal) closeSettingsModal();
  });
  adminAiProvider.addEventListener("input", handleAdminAiProviderChange);
  adminAiSettingsForm.addEventListener("submit", handleAdminAiSettingsSubmit);
  adminAiValidateButton.addEventListener("click", handleAdminAiValidate);
  managedAccountClose.addEventListener("click", closeManagedAccountModal);
  managedAccountCancel.addEventListener("click", closeManagedAccountModal);
  managedAccountModal.addEventListener("click", (event) => {
    if (event.target === managedAccountModal) closeManagedAccountModal();
  });
  managedAccountForm.addEventListener("submit", handleManagedAccountSubmit);
  managedAccountProspectionAccess.addEventListener("change", () => {
    syncManagedStoreEntitlementQuotas();
    syncManagedAccountProspectionToggle();
  });
  managedAccountWhatsappAccess?.addEventListener("change", () => {
    syncManagedStoreEntitlementQuotas();
    syncManagedAccountWhatsappToggle();
  });
  managedAccountTechnician?.addEventListener("change", () => {
    syncManagedStoreEntitlementQuotas();
    syncManagedAccountProspectionToggle();
    syncManagedAccountWhatsappToggle();
  });
  managedAccountWhatsapp?.addEventListener("input", () => {
    managedAccountWhatsapp.value = formatWhatsAppInput(managedAccountWhatsapp.value);
  });
  storeForm.addEventListener("submit", handleCreateStore);
  storeTechnician.addEventListener("input", syncStoreCreationAvailability);
  technicianForm.addEventListener("submit", handleCreateTechnician);
  technicianWhatsapp?.addEventListener("input", () => {
    technicianWhatsapp.value = formatWhatsAppInput(technicianWhatsapp.value);
  });
  agencyContactWhatsapp?.addEventListener("input", () => {
    agencyContactWhatsapp.value = formatWhatsAppInput(agencyContactWhatsapp.value);
  });
  agencyWhatsappInput?.addEventListener("input", () => {
    agencyWhatsappInput.value = formatWhatsAppInput(agencyWhatsappInput.value);
  });
  agencyContactForm?.addEventListener("submit", handleAgencyContactSubmit);
  agencyWhatsappForm?.addEventListener("submit", handleRequiredAgencyWhatsappSubmit);
  agencyWhatsappLogout?.addEventListener("click", handleAgencyWhatsappLogout);
  adminAccountForm.addEventListener("submit", handleAdminAccountSubmit);
  storeOptionsList.addEventListener("click", handleOptionsEditorClick);
  storeOptionsList.addEventListener("input", handleOptionsEditorInput);
  storeOptionsClose.addEventListener("click", requestCloseStoreOptions);
  storeOptionsDone.addEventListener("click", requestCloseStoreOptions);
  storeOptionsPanel.addEventListener("click", (event) => {
    if (event.target === storeOptionsPanel) requestCloseStoreOptions();
  });
  companyWorkspaceButtons.forEach((button) => {
    button.addEventListener("click", () => setCompanyWorkspaceSection(button.dataset.companySection));
  });
  [legalAcceptanceSearch, legalAcceptanceRoleFilter, legalAcceptanceStatusFilter].forEach((element) => {
    element?.addEventListener("input", renderLegalAcceptanceList);
  });
  legalAcceptanceList?.addEventListener("click", handleLegalAcceptanceListClick);
  legalTermsForm?.addEventListener("submit", handleLegalTermsSubmit);
  legalTermsLogout?.addEventListener("click", handleLegalTermsLogout);
  legalTermsRetry?.addEventListener("click", () => window.location.reload());
  legalSignerCpf?.addEventListener("input", () => {
    legalSignerCpf.value = formatCpfInput(legalSignerCpf.value);
  });
  legalSignatureClear?.addEventListener("click", clearLegalSignature);
  legalDocumentClose?.addEventListener("click", closeLegalDocumentModal);
  legalDocumentDownload?.addEventListener("click", downloadCurrentLegalDocument);
  legalDocumentModal?.addEventListener("click", (event) => {
    if (event.target === legalDocumentModal) closeLegalDocumentModal();
  });
  window.addEventListener("focus", recheckLegalTermsForActiveSession);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") recheckLegalTermsForActiveSession();
  });
  window.setInterval(recheckLegalTermsForActiveSession, 60000);
  bindLegalSignatureCanvas();
  analyticsClientSelector.addEventListener("input", () => {
    handleAnalyticsClientSelection().catch((error) => showAppNotification(readableError(error), "error"));
  });
  analyticsClientSelectTrigger.addEventListener("click", () => {
    setAnalyticsClientDropdown(analyticsClientDropdown.hidden);
  });
  analyticsClientSelectTrigger.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setAnalyticsClientDropdown(true, "option");
    }
    if (event.key === "Escape") setAnalyticsClientDropdown(false);
  });
  analyticsClientSearch.addEventListener("input", renderAnalyticsClientOptions);
  analyticsClientSearch.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      focusAnalyticsClientOption(0);
    }
    if (event.key === "Escape") {
      event.preventDefault();
      setAnalyticsClientDropdown(false, "trigger");
    }
  });
  analyticsClientOptions.addEventListener("click", (event) => {
    const option = event.target.closest("[data-analytics-store-id]");
    if (!option) return;
    selectAnalyticsClient(option.dataset.analyticsStoreId).catch((error) => showAppNotification(readableError(error), "error"));
  });
  analyticsClientOptions.addEventListener("keydown", handleAnalyticsClientOptionsKeydown);
  document.addEventListener("click", (event) => {
    if (!analyticsClientDropdown.hidden && !analyticsClientSelect.contains(event.target)) {
      setAnalyticsClientDropdown(false);
    }
  });
  [
    [storeAvatar, storeAvatarPreview, "store"],
    [technicianAvatar, technicianAvatarPreview, "building"],
    [managedAccountAvatar, managedAccountAvatarPreview, "camera"],
  ].forEach(([input, preview, fallbackIcon]) => {
    input.addEventListener("input", () => previewAvatarFile(input, preview, fallbackIcon));
  });
  $$('[data-avatar-input]').forEach((button) => {
    button.addEventListener("click", () => document.getElementById(button.dataset.avatarInput)?.click());
  });
  clientWalletSearch.addEventListener("input", renderStoreList);
  clearClientWalletSearch.addEventListener("click", () => {
    clientWalletSearch.value = "";
    renderStoreList();
    clientWalletSearch.focus();
  });
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
  exportLeadsButton.addEventListener("click", exportLeadsToExcel);
  storeExportLeadsButton.addEventListener("click", exportFilteredStoreLeadsToExcel);
  backupChooseDirectory.addEventListener("click", chooseBackupDirectory);
  backupRunNow.addEventListener("click", () => {
    runBackup({ manual: true }).catch((error) => showBackupMessage(readableError(error), "error"));
  });
  storeExportButton.addEventListener("click", exportStoreLeadsToExcel);
  [storeExportStartDate, storeExportEndDate].forEach((element) => {
    element.addEventListener("input", renderStoreExportSummary);
  });
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
    analyticsLifecycleFilter,
    analyticsQualifiedFilter,
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
    element.addEventListener("change", renderAdminAnalytics);
  });
  analyticsDateModeButtons.forEach((button) => {
    button.addEventListener("click", () => setAnalyticsDateMode(button.dataset.analyticsDateMode));
  });
  analyticsQuickRangeButtons.forEach((button) => {
    button.addEventListener("click", () => setAnalyticsQuickRange(button.dataset.analyticsRange));
  });
  analyticsApplyFiltersButton.addEventListener("click", forceApplyAnalyticsFilters);
  adMetricForm?.addEventListener("submit", handleAdMetricSubmit);
  marketingTargetsForm?.addEventListener("submit", handleMarketingTargetsSubmit);
  adMetricSpend?.addEventListener("input", () => {
    adMetricSpend.value = adMetricSpend.value.replace(/[^\d.,]/g, "");
  });
  [marketingMonthlyBudget, marketingRevenueGoal].forEach((element) => {
    element?.addEventListener("input", () => {
      element.value = element.value.replace(/[^\d.,]/g, "");
    });
  });

  form.addEventListener("submit", handleLeadSubmit);
  clearFormButton.addEventListener("click", resetLeadForm);
  cancelEditButton.addEventListener("click", resetLeadForm);
  toggleOptionsEditButton.addEventListener("click", () => toggleStoreOptionsMode(true));
  phoneInput.addEventListener("input", () => {
    phoneInput.value = formatPhone(phoneInput.value);
  });
  purchaseAmountInput.addEventListener("input", () => {
    purchaseAmountInput.value = purchaseAmountInput.value.replace(/[^\d.,]/g, "");
  });
  leadLifecycleStatus?.addEventListener("input", syncLeadIntelligenceVisibility);
  leadQualified?.addEventListener("input", () => {
    if (leadQualified.checked && ["new", "contacted"].includes(leadLifecycleStatus.value)) {
      leadLifecycleStatus.value = "qualified";
    }
    syncLeadIntelligenceVisibility();
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
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !storeOptionsPanel.hidden && unsavedOptionsModal.hidden && confirmModal.hidden) {
      event.preventDefault();
      requestCloseStoreOptions();
    }
  });
}

function initializeLeadWorkspaceSizing() {
  window.addEventListener("resize", scheduleLeadWorkspaceSizing);
  if (typeof ResizeObserver === "function") {
    leadPanelResizeObserver = new ResizeObserver(scheduleLeadWorkspaceSizing);
    leadPanelResizeObserver.observe(form);
  }
  scheduleLeadWorkspaceSizing();
}

function scheduleLeadWorkspaceSizing() {
  cancelAnimationFrame(leadPanelSyncFrame);
  leadPanelSyncFrame = requestAnimationFrame(syncLeadWorkspacePanelHeight);
}

function syncLeadWorkspacePanelHeight() {
  if (!registeredLeadsPanel || !form) return;

  const isSideBySide = window.matchMedia("(min-width: 1081px)").matches;
  if (!isSideBySide || storeView.hidden) {
    registeredLeadsPanel.style.removeProperty("height");
    return;
  }

  const formHeight = Math.ceil(form.getBoundingClientRect().height);
  if (formHeight > 0) registeredLeadsPanel.style.height = `${formHeight}px`;
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
  appView.hidden = true;
  const legalAccessGranted = await ensureLegalTermsAcceptance();
  if (!legalAccessGranted) return;
  appView.hidden = false;
  await refreshRemoteState();
  const agencyContactReady = await ensureAgencyWhatsappRegistration();
  if (!agencyContactReady) return;
  appView.hidden = false;

  if (["admin", "technician"].includes(profile.role)) {
    await refreshCentralAiSettings({ silent: true });
    await initializeBackupSystem();
  } else {
    stopBackupScheduler();
  }

  if (profile.role === "admin" || profile.role === "technician") {
    showAdminDashboard();
  } else {
    showStoreDashboard();
  }

  const preferredModule = localStorage.getItem(getSystemModuleStorageKey()) || "leads";
  if (["prospections", "whatsapp", "attendances"].includes(preferredModule)) {
    await setSystemModule(preferredModule, { persist: false });
  } else {
    updateSystemModuleControls();
  }
}

async function ensureLegalTermsAcceptance() {
  if (!currentProfile) return true;

  let response;
  try {
    response = firstRow(await authenticatedRpc("lc_get_required_legal_terms"));
  } catch (error) {
    return showBlockedLegalTermsGate(error);
  }

  if (!response?.required || !response.terms) return true;
  appView.hidden = true;
  pendingLegalTerms = response.terms;
  legalTermsModal.classList.remove("is-unavailable");
  legalTermsRetry.hidden = true;
  legalTermsForm.hidden = false;
  legalTermsForm.reset();
  legalSignerName.value = currentProfile.fullName || "";
  legalTermsTitle.textContent = response.terms.title || "Termos de Uso e Privacidade";
  legalTermsVersion.textContent = `Versão ${response.terms.version || "vigente"} · aceite necessário para continuar`;
  legalTermsContent.innerHTML = renderLegalTermsMarkup(response.terms.content || "");
  legalTermsMessage.textContent = "";
  legalTermsModal.hidden = false;
  document.body.classList.add("is-legal-gated");
  syncModalLock();

  requestAnimationFrame(() => {
    initializeLegalSignatureCanvas();
    legalTermsContent.focus();
  });

  return new Promise((resolve) => {
    legalTermsGateResolve = resolve;
  });
}

function showBlockedLegalTermsGate(error) {
  appView.hidden = true;
  pendingLegalTerms = null;
  legalTermsModal.classList.add("is-unavailable");
  legalTermsRetry.hidden = false;
  legalTermsForm.hidden = true;
  legalTermsTitle.textContent = "Acesso bloqueado";
  legalTermsVersion.textContent = "Os Termos de Uso precisam estar disponíveis e assinados antes de entrar.";
  legalTermsContent.innerHTML = `<div class="legal-gate-error">
    <span><i class="fa-solid fa-lock"></i></span>
    <div><h3>Sistema protegido pelos Termos de Uso</h3><p>Nenhum módulo, dado ou ferramenta foi liberado para esta conta.</p><p>Peça ao administrador para concluir a configuração dos Termos e tente entrar novamente.</p></div>
  </div>`;
  legalTermsMessage.textContent = readableError(error);
  legalTermsModal.hidden = false;
  document.body.classList.add("is-legal-gated");
  syncModalLock();
  requestAnimationFrame(() => legalTermsContent.focus());

  return new Promise((resolve) => {
    legalTermsGateResolve = resolve;
  });
}

async function recheckLegalTermsForActiveSession() {
  if (
    legalTermsRecheckInFlight
    || !currentProfile?.sessionToken
    || !authScreen.hidden
    || !legalTermsModal?.hidden
    || legalTermsGateResolve
    || !agencyWhatsappModal?.hidden
  ) return;

  legalTermsRecheckInFlight = true;
  try {
    const allowed = await ensureLegalTermsAcceptance();
    if (allowed && currentProfile) {
      appView.hidden = false;
      renderAll();
    }
  } finally {
    legalTermsRecheckInFlight = false;
  }
}

function getAgencyWhatsappValue() {
  return String(
    agencyWhatsappContext?.profile?.agency_whatsapp
      || currentProfile?.agencyWhatsapp
      || "",
  );
}

function ensureAgencyWhatsappRegistration() {
  if (currentProfile?.role !== "technician" || !agencyWhatsappContext) return true;
  if (isValidWhatsAppNumber(getAgencyWhatsappValue())) return true;

  appView.hidden = true;
  agencyWhatsappForm.reset();
  agencyWhatsappInput.value = "";
  agencyWhatsappMessage.textContent = "";
  agencyWhatsappModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => agencyWhatsappInput.focus());

  return new Promise((resolve) => {
    agencyWhatsappGateResolve = resolve;
  });
}

async function saveAgencyWhatsapp(value, technicianId = null) {
  if (!isValidWhatsAppNumber(value)) {
    throw new Error("Informe um WhatsApp válido com DDD.");
  }
  const args = { p_whatsapp: value };
  if (technicianId) args.p_technician_id = technicianId;
  const result = firstRow(await authenticatedRpc("lc_set_agency_whatsapp", args));
  const normalized = String(result?.whatsapp || normalizeWhatsAppNumber(value));
  currentProfile.agencyWhatsapp = normalized;
  if (agencyWhatsappContext?.profile && currentProfile.role === "technician") {
    agencyWhatsappContext.profile.agency_whatsapp = normalized;
  }
  if (accountUsage && currentProfile.role === "technician") accountUsage.whatsappPhone = normalized;
  return normalized;
}

async function handleRequiredAgencyWhatsappSubmit(event) {
  event.preventDefault();
  agencyWhatsappMessage.textContent = "";
  try {
    setFormBusy(agencyWhatsappForm, true);
    await saveAgencyWhatsapp(agencyWhatsappInput.value);
    agencyWhatsappModal.hidden = true;
    syncModalLock();
    const resolveGate = agencyWhatsappGateResolve;
    agencyWhatsappGateResolve = null;
    resolveGate?.(true);
  } catch (error) {
    agencyWhatsappMessage.textContent = readableError(error);
  } finally {
    setFormBusy(agencyWhatsappForm, false);
  }
}

async function handleAgencyContactSubmit(event) {
  event.preventDefault();
  agencyContactMessage.textContent = "";
  try {
    setFormBusy(agencyContactForm, true);
    const normalized = await saveAgencyWhatsapp(agencyContactWhatsapp.value);
    agencyContactWhatsapp.value = formatWhatsAppInput(normalized);
    agencyContactMessage.textContent = "WhatsApp atualizado. Seus clientes já podem solicitar o upgrade por aqui.";
    agencyContactMessage.classList.add("success");
  } catch (error) {
    agencyContactMessage.classList.remove("success");
    agencyContactMessage.textContent = readableError(error);
  } finally {
    setFormBusy(agencyContactForm, false);
  }
}

async function handleAgencyWhatsappLogout() {
  agencyWhatsappModal.hidden = true;
  syncModalLock();
  const resolveGate = agencyWhatsappGateResolve;
  agencyWhatsappGateResolve = null;
  resolveGate?.(false);
  await handleLogout();
}

function renderLegalTermsMarkup(content) {
  const lines = String(content || "").replace(/\r/g, "").split("\n");
  const output = [];
  let listOpen = false;
  const closeList = () => {
    if (!listOpen) return;
    output.push("</ul>");
    listOpen = false;
  };

  lines.forEach((rawLine) => {
    const line = rawLine.trim();
    if (!line) {
      closeList();
      return;
    }
    if (line.startsWith("## ")) {
      closeList();
      output.push(`<h3>${escapeHtml(line.slice(3))}</h3>`);
      return;
    }
    if (line.startsWith("- ")) {
      if (!listOpen) {
        output.push("<ul>");
        listOpen = true;
      }
      output.push(`<li>${escapeHtml(line.slice(2))}</li>`);
      return;
    }
    closeList();
    output.push(`<p>${escapeHtml(line)}</p>`);
  });
  closeList();
  return output.join("");
}

function bindLegalSignatureCanvas() {
  if (!legalSignatureCanvas) return;
  legalSignatureCanvas.addEventListener("pointerdown", startLegalSignatureStroke);
  legalSignatureCanvas.addEventListener("pointermove", continueLegalSignatureStroke);
  legalSignatureCanvas.addEventListener("pointerup", endLegalSignatureStroke);
  legalSignatureCanvas.addEventListener("pointercancel", endLegalSignatureStroke);
  legalSignatureCanvas.addEventListener("pointerleave", (event) => {
    if (legalSignatureDrawing && event.buttons === 0) endLegalSignatureStroke(event);
  });
}

function initializeLegalSignatureCanvas() {
  if (!legalSignatureCanvas) return;
  const rect = legalSignatureCanvas.getBoundingClientRect();
  const pixelRatio = Math.max(1, Math.min(window.devicePixelRatio || 1, 2));
  legalSignatureCanvas.width = Math.max(1, Math.round(rect.width * pixelRatio));
  legalSignatureCanvas.height = Math.max(1, Math.round(rect.height * pixelRatio));
  const context = legalSignatureCanvas.getContext("2d");
  context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, rect.width, rect.height);
  context.lineCap = "round";
  context.lineJoin = "round";
  context.lineWidth = 3.4;
  context.strokeStyle = "#102a43";
  context.shadowColor = "rgba(16, 42, 67, 0.16)";
  context.shadowBlur = 0.6;
  legalSignatureHasInk = false;
  legalSignatureDrawing = false;
  legalSignatureCanvas.classList.remove("has-ink", "has-error");
}

function legalSignaturePoint(event) {
  const rect = legalSignatureCanvas.getBoundingClientRect();
  return { x: event.clientX - rect.left, y: event.clientY - rect.top };
}

function startLegalSignatureStroke(event) {
  if (legalTermsModal.hidden) return;
  event.preventDefault();
  legalSignatureDrawing = true;
  legalSignatureCanvas.setPointerCapture?.(event.pointerId);
  const point = legalSignaturePoint(event);
  const context = legalSignatureCanvas.getContext("2d");
  context.beginPath();
  context.moveTo(point.x, point.y);
  context.lineTo(point.x + 0.1, point.y + 0.1);
  context.stroke();
  legalSignatureHasInk = true;
  legalSignatureCanvas.classList.add("has-ink");
  legalSignatureCanvas.classList.remove("has-error");
}

function continueLegalSignatureStroke(event) {
  if (!legalSignatureDrawing) return;
  event.preventDefault();
  const point = legalSignaturePoint(event);
  const context = legalSignatureCanvas.getContext("2d");
  context.lineTo(point.x, point.y);
  context.stroke();
}

function endLegalSignatureStroke(event) {
  if (!legalSignatureDrawing) return;
  legalSignatureDrawing = false;
  try { legalSignatureCanvas.releasePointerCapture?.(event.pointerId); } catch {}
}

function clearLegalSignature() {
  initializeLegalSignatureCanvas();
  legalSignatureCanvas.focus?.();
}

function formatCpfInput(value) {
  const digits = String(value || "").replace(/\D/g, "").slice(0, 11);
  return digits
    .replace(/^(\d{3})(\d)/, "$1.$2")
    .replace(/^(\d{3})\.(\d{3})(\d)/, "$1.$2.$3")
    .replace(/\.(\d{3})(\d)/, ".$1-$2");
}

function isValidCpf(value) {
  const digits = String(value || "").replace(/\D/g, "");
  if (digits.length !== 11 || /^(\d)\1{10}$/.test(digits)) return false;
  const calculate = (length) => {
    let sum = 0;
    for (let index = 0; index < length; index += 1) sum += Number(digits[index]) * (length + 1 - index);
    const remainder = (sum * 10) % 11;
    return remainder === 10 ? 0 : remainder;
  };
  return calculate(9) === Number(digits[9]) && calculate(10) === Number(digits[10]);
}

async function handleLegalTermsSubmit(event) {
  event.preventDefault();
  legalTermsMessage.textContent = "";

  if (!pendingLegalTerms) return;
  if (!isValidCpf(legalSignerCpf.value)) {
    legalTermsMessage.textContent = "Informe um CPF válido para identificar o responsável.";
    legalSignerCpf.focus();
    return;
  }
  if (!legalSignatureHasInk) {
    legalTermsMessage.textContent = "Faça sua assinatura no campo indicado.";
    legalSignatureCanvas.classList.add("has-error");
    return;
  }
  if (![legalConfirmRead, legalConfirmAuthority, legalConfirmEvidence].every((input) => input.checked)) {
    legalTermsMessage.textContent = "Confirme as três declarações para continuar.";
    return;
  }

  try {
    setFormBusy(legalTermsForm, true);
    await authenticatedRpc("lc_accept_legal_terms", {
      p_signer_name: legalSignerName.value.trim(),
      p_signer_role: legalSignerRole.value.trim(),
      p_signer_cpf: legalSignerCpf.value,
      p_signature_data_url: legalSignatureCanvas.toDataURL("image/png"),
      p_user_agent: navigator.userAgent,
      p_client_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "",
      p_client_timestamp: new Date().toISOString(),
    });
    legalTermsModal.hidden = true;
    document.body.classList.remove("is-legal-gated");
    pendingLegalTerms = null;
    syncModalLock();
    const resolveGate = legalTermsGateResolve;
    legalTermsGateResolve = null;
    resolveGate?.(true);
  } catch (error) {
    legalTermsMessage.textContent = readableError(error);
  } finally {
    setFormBusy(legalTermsForm, false);
  }
}

async function handleLegalTermsLogout() {
  legalTermsModal.hidden = true;
  document.body.classList.remove("is-legal-gated");
  pendingLegalTerms = null;
  syncModalLock();
  const resolveGate = legalTermsGateResolve;
  legalTermsGateResolve = null;
  resolveGate?.(false);
  await handleLogout();
}

function showAdminDashboard() {
  activeStoreContext = null;
  activeTechnicianContext = null;
  companyWorkspaceSection = "clients";
  selectedAnalyticsStoreId = "";
  clientWalletSearch.value = "";
  syncAiChatStoreScope("");
  const isTechnician = currentProfile.role === "technician";
  sessionRole.textContent = `${isTechnician ? "Agência" : "Admin"} · ${currentProfile.fullName || currentProfile.username}`;
  storeForm.hidden = false;
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
  sessionRole.textContent = `Cliente · ${activeStoreContext?.name || currentProfile.username}`;
  backAdminButton.hidden = true;
  settingsButton.hidden = true;
  appointmentMonitorToggle.hidden = false;
  toggleOptionsEditButton.hidden = false;
  clearFormButton.hidden = true;
  storeOptionsPanel.hidden = true;
  initializeStoreExportDates();
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
    closeAiChat();
    clearStoredSession();
    currentProfile = null;
    activeStoreContext = null;
    activeTechnicianContext = null;
    accountUsage = null;
    companyWorkspaceSection = "clients";
    selectedAnalyticsStoreId = "";
    stores = [];
    leads = [];
    technicians = [];
    profileAvatars = [];
    legalAcceptanceOverview = { activeVersion: "", total: 0, accepted: 0, pending: 0, accounts: [] };
    aiChats = [];
    activeAiChatId = null;
    aiChatStoreScopeId = "";
    aiMessages = [];
    customCategories = [];
    options = cloneOptions(defaultOptions);
    optionRecords = createDefaultOptionRecords();
    applyCategoryLabelRows([]);
    selectedCustomValues = {};
    stopBackupScheduler();
    backupDirectoryHandle = null;
    backupManifest = createEmptyBackupManifest();
    backupAutoAttemptDate = "";
    resetLeadForm();
    showAuth();
    renderAll();
  }
}

function showAuth() {
  clearAppNotification();
  closeSettingsModal();
  closeManagedAccountModal();
  closeAiChat();
  window.ProspectionsModule?.deactivate?.();
  window.WhatsAppModule?.deactivate?.();
  window.AttendancesModule?.resetSession?.();
  activeSystemModule = "leads";
  setProspectionVisualMode(false);
  setWhatsAppVisualMode(false);
  setAttendanceVisualMode(false);
  leadModuleSnapshot = null;
  attendanceStoreSelectionId = "";
  settingsButton.hidden = true;
  authScreen.hidden = false;
  appView.hidden = true;
  adminView.hidden = true;
  storeView.hidden = true;
  prospectionView.hidden = true;
  whatsappView.hidden = true;
  attendanceView.hidden = true;
  if (legalTermsModal) legalTermsModal.hidden = true;
  if (legalDocumentModal) legalDocumentModal.hidden = true;
  if (agencyWhatsappModal) agencyWhatsappModal.hidden = true;
  agencyWhatsappContext = null;
  agencyWhatsappGateResolve = null;
  pendingLegalTerms = null;
  legalTermsModal?.classList.remove("is-unavailable");
  if (legalTermsRetry) legalTermsRetry.hidden = true;
  if (legalTermsForm) legalTermsForm.hidden = false;
  currentLegalDocument = null;
  document.body.classList.remove("is-legal-gated");
  appMainTitle.textContent = "Controle de Leads";
  syncModalLock();
  updateSystemModuleControls();
}

function getSystemModuleStorageKey() {
  return `${SYSTEM_MODULE_STORAGE_PREFIX}:${currentProfile?.id || "anonymous"}`;
}

function handleModuleSwitcherKeydown(event) {
  if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
  const buttons = [moduleLeadsButton, moduleProspectionsButton, moduleWhatsAppButton, moduleAttendancesButton]
    .filter((button) => !button.disabled);
  if (!buttons.length) return;
  const currentIndex = Math.max(0, buttons.indexOf(document.activeElement));
  const nextIndex = event.key === "Home"
    ? 0
    : event.key === "End"
      ? buttons.length - 1
      : (currentIndex + (event.key === "ArrowRight" ? 1 : -1) + buttons.length) % buttons.length;
  event.preventDefault();
  buttons[nextIndex].focus();
  buttons[nextIndex].click();
}

function updateSystemModuleControls() {
  const isLeads = activeSystemModule === "leads";
  const isProspections = activeSystemModule === "prospections";
  const isWhatsApp = activeSystemModule === "whatsapp";
  const isAttendances = activeSystemModule === "attendances";
  const prospectionsAllowed = canUseProspections();
  const whatsappAllowed = canUseWhatsApp();
  moduleLeadsButton.classList.toggle("is-active", isLeads);
  moduleProspectionsButton.classList.toggle("is-active", isProspections);
  moduleWhatsAppButton.classList.toggle("is-active", isWhatsApp);
  moduleAttendancesButton.classList.toggle("is-active", isAttendances);
  moduleProspectionsButton.classList.toggle("is-locked", !prospectionsAllowed);
  moduleWhatsAppButton.classList.toggle("is-locked", !whatsappAllowed);
  moduleAttendancesButton.classList.toggle("is-locked", !prospectionsAllowed);
  moduleProspectionsButton.disabled = !currentProfile;
  moduleWhatsAppButton.disabled = !currentProfile;
  moduleAttendancesButton.disabled = !currentProfile;
  moduleLeadsButton.setAttribute("aria-selected", String(isLeads));
  moduleProspectionsButton.setAttribute("aria-selected", String(isProspections));
  moduleWhatsAppButton.setAttribute("aria-selected", String(isWhatsApp));
  moduleAttendancesButton.setAttribute("aria-selected", String(isAttendances));
  moduleLeadsButton.tabIndex = isLeads ? 0 : -1;
  moduleProspectionsButton.tabIndex = isProspections ? 0 : -1;
  moduleWhatsAppButton.tabIndex = isWhatsApp ? 0 : -1;
  moduleAttendancesButton.tabIndex = isAttendances ? 0 : -1;
  moduleProspectionsButton.setAttribute("aria-disabled", "false");
  moduleWhatsAppButton.setAttribute("aria-disabled", String(!currentProfile));
  moduleAttendancesButton.setAttribute("aria-disabled", String(!currentProfile));
  moduleProspectionsButton.title = prospectionsAllowed
    ? "Abrir Prospecções"
    : "Conhecer Prospecções e solicitar upgrade";
  moduleWhatsAppButton.title = whatsappAllowed
    ? "Abrir WhatsApp Business"
    : "WhatsApp ainda não está liberado para este cliente";
  moduleAttendancesButton.title = prospectionsAllowed
    ? "Registrar e acompanhar atendimentos"
    : "Atendimentos é liberado junto com Prospecções";
}

function canUseProspections() {
  if (!currentProfile) return false;
  if (["admin", "technician"].includes(currentProfile.role)) {
    return activeStoreContext ? activeStoreContext.prospectionEnabled !== false : true;
  }
  const profileStore = stores.find((store) => store.id === currentProfile.storeId);
  return Boolean(profileStore?.prospectionEnabled ?? currentProfile.prospectionEnabled);
}

function canUseWhatsApp() {
  if (!currentProfile) return false;
  if (["admin", "technician"].includes(currentProfile.role)) {
    if (activeStoreContext) return activeStoreContext.whatsappEnabled === true;
    const scopedStores = currentProfile.role === "technician"
      ? stores.filter((store) => store.technicianId === currentProfile.id)
      : activeTechnicianContext
        ? stores.filter((store) => store.technicianId === activeTechnicianContext.id)
        : stores;
    return scopedStores.some((store) => store.whatsappEnabled === true);
  }
  const profileStore = stores.find((store) => store.id === currentProfile.storeId);
  return Boolean(profileStore?.whatsappEnabled ?? currentProfile.whatsappEnabled);
}

function setProspectionVisualMode(enabled, operation = false) {
  const stylesheet = document.querySelector("#prospecOriginalStyles");
  if (stylesheet) stylesheet.disabled = !(enabled && operation);
  document.body.classList.toggle("is-prospections-module", enabled);
  document.body.classList.toggle("is-prospections-operation", enabled && operation);
}

function setWhatsAppVisualMode(enabled) {
  document.body.classList.toggle("is-whatsapp-module", enabled);
}

function setAttendanceVisualMode(enabled) {
  document.body.classList.toggle("is-attendances-module", enabled);
}

function captureLeadModuleSnapshot() {
  return {
    adminViewHidden: adminView.hidden,
    storeViewHidden: storeView.hidden,
    sessionRoleText: sessionRole.textContent,
    backAdminHidden: backAdminButton.hidden,
    settingsHidden: settingsButton.hidden,
    appointmentToggleHidden: appointmentMonitorToggle.hidden,
    appointmentPanelHidden: appointmentMonitorPanel.hidden,
  };
}

function restoreLeadModuleSnapshot() {
  const fallbackShowsAdmin = ["admin", "technician"].includes(currentProfile?.role);
  const snapshot = leadModuleSnapshot || {};
  adminView.hidden = snapshot.adminViewHidden ?? !fallbackShowsAdmin;
  storeView.hidden = snapshot.storeViewHidden ?? fallbackShowsAdmin;
  sessionRole.textContent = snapshot.sessionRoleText || sessionRole.textContent;
  backAdminButton.hidden = snapshot.backAdminHidden ?? true;
  settingsButton.hidden = snapshot.settingsHidden ?? currentProfile?.role !== "admin";
  appointmentMonitorToggle.hidden = snapshot.appointmentToggleHidden ?? currentProfile?.role !== "store";
  appointmentMonitorPanel.hidden = snapshot.appointmentPanelHidden ?? true;
}

async function setSystemModule(moduleName, { persist = true } = {}) {
  if (!currentProfile) return;
  const nextModule = ["leads", "prospections", "whatsapp", "attendances"].includes(moduleName) ? moduleName : "leads";

  if (nextModule === "whatsapp" && !canUseWhatsApp()) {
    if (currentProfile.role !== "store" && activeStoreContext) {
      showAppNotification("O WhatsApp Business não está liberado para este cliente. Ative uma licença no gerenciamento de acessos.", "warning");
      updateSystemModuleControls();
      return;
    }
  }

  if (nextModule === "attendances" && !canUseProspections()) {
    if (currentProfile.role === "store") {
      await setSystemModule("prospections", { persist });
      showAppNotification("Atendimentos é liberado junto com Prospecções. Solicite o upgrade à sua agência.", "warning");
    } else {
      showAppNotification("Atendimentos acompanha a licença de Prospecções deste cliente e está bloqueado.", "warning");
      updateSystemModuleControls();
    }
    return;
  }

  if (nextModule === activeSystemModule) {
    updateSystemModuleControls();
    return;
  }

  if (nextModule === "prospections" && !window.ProspectionsModule?.activate) {
    showAppNotification("O módulo de Prospecções não foi carregado. Atualize a página.", "error");
    return;
  }

  if (nextModule === "whatsapp" && !window.WhatsAppModule?.activate) {
    showAppNotification("O módulo WhatsApp não foi carregado. Atualize a página.", "error");
    return;
  }

  if (nextModule === "attendances" && !window.AttendancesModule?.activate) {
    showAppNotification("O módulo de Atendimentos não foi carregado. Atualize a página.", "error");
    return;
  }

  if (activeSystemModule === "leads" && nextModule !== "leads") {
    leadModuleSnapshot = captureLeadModuleSnapshot();
  }

  window.ProspectionsModule?.deactivate?.();
  window.WhatsAppModule?.deactivate?.();
  window.AttendancesModule?.deactivate?.();
  prospectionView.hidden = true;
  whatsappView.hidden = true;
  attendanceView.hidden = true;
  setProspectionVisualMode(false);
  setWhatsAppVisualMode(false);
  setAttendanceVisualMode(false);

  if (nextModule === "prospections") {
    setProspectionVisualMode(true, false);
    activeSystemModule = "prospections";
    updateSystemModuleControls();
    appMainTitle.textContent = "Controle de Prospecções";
    adminView.hidden = true;
    storeView.hidden = true;
    prospectionView.hidden = false;
    appointmentMonitorToggle.hidden = true;
    appointmentMonitorPanel.hidden = true;
    backAdminButton.hidden = true;
    settingsButton.hidden = true;
    closeAiChat();

    try {
      await window.ProspectionsModule.activate({
        profile: { ...currentProfile },
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        prospectionAccessGranted: canUseProspections(),
        initialStoreId: activeStoreContext?.id || currentProfile.storeId || "",
        initialAgencyId: activeTechnicianContext?.id || (currentProfile.role === "technician" ? currentProfile.id : ""),
        rpc: authenticatedRpc,
        notify: showAppNotification,
        setOperationMode: (isOperation) => setProspectionVisualMode(true, Boolean(isOperation)),
        openLeadsForStore: async (storeId) => {
          await setSystemModule("leads");
          if (["admin", "technician"].includes(currentProfile?.role) && storeId) {
            await openStoreAsAdmin(storeId);
          }
        },
        openStoreAccess: (storeId) => openManagedAccountModal("store", storeId),
      });
      renderCurrentSessionAvatar();
    } catch (error) {
      window.ProspectionsModule?.renderFatalError?.(readableError(error));
      showAppNotification(readableError(error), "error");
    }
  } else if (nextModule === "whatsapp") {
    setWhatsAppVisualMode(true);
    activeSystemModule = "whatsapp";
    updateSystemModuleControls();
    appMainTitle.textContent = "WhatsApp Business";
    adminView.hidden = true;
    storeView.hidden = true;
    whatsappView.hidden = false;
    appointmentMonitorToggle.hidden = true;
    appointmentMonitorPanel.hidden = true;
    backAdminButton.hidden = true;
    settingsButton.hidden = true;
    closeAiChat();

    try {
      await window.WhatsAppModule.activate({
        profile: { ...currentProfile },
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        whatsappAccessGranted: canUseWhatsApp(),
        initialStoreId: activeStoreContext?.id || currentProfile.storeId || "",
        initialAgencyId: activeTechnicianContext?.id || (currentProfile.role === "technician" ? currentProfile.id : ""),
        rpc: authenticatedRpc,
        edge: callWhatsAppEdge,
        upload: callWhatsAppUpload,
        download: callWhatsAppDownload,
        notify: showAppNotification,
        supabaseUrl: SUPABASE_URL,
        onAccessRevoked: (storeId) => {
          const store = stores.find((item) => item.id === storeId);
          if (store) store.whatsappEnabled = false;
          if (currentProfile.role === "store" && currentProfile.storeId === storeId) currentProfile.whatsappEnabled = false;
          if (activeStoreContext?.id === storeId) activeStoreContext.whatsappEnabled = false;
          updateSystemModuleControls();
        },
        openLeadsForStore: async (storeId) => {
          await setSystemModule("leads");
          if (["admin", "technician"].includes(currentProfile?.role) && storeId) {
            await openStoreAsAdmin(storeId);
          }
        },
      });
      renderCurrentSessionAvatar();
    } catch (error) {
      window.WhatsAppModule?.renderFatalError?.(readableError(error));
      showAppNotification(readableError(error), "error");
    }
  } else if (nextModule === "attendances") {
    setAttendanceVisualMode(true);
    activeSystemModule = "attendances";
    updateSystemModuleControls();
    appMainTitle.textContent = "Atendimentos";
    adminView.hidden = true;
    storeView.hidden = true;
    attendanceView.hidden = false;
    appointmentMonitorToggle.hidden = true;
    appointmentMonitorPanel.hidden = true;
    backAdminButton.hidden = true;
    settingsButton.hidden = true;
    closeAiChat();

    try {
      await window.AttendancesModule.activate({
        profile: { ...currentProfile },
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        prospectionAccessGranted: canUseProspections(),
        initialStoreId: attendanceStoreSelectionId || activeStoreContext?.id || currentProfile.storeId || "",
        initialAgencyId: activeTechnicianContext?.id || (currentProfile.role === "technician" ? currentProfile.id : ""),
        rpc: authenticatedRpc,
        notify: showAppNotification,
        onAccessRevoked: (storeId) => {
          const store = stores.find((item) => item.id === storeId);
          if (store) store.prospectionEnabled = false;
          if (currentProfile.role === "store" && currentProfile.storeId === storeId) currentProfile.prospectionEnabled = false;
          if (activeStoreContext?.id === storeId) activeStoreContext.prospectionEnabled = false;
          updateSystemModuleControls();
        },
        onStoreSelected: (storeId) => {
          attendanceStoreSelectionId = storeId || "";
        },
        afterSave: async () => {
          await refreshRemoteState();
          if (activeSystemModule === "leads") {
            renderAll();
            return;
          }
          if (activeSystemModule !== "attendances") return;
          renderAll();
          adminView.hidden = true;
          storeView.hidden = true;
          attendanceView.hidden = false;
          appointmentMonitorToggle.hidden = true;
          appointmentMonitorPanel.hidden = true;
          backAdminButton.hidden = true;
          settingsButton.hidden = true;
        },
        openLeadsForStore: async (storeId) => {
          await setSystemModule("leads");
          if (["admin", "technician"].includes(currentProfile?.role) && storeId) {
            await openStoreAsAdmin(storeId);
          }
        },
      });
      renderCurrentSessionAvatar();
    } catch (error) {
      window.AttendancesModule?.renderFatalError?.(readableError(error));
      showAppNotification(readableError(error), "error");
    }
  } else {
    activeSystemModule = "leads";
    updateSystemModuleControls();
    appMainTitle.textContent = "Controle de Leads";
    restoreLeadModuleSnapshot();
    leadModuleSnapshot = null;
    renderCurrentSessionAvatar();
  }

  if (persist) localStorage.setItem(getSystemModuleStorageKey(), activeSystemModule);
}

async function callWhatsAppEdge(action, payload = {}) {
  if (!currentProfile?.sessionToken) throw new Error("Sessão inválida. Entre novamente.");
  const response = await fetchWhatsAppWithTimeout(`${SUPABASE_URL}/functions/v1/whatsapp-api`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      "x-app-session": currentProfile.sessionToken,
    },
    body: JSON.stringify({ action, ...payload }),
  }, 45000);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const payloadError = data?.error && typeof data.error === "object" ? data.error : {};
    const error = new Error(payloadError.message || data?.error || data?.message || `Falha no serviço WhatsApp (${response.status}).`);
    error.code = payloadError.code || data?.code || `HTTP_${response.status}`;
    error.details = payloadError.details || data?.details || null;
    error.retryable = payloadError.retryable === true;
    error.correlationId = data?.correlation_id || response.headers.get("x-correlation-id") || "";
    throw error;
  }
  return data;
}

async function callMarketingEdge(action, payload = {}) {
  if (!currentProfile?.sessionToken) throw new Error("Sessão inválida. Entre novamente.");
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), action === "sync-now" ? 120000 : 45000);
  let response;
  try {
    response = await fetch(`${SUPABASE_URL}/functions/v1/marketing-api`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        "x-app-session": currentProfile.sessionToken,
      },
      body: JSON.stringify({ action, ...payload }),
      signal: controller.signal,
    });
  } catch (error) {
    if (error?.name === "AbortError") {
      const timeoutError = new Error("A integração de marketing demorou demais para responder. Tente novamente.");
      timeoutError.code = "MARKETING_TIMEOUT";
      throw timeoutError;
    }
    throw error;
  } finally {
    window.clearTimeout(timeout);
  }

  const data = await response.json().catch(() => ({}));
  if (!response.ok || data?.ok === false) {
    const payloadError = data?.error && typeof data.error === "object" ? data.error : {};
    const requestError = new Error(
      payloadError.message || data?.error || data?.message || `Falha no serviço de marketing (${response.status}).`,
    );
    requestError.code = payloadError.code || data?.code || `HTTP_${response.status}`;
    requestError.details = payloadError.details || data?.details || null;
    requestError.correlationId = data?.correlation_id || response.headers.get("x-correlation-id") || "";
    throw requestError;
  }
  return data;
}

async function callWhatsAppUpload({ connectionId, file }) {
  if (!currentProfile?.sessionToken) throw new Error("Sessão inválida. Entre novamente.");
  if (!connectionId) throw new Error("Selecione uma conexão do WhatsApp antes de anexar arquivos.");
  if (!(file instanceof File)) throw new Error("Selecione um arquivo válido.");
  const body = new FormData();
  body.set("action", "upload-media");
  body.set("connection_id", connectionId);
  body.set("file", file, file.name);
  const response = await fetchWhatsAppWithTimeout(`${SUPABASE_URL}/functions/v1/whatsapp-api`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      "x-app-session": currentProfile.sessionToken,
    },
    body,
  }, 120000);
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data?.ok === false) {
    const payloadError = data?.error && typeof data.error === "object" ? data.error : {};
    const error = new Error(payloadError.message || data?.message || `Falha ao enviar mídia (${response.status}).`);
    error.code = payloadError.code || `HTTP_${response.status}`;
    error.details = payloadError.details || null;
    error.retryable = payloadError.retryable === true;
    error.correlationId = data?.correlation_id || response.headers.get("x-correlation-id") || "";
    throw error;
  }
  return data;
}

async function callWhatsAppDownload({ attachmentId }) {
  if (!currentProfile?.sessionToken) throw new Error("Sessão inválida. Entre novamente.");
  if (!attachmentId) throw new Error("Anexo inválido.");
  const response = await fetchWhatsAppWithTimeout(`${SUPABASE_URL}/functions/v1/whatsapp-api`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      "x-app-session": currentProfile.sessionToken,
    },
    body: JSON.stringify({ action: "download-media", attachment_id: attachmentId }),
  }, 120000);
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    const payloadError = data?.error && typeof data.error === "object" ? data.error : {};
    const error = new Error(payloadError.message || data?.message || `Falha ao baixar mídia (${response.status}).`);
    error.code = payloadError.code || `HTTP_${response.status}`;
    error.details = payloadError.details || null;
    error.retryable = payloadError.retryable === true;
    error.correlationId = data?.correlation_id || response.headers.get("x-correlation-id") || "";
    throw error;
  }
  const disposition = response.headers.get("content-disposition") || "";
  const filename = disposition.match(/filename="?([^";]+)"?/i)?.[1] || `midia-whatsapp-${attachmentId}`;
  return {
    blob: await response.blob(),
    filename,
    mimeType: response.headers.get("content-type") || "application/octet-stream",
  };
}

async function fetchWhatsAppWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (error) {
    if (error?.name === "AbortError") {
      const timeoutError = new Error("A integração do WhatsApp demorou demais para responder. Tente novamente.");
      timeoutError.code = "WHATSAPP_TIMEOUT";
      timeoutError.retryable = true;
      throw timeoutError;
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function handleCreateStore(event) {
  event.preventDefault();
  clearStoreMessage();

  if (!currentProfile || !["admin", "technician"].includes(currentProfile.role)) return;

  const username = normalizeNick(storeNick.value);
  if (!username) {
    showStoreMessage("Digite um nick válido para a loja.");
    return;
  }

  const technicianId = getStoreCreationTechnicianId();
  if (!technicianId) {
    showStoreMessage("Selecione a agência responsável por este cliente.");
    return;
  }

  try {
    setFormBusy(storeForm, true);
    const avatarUrl = await avatarFileToDataUrl(storeAvatar.files?.[0]);
    const createdStore = firstRow(await authenticatedRpc("lc_create_store", {
      p_name: storeName.value.trim(),
      p_nick: username,
      p_password: storePassword.value,
      p_technician_id: technicianId,
    }));
    if (avatarUrl && createdStore?.store_id) {
      await authenticatedRpc("lc_set_profile_avatar", {
        p_account_type: "store",
        p_account_id: createdStore.store_id,
        p_avatar_url: avatarUrl,
      });
    }
    storeForm.reset();
    setAvatarPreview(storeAvatarPreview, "", "store");
    setAvatarFileName(storeAvatar);
    await refreshRemoteState();
    showStoreMessage("Loja criada.", "success");
    renderAll();
  } catch (error) {
    showStoreMessage(readableError(error));
  } finally {
    setFormBusy(storeForm, false);
    syncStoreCreationAvailability();
  }
}

async function handleCreateTechnician(event) {
  event.preventDefault();
  clearTechnicianMessage();

  if (!currentProfile || currentProfile.role !== "admin") return;

  const username = normalizeNick(technicianNick.value);
  const storeLimit = Number.parseInt(technicianStoreLimit.value, 10);
  const prospectionLimit = Number.parseInt(technicianProspectionLimit.value, 10);
  const whatsappLimit = Number.parseInt(technicianWhatsappLimit.value, 10);
  if (!username) {
    showTechnicianMessage("Digite um login válido para a agência.");
    return;
  }

  if (!Number.isInteger(storeLimit) || storeLimit < 0) {
    showTechnicianMessage("Informe um limite de clientes válido.");
    return;
  }

  if (!Number.isInteger(prospectionLimit) || prospectionLimit < 0 || prospectionLimit > storeLimit) {
    showTechnicianMessage("A franquia de Prospecções deve ficar entre zero e o limite total de clientes.");
    return;
  }

  if (!Number.isInteger(whatsappLimit) || whatsappLimit < 0 || whatsappLimit > storeLimit) {
    showTechnicianMessage("A franquia de WhatsApp deve ficar entre zero e o limite total de clientes.");
    return;
  }

  if (!isValidWhatsAppNumber(technicianWhatsapp.value)) {
    showTechnicianMessage("Informe um WhatsApp comercial válido com DDD.");
    technicianWhatsapp.focus();
    return;
  }

  try {
    setFormBusy(technicianForm, true);
    const avatarUrl = await avatarFileToDataUrl(technicianAvatar.files?.[0]);
    const createdTechnician = firstRow(await authenticatedRpc("lc_create_technician_with_feature_plan", {
      p_full_name: technicianName.value.trim(),
      p_nick: username,
      p_password: technicianPassword.value,
      p_store_limit: storeLimit,
      p_whatsapp: technicianWhatsapp.value,
      p_prospection_limit: prospectionLimit,
      p_whatsapp_limit: whatsappLimit,
    }));
    if (avatarUrl && createdTechnician?.id) {
      await authenticatedRpc("lc_set_profile_avatar", {
        p_account_type: "technician",
        p_account_id: createdTechnician.id,
        p_avatar_url: avatarUrl,
      });
    }
    technicianForm.reset();
    setAvatarPreview(technicianAvatarPreview, "", "building");
    setAvatarFileName(technicianAvatar);
    await refreshRemoteState();
    technicianStoreLimit.value = "5";
    technicianProspectionLimit.value = "0";
    technicianWhatsappLimit.value = "0";
    showTechnicianMessage("Agência criada.", "success");
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
  renderAdminAiSettingsForm();
  showAdminAiSettingsMessage("");
  settingsModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => adminAccountNick.focus());
}

function closeSettingsModal() {
  if (!settingsModal || settingsModal.hidden) return;
  settingsModal.hidden = true;
  adminCurrentPassword.value = "";
  adminNewPassword.value = "";
  adminAiApiKey.value = "";
  clearAdminAccountMessage();
  showAdminAiSettingsMessage("");
  syncModalLock();
}

function handleManagementListClick(event) {
  const exportButton = event.target.closest("[data-store-export]");
  if (exportButton) {
    exportManagedStoreLeads(exportButton.dataset.storeExport);
    return;
  }

  const analyzeButton = event.target.closest("[data-store-analyze]");
  if (analyzeButton) {
    analyzeStore(analyzeButton.dataset.storeAnalyze).catch((error) => showAppNotification(readableError(error), "error"));
    return;
  }

  const editButton = event.target.closest("[data-account-edit]");
  if (editButton) {
    openManagedAccountModal(editButton.dataset.accountEdit, editButton.dataset.accountId);
    return;
  }

  const deleteButton = event.target.closest("[data-account-delete]");
  if (deleteButton) {
    confirmDeleteManagedAccount(deleteButton.dataset.accountDelete, deleteButton.dataset.accountId);
    return;
  }

  const technicianButton = event.target.closest("[data-technician-login]");
  if (technicianButton && currentProfile?.role === "admin") {
    guardUnsavedOptions(() => openTechnicianAsAdmin(technicianButton.dataset.technicianLogin));
    return;
  }

  const button = event.target.closest("[data-store-login]");
  if (!button || !["admin", "technician"].includes(currentProfile?.role)) return;
  guardUnsavedOptions(() => openStoreAsAdmin(button.dataset.storeLogin).catch((error) => showAppNotification(readableError(error), "error")));
}

function confirmDeleteManagedAccount(type, id) {
  const isStore = type === "store";
  const canDelete = isStore ? canManageStoreAccount(id) : currentProfile?.role === "admin";
  if (!canDelete) return;
  const record = isStore
    ? stores.find((store) => store.id === id)
    : technicians.find((technician) => technician.id === id);
  if (!record) return;

  const name = isStore ? record.name : record.fullName || record.username;
  openConfirmModal({
    eyebrow: isStore ? "Excluir cliente" : "Excluir agência",
    title: `Excluir ${name}?`,
    message: isStore
      ? "O acesso será desativado e o cliente sairá da carteira. Os dados históricos serão preservados no banco."
      : "A agência só poderá ser excluída depois que todos os clientes ativos forem removidos ou transferidos.",
    confirmText: "Excluir",
    action: () => deleteManagedAccount(type, id),
  });
}

async function deleteManagedAccount(type, id) {
  try {
    if (type === "store") {
      await authenticatedRpc("lc_delete_store_account", { p_store_id: id });
    } else {
      await authenticatedRpc("lc_delete_agency_account", { p_agency_id: id });
    }
    await refreshRemoteState();
    if (activeSystemModule === "prospections") {
      await window.ProspectionsModule?.refreshContext?.({
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        prospectionAccessGranted: canUseProspections(),
      });
    } else if (activeSystemModule === "whatsapp") {
      await window.WhatsAppModule?.refreshContext?.({
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        whatsappAccessGranted: canUseWhatsApp(),
      });
    } else if (activeSystemModule === "attendances") {
      await window.AttendancesModule?.refreshContext?.({
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        prospectionAccessGranted: canUseProspections(),
      });
    }
    renderAll();
    showAppNotification(type === "store" ? "Cliente excluído" : "Agência excluída");
  } catch (error) {
    showAppNotification(readableError(error), "error");
  }
}

function openManagedAccountModal(type, id) {
  const canManageTechnician = type === "technician" && currentProfile?.role === "admin";
  const canManageStore = type === "store" && canManageStoreAccount(id);
  if (!canManageTechnician && !canManageStore) return;

  const record = type === "store"
    ? stores.find((store) => store.id === id)
    : technicians.find((technician) => technician.id === id);
  if (!record) return;

  managedAccountType.value = type;
  managedAccountId.value = id;
  managedAccountTitle.textContent = type === "store" ? "Editar cliente" : "Editar agência";
  managedAccountNameLabel.textContent = type === "store" ? "Nome do cliente" : "Nome da agência";
  managedAccountName.value = type === "store" ? record.name : record.fullName || record.username;
  managedAccountWhatsappField.hidden = type !== "technician";
  managedAccountWhatsapp.required = type === "technician";
  managedAccountWhatsapp.value = type === "technician" ? formatWhatsAppInput(record.whatsappPhone || "") : "";
  const canAssignCompany = type === "store" && currentProfile?.role === "admin";
  managedAccountTechnicianField.hidden = !canAssignCompany;
  managedAccountTechnician.required = canAssignCompany;
  managedAccountTechnician.innerHTML = canAssignCompany
    ? '<option value="">Selecione a agência</option>' + technicians
        .map((technician) => `<option value="${technician.id}">${escapeHtml(technician.fullName || technician.username)} · ${technician.storeCount}/${technician.storeLimit}</option>`)
        .join("")
    : "";
  if (canAssignCompany) managedAccountTechnician.value = record.technicianId || "";
  managedAccountCurrentAvatar = record.avatarUrl || "";
  managedAccountAvatar.value = "";
  setAvatarFileName(managedAccountAvatar);
  setAvatarPreview(managedAccountAvatarPreview, managedAccountCurrentAvatar, type === "store" ? "store" : "building");
  managedAccountNick.value = record.username || "";
  managedAccountPassword.value = "";
  managedAccountLimitField.hidden = type !== "technician";
  managedAccountLimit.required = type === "technician";
  managedAccountLimit.value = type === "technician" ? String(record.storeLimit ?? 0) : "";
  managedAccountProspectionLimitField.hidden = type !== "technician";
  managedAccountProspectionLimit.required = type === "technician";
  managedAccountProspectionLimit.value = type === "technician" ? String(record.prospectionStoreLimit ?? 0) : "";
  if (type === "technician" && managedAccountProspectionLimitHelp) {
    const activeAccesses = record.prospectionStoreCount ?? 0;
    managedAccountProspectionLimitHelp.textContent = activeAccesses > 0
      ? `${activeAccesses} cliente${activeAccesses === 1 ? " está" : "s estão"} com acesso. Se o novo limite for menor, a agência escolherá quais clientes desativar.`
      : "Defina quantos clientes desta agência podem usar Prospecções.";
  }
  managedAccountWhatsappLimitField.hidden = type !== "technician";
  managedAccountWhatsappLimit.required = type === "technician";
  managedAccountWhatsappLimit.value = type === "technician" ? String(record.whatsappStoreLimit ?? 0) : "";
  if (type === "technician" && managedAccountWhatsappLimitHelp) {
    const activeAccesses = record.whatsappStoreCount ?? 0;
    managedAccountWhatsappLimitHelp.textContent = activeAccesses > 0
      ? `${activeAccesses} cliente${activeAccesses === 1 ? " está" : "s estão"} com WhatsApp. Reduzir a cota bloqueia novas ativações até a agência ajustar os acessos.`
      : "Defina quantos clientes desta agência podem usar a API Oficial do WhatsApp.";
  }
  managedAccountProspectionField.hidden = type !== "store";
  managedAccountProspectionAccess.checked = type === "store" && Boolean(record.prospectionEnabled);
  managedAccountWhatsappAccessField.hidden = type !== "store";
  managedAccountWhatsappAccess.checked = type === "store" && Boolean(record.whatsappEnabled);
  syncManagedStoreEntitlementQuotas();
  syncManagedAccountProspectionToggle();
  syncManagedAccountWhatsappToggle();
  clearManagedAccountMessage();
  managedAccountModal.hidden = false;
  syncModalLock();
  requestAnimationFrame(() => managedAccountName.focus());
}

function closeManagedAccountModal() {
  if (!managedAccountModal || managedAccountModal.hidden) return;
  managedAccountModal.hidden = true;
  managedAccountForm.reset();
  managedAccountCurrentAvatar = "";
  setAvatarPreview(managedAccountAvatarPreview, "", "camera");
  setAvatarFileName(managedAccountAvatar);
  managedAccountTechnicianField.hidden = true;
  managedAccountTechnician.required = false;
  managedAccountWhatsappField.hidden = true;
  managedAccountWhatsapp.required = false;
  managedAccountWhatsapp.value = "";
  managedAccountLimitField.hidden = true;
  managedAccountLimit.required = false;
  managedAccountProspectionLimitField.hidden = true;
  managedAccountProspectionLimit.required = false;
  managedAccountWhatsappLimitField.hidden = true;
  managedAccountWhatsappLimit.required = false;
  managedAccountProspectionField.hidden = true;
  managedAccountProspectionAccess.checked = false;
  managedAccountProspectionAccess.disabled = false;
  delete managedAccountProspectionAccess.dataset.quotaLocked;
  delete managedAccountProspectionAccess.dataset.transferBlocked;
  managedAccountWhatsappAccessField.hidden = true;
  managedAccountWhatsappAccess.checked = false;
  managedAccountWhatsappAccess.disabled = false;
  delete managedAccountWhatsappAccess.dataset.quotaLocked;
  delete managedAccountWhatsappAccess.dataset.transferBlocked;
  syncManagedAccountProspectionToggle();
  syncManagedAccountWhatsappToggle();
  clearManagedAccountMessage();
  syncModalLock();
}

async function handleManagedAccountSubmit(event) {
  event.preventDefault();
  clearManagedAccountMessage();

  const type = managedAccountType.value;
  const id = managedAccountId.value;
  const canManageTechnician = type === "technician" && currentProfile?.role === "admin";
  const canManageStore = type === "store" && canManageStoreAccount(id);
  if (!canManageTechnician && !canManageStore) return;

  const username = normalizeNick(managedAccountNick.value);
  const password = managedAccountPassword.value;
  const storeLimit = Number.parseInt(managedAccountLimit.value, 10);
  const prospectionLimit = Number.parseInt(managedAccountProspectionLimit.value, 10);
  const whatsappLimit = Number.parseInt(managedAccountWhatsappLimit.value, 10);

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

  if (type === "store" && currentProfile?.role === "admin" && !managedAccountTechnician.value) {
    showManagedAccountMessage("Selecione a agência responsável pelo cliente.");
    return;
  }

  if (type === "technician" && (!Number.isInteger(storeLimit) || storeLimit < 0)) {
    showManagedAccountMessage("Informe um limite de clientes válido.");
    return;
  }

  if (type === "technician" && (!Number.isInteger(prospectionLimit) || prospectionLimit < 0 || prospectionLimit > storeLimit)) {
    showManagedAccountMessage("A franquia de Prospecções deve ficar entre zero e o limite total de clientes.");
    return;
  }

  if (type === "technician" && (!Number.isInteger(whatsappLimit) || whatsappLimit < 0 || whatsappLimit > storeLimit)) {
    showManagedAccountMessage("A franquia de WhatsApp deve ficar entre zero e o limite total de clientes.");
    return;
  }

  if (type === "technician" && !isValidWhatsAppNumber(managedAccountWhatsapp.value)) {
    showManagedAccountMessage("Informe um WhatsApp comercial válido com DDD.");
    managedAccountWhatsapp.focus();
    return;
  }

  if (type === "store") {
    const blockedFeatures = [
      managedAccountProspectionAccess.checked && managedAccountProspectionAccess.dataset.transferBlocked === "true" ? "Prospecções + Atendimentos" : "",
      managedAccountWhatsappAccess.checked && managedAccountWhatsappAccess.dataset.transferBlocked === "true" ? "WhatsApp" : "",
    ].filter(Boolean);
    if (blockedFeatures.length) {
      showManagedAccountMessage(`A agência de destino não possui licença disponível para ${blockedFeatures.join(" e ")}. Desative o recurso antes de transferir ou escolha outra agência.`);
      return;
    }
  }

  try {
    setFormBusy(managedAccountForm, true);
    const newAvatarUrl = await avatarFileToDataUrl(managedAccountAvatar.files?.[0]);
    if (type === "store") {
      const wantsProspections = managedAccountProspectionAccess.checked;
      const wantsWhatsapp = managedAccountWhatsappAccess.checked;
      await authenticatedRpc("lc_update_store_with_feature_access", {
        p_store_id: id,
        p_name: managedAccountName.value.trim(),
        p_nick: username,
        p_password: password || null,
        p_technician_id: currentProfile.role === "technician" ? currentProfile.id : managedAccountTechnician.value,
        p_prospection_enabled: wantsProspections,
        p_whatsapp_enabled: wantsWhatsapp,
      });
    } else if (type === "technician") {
      await authenticatedRpc("lc_update_technician_with_feature_plan", {
        p_technician_id: id,
        p_full_name: managedAccountName.value.trim(),
        p_nick: username,
        p_password: password || null,
        p_store_limit: storeLimit,
        p_whatsapp: managedAccountWhatsapp.value,
        p_prospection_limit: prospectionLimit,
        p_whatsapp_limit: whatsappLimit,
      });
    }

    if (newAvatarUrl) {
      await authenticatedRpc("lc_set_profile_avatar", {
        p_account_type: type,
        p_account_id: id,
        p_avatar_url: newAvatarUrl,
      });
    }

    await refreshRemoteState();
    if (activeSystemModule === "prospections") {
      await window.ProspectionsModule?.refreshContext?.({
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        prospectionAccessGranted: canUseProspections(),
      });
    } else if (activeSystemModule === "whatsapp") {
      await window.WhatsAppModule?.refreshContext?.({
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        whatsappAccessGranted: canUseWhatsApp(),
      });
    } else if (activeSystemModule === "attendances") {
      await window.AttendancesModule?.refreshContext?.({
        stores: stores.map((store) => ({ ...store })),
        agencies: technicians.map((technician) => ({ ...technician })),
        prospectionAccessGranted: canUseProspections(),
      });
    }
    renderAll();
    closeManagedAccountModal();
    showAppNotification("Atualizado");
  } catch (error) {
    if (type === "store") {
      try {
        await refreshRemoteState();
        renderAll();
        syncManagedStoreEntitlementQuotas();
      } catch (refreshError) {
        console.warn("Não foi possível reconciliar o estado do cliente após a falha.", refreshError);
      }
    }
    showManagedAccountMessage(readableError(error));
  } finally {
    setFormBusy(managedAccountForm, false);
    if (!managedAccountModal.hidden && managedAccountType.value === "store") {
      managedAccountProspectionAccess.disabled = managedAccountProspectionAccess.dataset.quotaLocked === "true";
      syncManagedAccountProspectionToggle();
      managedAccountWhatsappAccess.disabled = managedAccountWhatsappAccess.dataset.quotaLocked === "true";
      syncManagedAccountWhatsappToggle();
    }
  }
}

function syncManagedAccountProspectionToggle() {
  if (!managedAccountProspectionStatus) return;
  const enabled = managedAccountProspectionAccess.checked;
  const unavailable = managedAccountProspectionAccess.disabled && !enabled;
  managedAccountProspectionStatus.textContent = unavailable ? "Sem licença" : enabled ? "Ativo" : "Desativado";
  managedAccountProspectionStatus.classList.toggle("is-enabled", enabled);
  managedAccountProspectionStatus.classList.toggle("is-unavailable", unavailable);
}

function syncManagedStoreEntitlementQuotas() {
  if (managedAccountType.value !== "store") return;
  const store = stores.find((item) => item.id === managedAccountId.value);
  if (!store) return;
  const targetAgencyId = currentProfile?.role === "technician"
    ? currentProfile.id
    : managedAccountTechnician.value || store.technicianId;
  const targetAgency = technicians.find((technician) => technician.id === targetAgencyId);
  const isTransfer = Boolean(targetAgencyId && store.technicianId && targetAgencyId !== store.technicianId);

  const syncFeature = ({ control, help, originalEnabled, countKey, limitKey, label }) => {
    const inUse = Number(targetAgency?.[countKey] ?? accountUsage?.[countKey] ?? 0);
    const limit = Number(targetAgency?.[limitKey] ?? accountUsage?.[limitKey] ?? 0);
    const hasExistingReservation = originalEnabled && !isTransfer;
    const hasAvailableLicense = hasExistingReservation || inUse < limit;
    const transferBlocked = control.checked && isTransfer && inUse >= limit;
    const willConsumeLicense = control.checked && (!originalEnabled || isTransfer);
    const projectedUse = inUse + (willConsumeLicense ? 1 : 0);
    const excess = Math.max(0, projectedUse - limit);

    control.disabled = !control.checked && !hasAvailableLicense;
    control.dataset.quotaLocked = String(control.disabled);
    control.dataset.transferBlocked = String(transferBlocked);

    help.textContent = transferBlocked
      ? `A agência de destino já usa ${inUse} de ${limit} licenças ${label}. Desative este recurso antes de transferir ou escolha outra agência.`
      : excess > 0
        ? `${projectedUse} acessos ativos para ${limit} licenças. Desative ${excess} cliente${excess === 1 ? "" : "s"} para regularizar o plano.`
        : !control.checked && !hasAvailableLicense
          ? `${inUse} de ${limit} licenças em uso. Desative outro cliente antes de liberar este acesso.`
          : `${projectedUse} de ${limit} licenças ${label} ficarão em uso${isTransfer ? " na agência de destino" : ""}.`;
  };

  syncFeature({
    control: managedAccountProspectionAccess,
    help: managedAccountProspectionHelp,
    originalEnabled: Boolean(store.prospectionEnabled),
    countKey: "prospectionStoreCount",
    limitKey: "prospectionStoreLimit",
    label: "de Prospecções + Atendimentos",
  });
  syncFeature({
    control: managedAccountWhatsappAccess,
    help: managedAccountWhatsappAccessHelp,
    originalEnabled: Boolean(store.whatsappEnabled),
    countKey: "whatsappStoreCount",
    limitKey: "whatsappStoreLimit",
    label: "de WhatsApp",
  });
}

function syncManagedAccountWhatsappToggle() {
  if (!managedAccountWhatsappAccessStatus) return;
  const enabled = managedAccountWhatsappAccess.checked;
  const unavailable = managedAccountWhatsappAccess.disabled && !enabled;
  managedAccountWhatsappAccessStatus.textContent = unavailable ? "Sem licença" : enabled ? "Ativo" : "Desativado";
  managedAccountWhatsappAccessStatus.classList.toggle("is-enabled", enabled);
  managedAccountWhatsappAccessStatus.classList.toggle("is-unavailable", unavailable);
}

async function openStoreAsAdmin(storeId) {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;
  const store = stores.find((item) => item.id === storeId);
  if (!store || (currentProfile.role === "technician" && store.technicianId !== currentProfile.id)) return;

  activeStoreContext = store;
  sessionRole.textContent = `${currentProfile.role === "technician" ? "Agência" : "Admin"} · ${store.name}`;
  backAdminButton.hidden = false;
  appointmentMonitorToggle.hidden = false;
  toggleOptionsEditButton.hidden = false;
  clearFormButton.hidden = true;
  initializeStoreExportDates();
  adminView.hidden = true;
  storeView.hidden = false;
  await Promise.all([
    refreshStoreConfiguration(store.id),
    refreshMarketingConnections(store.id),
  ]);
  resetLeadForm();
  renderAll();
}

function openTechnicianAsAdmin(technicianId) {
  const technician = technicians.find((item) => item.id === technicianId);
  if (!technician) return;

  activeStoreContext = null;
  activeTechnicianContext = technician;
  companyWorkspaceSection = "clients";
  selectedAnalyticsStoreId = "";
  clientWalletSearch.value = "";
  syncAiChatStoreScope("");
  analyticsStoreFilter.value = "";
  sessionRole.textContent = `Agência · ${technician.fullName || technician.username}`;
  backAdminButton.hidden = false;
  adminView.hidden = false;
  storeView.hidden = true;
  renderAll();
}

async function analyzeStore(storeId) {
  const store = getDashboardStores().find((item) => item.id === storeId);
  if (!store) return;

  selectedAnalyticsStoreId = store.id;
  syncAiChatStoreScope(store.id);
  companyWorkspaceSection = "analytics";
  await Promise.all([
    refreshStoreConfiguration(store.id),
    refreshMarketingConnections(store.id),
  ]);
  renderAll();
  analyticsClientPicker.scrollIntoView({ behavior: "smooth", block: "start" });
  showAppNotification(`Analisando ${store.name}`);
}

function returnToAdmin() {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;
  const wasInsideStore = Boolean(activeStoreContext);
  clearFormButton.hidden = false;
  activeStoreContext = null;
  if (currentProfile.role === "admin" && activeTechnicianContext && !wasInsideStore) {
    activeTechnicianContext = null;
    companyWorkspaceSection = "clients";
    selectedAnalyticsStoreId = "";
    clientWalletSearch.value = "";
    syncAiChatStoreScope("");
    analyticsStoreFilter.value = "";
  }
  appointmentMonitorToggle.hidden = true;
  appointmentMonitorPanel.hidden = true;
  backAdminButton.hidden = currentProfile.role === "technician" || !activeTechnicianContext;
  adminView.hidden = false;
  storeView.hidden = true;
  if (currentProfile.role === "technician") {
    sessionRole.textContent = `Agência · ${currentProfile.fullName || currentProfile.username}`;
  } else if (activeTechnicianContext) {
    sessionRole.textContent = `Agência · ${activeTechnicianContext.fullName || activeTechnicianContext.username}`;
  } else {
    sessionRole.textContent = `Admin · ${currentProfile.fullName || currentProfile.username}`;
  }
  renderAll();
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

  const intelligencePayload = buildLeadIntelligencePayload();
  try {
    setFormBusy(form, true);
    try {
      await authenticatedRpc("lc_upsert_lead_with_intelligence", {
        ...payload,
        p_intelligence: intelligencePayload,
      });
    } catch (error) {
      if (!isMissingRpcError(error)) throw error;
      const savedLeadId = await authenticatedRpc("lc_upsert_lead", payload);
      const leadId = Array.isArray(savedLeadId) ? savedLeadId[0] : savedLeadId;
      if (leadId) {
        await authenticatedRpc("lc_save_lead_intelligence", {
          p_lead_id: leadId,
          p_payload: intelligencePayload,
        }).catch((intelligenceError) => {
          if (!isMissingRpcError(intelligenceError)) throw intelligenceError;
        });
      }
    }
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
  if (leadLifecycleStatus) leadLifecycleStatus.value = lead.lifecycleStatus || inferLeadLifecycleStatus(lead);
  if (leadOwnerName) leadOwnerName.value = lead.ownerName || "";
  formTitle.textContent = "Editar lead";
  submitButton.textContent = "Atualizar lead";
  cancelEditButton.hidden = false;
  updateAppointmentDetailsVisibility();
  updatePurchaseDetailsVisibility();
  syncLeadIntelligenceVisibility();
  renderChoiceButtons();
}

function editLeadFromAppointmentMonitor(lead) {
  if (!lead) return;

  appointmentMonitorPanel.hidden = true;
  appointmentMonitorToggle.setAttribute("aria-expanded", "false");
  clearAppointmentMonitorMessage();
  editLead(lead.id);

  requestAnimationFrame(() => {
    form.scrollIntoView({ behavior: "smooth", block: "start" });
    nameInput.focus({ preventScroll: true });
    nameInput.select();
  });
  showAppNotification(`Editando ${lead.name}.`);
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
  if (leadLifecycleStatus) leadLifecycleStatus.value = "new";
  if (leadOwnerName) leadOwnerName.value = "";
  [
    leadUtmSource,
    leadUtmMedium,
    leadUtmCampaign,
    leadUtmContent,
    leadCampaignExternalId,
    leadAdsetExternalId,
    leadAdExternalId,
    leadGoogleClickId,
    leadMetaClickId,
    leadLandingPage,
  ].filter(Boolean).forEach((input) => { input.value = ""; });
  formTitle.textContent = "Cadastrar lead";
  submitButton.textContent = "Salvar lead";
  cancelEditButton.hidden = true;
  if (!storeOptionsPanel.hidden) toggleStoreOptionsMode(false);
  closeAppointmentModal();
  updatePurchaseDetailsVisibility();
  updateAppointmentDetailsVisibility();
  syncLeadIntelligenceVisibility();
  renderChoiceButtons();
}

async function refreshRemoteState() {
  if (!currentProfile?.sessionToken) return;

  const configurationStoreId = getConfigurationStoreId();

  const technicianRowsRequest = currentProfile.role === "admin"
    ? authenticatedRpc("lc_list_technicians").catch((error) => {
        if (isMissingRpcError(error)) return [];
        throw error;
      })
    : Promise.resolve([]);

  const accountUsageRequest = currentProfile.role === "technician"
    ? authenticatedRpc("lc_account_usage").catch((error) => {
        if (isMissingRpcError(error)) return [];
        throw error;
      })
    : Promise.resolve([]);

  const prospectionEntitlementsRequest = authenticatedRpc("lc_get_prospection_entitlements").catch((error) => {
    if (isMissingRpcError(error)) return null;
    throw error;
  });

  const whatsappEntitlementsRequest = authenticatedRpc("lc_get_whatsapp_entitlements").catch((error) => {
    if (isMissingRpcError(error)) return null;
    throw error;
  });

  const agencyWhatsappRequest = authenticatedRpc("lc_get_agency_whatsapp_context").catch((error) => {
    if (isMissingRpcError(error)) return null;
    throw error;
  });

  const legalAcceptanceRequest = currentProfile.role === "admin"
    ? authenticatedRpc("lc_list_legal_acceptances").catch((error) => {
        if (isMissingRpcError(error)) return null;
        throw error;
      })
    : Promise.resolve(null);

  const optionRowsRequest = configurationStoreId
    ? authenticatedRpc("lc_list_options", { p_store_id: configurationStoreId })
    : Promise.resolve([]);
  const customCategoryRowsRequest = configurationStoreId
    ? authenticatedRpc("lc_list_custom_categories", { p_store_id: configurationStoreId }).catch((error) => {
        if (isMissingRpcError(error)) return [];
        throw error;
      })
    : Promise.resolve([]);
  const categoryLabelRowsRequest = configurationStoreId
    ? authenticatedRpc("lc_list_configuration_labels", { p_store_id: configurationStoreId }).catch((error) => {
        if (isMissingRpcError(error)) return [];
        throw error;
      })
    : Promise.resolve([]);
  const avatarRowsRequest = authenticatedRpc("lc_list_profile_avatars").catch((error) => {
    if (isMissingRpcError(error)) return [];
    throw error;
  });
  const leadIntelligenceRequest = authenticatedRpc("lc_list_lead_intelligence").catch((error) => {
    if (isMissingRpcError(error)) return [];
    throw error;
  });
  const adMetricsRequest = authenticatedRpc("lc_list_ad_daily_metrics").catch((error) => {
    if (isMissingRpcError(error)) return [];
    throw error;
  });
  const marketingTargetsRequest = authenticatedRpc("lc_list_marketing_targets").catch((error) => {
    if (isMissingRpcError(error)) return [];
    throw error;
  });
  const connectionStoreId = configurationStoreId || selectedAnalyticsStoreId;
  const marketingConnectionsRequest = connectionStoreId
    ? authenticatedRpc("lc_list_marketing_connections", { p_store_id: connectionStoreId }).catch((error) => {
        if (isMissingRpcError(error)) return [];
        throw error;
      })
    : Promise.resolve([]);

  const [
    storeRows,
    optionRows,
    customCategoryRows,
    categoryLabelRows,
    leadRows,
    technicianRows,
    usageRows,
    avatarRows,
    intelligenceRows,
    adMetricRows,
    targetRows,
    connectionRows,
    entitlementRows,
    whatsappEntitlementRows,
    agencyWhatsappRows,
    legalAcceptanceRows,
  ] = await Promise.all([
    authenticatedRpc("lc_list_stores"),
    optionRowsRequest,
    customCategoryRowsRequest,
    categoryLabelRowsRequest,
    authenticatedRpc("lc_list_leads"),
    technicianRowsRequest,
    accountUsageRequest,
    avatarRowsRequest,
    leadIntelligenceRequest,
    adMetricsRequest,
    marketingTargetsRequest,
    marketingConnectionsRequest,
    prospectionEntitlementsRequest,
    whatsappEntitlementsRequest,
    agencyWhatsappRequest,
    legalAcceptanceRequest,
  ]);

  stores = (storeRows || []).map(mapStoreRow);
  applyOptionRows(optionRows || []);
  applyCustomCategoryRows(customCategoryRows || []);
  applyCategoryLabelRows(categoryLabelRows || []);
  leadIntelligenceRows = intelligenceRows || [];
  const intelligenceByLeadId = new Map(leadIntelligenceRows.map((row) => [row.lead_id, row]));
  leads = (leadRows || []).map((row) => mapLeadRow(row, intelligenceByLeadId.get(row.id)));
  adDailyMetrics = (adMetricRows || []).map(mapAdDailyMetricRow);
  marketingTargets = (targetRows || []).map(mapMarketingTargetRow);
  marketingConnections = connectionRows || [];
  technicians = (technicianRows || []).map(mapTechnicianRow);
  applyProspectionEntitlements(entitlementRows);
  applyWhatsappEntitlements(whatsappEntitlementRows);
  applyAgencyWhatsappContext(agencyWhatsappRows);
  applyLegalAcceptanceOverview(legalAcceptanceRows);
  profileAvatars = avatarRows || [];
  applyProfileAvatars();
  accountUsage = currentProfile.role === "technician" ? mapAccountUsage(firstRow(usageRows)) : null;
  if (accountUsage) {
    const entitlementProfile = normalizeProspectionEntitlements(entitlementRows)?.profile || {};
    accountUsage.prospectionStoreLimit = Number(entitlementProfile.prospection_store_limit || 0);
    accountUsage.prospectionStoreCount = Number(entitlementProfile.prospection_store_count || 0);
    const whatsappEntitlementProfile = normalizeWhatsappEntitlements(whatsappEntitlementRows)?.profile || {};
    accountUsage.whatsappStoreLimit = Number(whatsappEntitlementProfile.whatsapp_store_limit || 0);
    accountUsage.whatsappStoreCount = Number(whatsappEntitlementProfile.whatsapp_store_count || 0);
    accountUsage.whatsappPhone = getAgencyWhatsappValue();
  }

  if (currentProfile.role === "store") {
    currentProfile.prospectionEnabled = Boolean(stores.find((store) => store.id === currentProfile.storeId)?.prospectionEnabled);
    currentProfile.whatsappEnabled = Boolean(stores.find((store) => store.id === currentProfile.storeId)?.whatsappEnabled);
  }

  if (selectedAnalyticsStoreId && !getDashboardStores().some((store) => store.id === selectedAnalyticsStoreId)) {
    selectedAnalyticsStoreId = "";
    syncAiChatStoreScope("");
  }

  if (activeStoreContext) {
    activeStoreContext = stores.find((store) => store.id === activeStoreContext.id) || activeStoreContext;
  }
  if (activeTechnicianContext) {
    activeTechnicianContext = technicians.find((technician) => technician.id === activeTechnicianContext.id) || activeTechnicianContext;
  }
}

async function refreshOptions() {
  const storeId = getConfigurationStoreId();
  if (!storeId) return;
  applyOptionRows(await authenticatedRpc("lc_list_options", { p_store_id: storeId }));
  renderAll();
}

async function refreshStoreConfiguration(storeId) {
  if (!storeId) {
    applyOptionRows([]);
    applyCustomCategoryRows([]);
    applyCategoryLabelRows([]);
    return;
  }

  const [optionRows, categoryRows, categoryLabelRows] = await Promise.all([
    authenticatedRpc("lc_list_options", { p_store_id: storeId }),
    authenticatedRpc("lc_list_custom_categories", { p_store_id: storeId }).catch((error) => {
      if (isMissingRpcError(error)) return [];
      throw error;
    }),
    authenticatedRpc("lc_list_configuration_labels", { p_store_id: storeId }).catch((error) => {
      if (isMissingRpcError(error)) return [];
      throw error;
    }),
  ]);
  applyOptionRows(optionRows || []);
  applyCustomCategoryRows(categoryRows || []);
  applyCategoryLabelRows(categoryLabelRows || []);
}

function renderAll() {
  updateSystemModuleControls();
  renderConfiguredCategoryLabels();
  renderChoiceButtons();
  renderCustomChoiceButtons();
  renderFilters();
  renderCustomLeadFilters();
  renderOptionsEditors();
  renderAdminDashboard();
  renderAppointmentMonitor();
  renderLeadList();
  renderTodayCount();
  scheduleLeadWorkspaceSizing();
}

function renderConfiguredCategoryLabels() {
  $$('[data-category-label]').forEach((element) => {
    const label = labels[element.dataset.categoryLabel];
    if (!label) return;
    const icon = element.querySelector("i");
    element.replaceChildren();
    if (icon) element.appendChild(icon);
    element.appendChild(document.createTextNode(label));
  });
}

function renderAdminDashboard() {
  const isRootAdmin = currentProfile?.role === "admin" && !activeTechnicianContext;
  const dashboardStores = getDashboardStores();
  const selectedStore = dashboardStores.find((store) => store.id === selectedAnalyticsStoreId) || null;
  const selectedLeads = selectedStore ? leads.filter((lead) => lead.storeId === selectedStore.id) : [];
  const isAnalytics = companyWorkspaceSection === "analytics";
  const isBackups = companyWorkspaceSection === "backups";
  const isLegal = companyWorkspaceSection === "legal" && isRootAdmin;
  const isClients = companyWorkspaceSection === "clients";

  clientManagementArea.hidden = !isClients;
  backupCenter.hidden = !isBackups;
  legalAdminCenter.hidden = !isLegal;
  legalTermsNavButton.hidden = !isRootAdmin;
  analyticsClientPicker.hidden = !isAnalytics;
  if (!isAnalytics) setAnalyticsClientDropdown(false);
  analyticsSelectionEmpty.hidden = !isAnalytics || Boolean(selectedStore);
  adminAnalyticsSummary.hidden = !isAnalytics || !selectedStore;
  adminAnalyticsPanel.hidden = !isAnalytics || !selectedStore;
  clientCapacityPanel.hidden = !isClients;
  const showAgencyContact = isClients && currentProfile?.role === "technician" && !activeTechnicianContext;
  agencyContactForm.hidden = !showAgencyContact;
  if (showAgencyContact && document.activeElement !== agencyContactWhatsapp) {
    agencyContactWhatsapp.value = formatWhatsAppInput(getAgencyWhatsappValue());
  }
  companyWorkspaceButtons.forEach((button) => {
    button.classList.toggle("is-active", button.dataset.companySection === companyWorkspaceSection);
  });

  storeForm.hidden = !isClients;
  technicianForm.hidden = !isRootAdmin;
  technicianListPanel.hidden = !isRootAdmin;
  settingsButton.hidden = !isRootAdmin;
  storeListPanel.hidden = false;
  totalStoresLabel.textContent = "Cliente";
  totalStoresHint.hidden = false;
  totalStoresHint.textContent = selectedStore ? "análise exclusiva" : "";
  storeListTitle.textContent = "Carteira de clientes";
  $("#totalStores").textContent = selectedStore?.name || "—";
  $("#adminTotalLeads").textContent = selectedLeads.length;
  $("#adminScheduledCount").textContent = countByValue(selectedLeads, "scheduled", "Sim");
  $("#adminSalesCount").textContent = countByValue(selectedLeads, "bought", "Sim");
  $("#adminConversionRate").textContent = formatPercent(countByValue(selectedLeads, "bought", "Sim"), selectedLeads.length);
  if (!isAnalytics) renderClientCapacity();
  renderStoreCreationContext();
  renderStoreList();
  renderTechnicianList();
  renderAnalyticsClientPicker(selectedStore);
  renderAnalyticsFilters();
  renderAdminAnalytics();
  renderBackupCenter();
  if (isLegal) renderLegalAdminCenter();
  renderCurrentSessionAvatar();
}

function setCompanyWorkspaceSection(section) {
  if (!["clients", "analytics", "backups", "legal"].includes(section)) return;
  if (section === "legal" && (currentProfile?.role !== "admin" || activeTechnicianContext)) return;
  companyWorkspaceSection = section;
  renderAll();
  if (section === "legal") refreshLegalAcceptanceOverview();
}

async function refreshLegalAcceptanceOverview() {
  try {
    const data = await authenticatedRpc("lc_list_legal_acceptances");
    applyLegalAcceptanceOverview(data);
    if (companyWorkspaceSection === "legal") renderLegalAdminCenter();
  } catch (error) {
    if (!isMissingRpcError(error)) showAppNotification(readableError(error), "error");
  }
}

function applyLegalAcceptanceOverview(data) {
  const value = firstRow(data);
  if (!value || typeof value !== "object") {
    legalAcceptanceOverview = { activeVersion: "", total: 0, accepted: 0, pending: 0, accounts: [] };
    return;
  }
  legalAcceptanceOverview = {
    activeVersion: value.active_version || "",
    total: Number(value.total || 0),
    accepted: Number(value.accepted || 0),
    pending: Number(value.pending || 0),
    accounts: Array.isArray(value.accounts) ? value.accounts : [],
  };
}

function renderLegalAdminCenter() {
  if (!legalAdminCenter || legalAdminCenter.hidden) return;
  legalActiveVersion.textContent = legalAcceptanceOverview.activeVersion
    ? `Versão ${legalAcceptanceOverview.activeVersion}`
    : "Migração pendente";
  legalTotalAccounts.textContent = String(legalAcceptanceOverview.total);
  legalAcceptedAccounts.textContent = String(legalAcceptanceOverview.accepted);
  legalPendingAccounts.textContent = String(legalAcceptanceOverview.pending);
  renderLegalAcceptanceList();
}

function renderLegalAcceptanceList() {
  if (!legalAcceptanceList) return;
  const search = normalizeSearchText(legalAcceptanceSearch?.value || "");
  const role = legalAcceptanceRoleFilter?.value || "all";
  const status = legalAcceptanceStatusFilter?.value || "all";
  const rows = legalAcceptanceOverview.accounts.filter((account) => {
    const matchesSearch = !search || [account.account_name, account.agency_name, account.signer_name, account.login]
      .some((value) => normalizeSearchText(value || "").includes(search));
    const matchesRole = role === "all" || account.account_role === role;
    const matchesStatus = status === "all" || account.status === status;
    return matchesSearch && matchesRole && matchesStatus;
  });

  legalAcceptanceEmpty.hidden = rows.length > 0;
  legalAcceptanceList.innerHTML = rows.map((account) => {
    const isAccepted = account.status === "accepted";
    const isOutdated = account.status === "outdated";
    const statusLabel = isAccepted ? "Assinado" : isOutdated ? "Nova versão pendente" : "Aguardando assinatura";
    const roleLabel = account.account_role === "admin" ? "Admin" : account.account_role === "technician" ? "Agência" : "Cliente";
    return `<article class="legal-acceptance-card is-${escapeHtml(account.status || "pending")}">
      <div class="legal-account-identity">
        <span><i class="fa-solid ${account.account_role === "admin" ? "fa-shield-halved" : account.account_role === "technician" ? "fa-building" : "fa-store"}"></i></span>
        <div><small>${roleLabel}</small><strong>${escapeHtml(account.account_name || "Conta")}</strong><em>@${escapeHtml(account.login || "—")}${account.account_role === "store" && account.agency_name ? ` · ${escapeHtml(account.agency_name)}` : ""}</em></div>
      </div>
      <div class="legal-acceptance-status">
        <span class="legal-status-chip is-${escapeHtml(account.status || "pending")}"><i class="fa-solid ${isAccepted ? "fa-circle-check" : isOutdated ? "fa-rotate" : "fa-clock"}"></i>${statusLabel}</span>
        ${account.accepted_at ? `<strong>${formatDateTime(account.accepted_at)}</strong><small>Versão ${escapeHtml(account.terms_version || "—")} · CPF final ${escapeHtml(account.signer_cpf_last4 || "—")}</small>` : `<strong>Primeiro acesso pendente</strong><small>O sistema bloqueará o uso até o aceite.</small>`}
      </div>
      <div class="legal-acceptance-signer">
        <span>Responsável</span><strong>${escapeHtml(account.signer_name || "Não informado")}</strong><small>${escapeHtml(account.signer_role || "—")}</small>
      </div>
      <button class="secondary-button" type="button" data-legal-acceptance-id="${escapeHtml(account.acceptance_id || "")}"${account.acceptance_id ? "" : " disabled"}>
        <i class="fa-solid fa-file-shield"></i>Ver documento
      </button>
    </article>`;
  }).join("");
}

async function handleLegalAcceptanceListClick(event) {
  const button = event.target.closest("[data-legal-acceptance-id]");
  if (!button?.dataset.legalAcceptanceId) return;
  try {
    button.disabled = true;
    const documentData = firstRow(await authenticatedRpc("lc_get_legal_acceptance_document", {
      p_acceptance_id: button.dataset.legalAcceptanceId,
    }));
    openLegalDocumentModal(documentData);
  } catch (error) {
    showAppNotification(readableError(error), "error");
  } finally {
    button.disabled = false;
  }
}

function openLegalDocumentModal(documentData) {
  if (!documentData) return;
  currentLegalDocument = documentData;
  legalDocumentTitle.textContent = documentData.terms_title || "Termo assinado";
  legalDocumentSubtitle.textContent = `${documentData.account_name || "Conta"} · versão ${documentData.terms_version || "—"}`;
  legalDocumentContent.innerHTML = renderLegalTermsMarkup(documentData.terms_snapshot || "");
  const signatureUrl = String(documentData.signature_data_url || "").startsWith("data:image/png;base64,")
    ? documentData.signature_data_url
    : "";
  legalDocumentEvidence.innerHTML = `<div class="legal-evidence-seal"><i class="fa-solid fa-shield-halved"></i><div><span>Integridade verificada</span><strong>Documento vinculado à sessão autenticada</strong></div></div>
    <dl>
      <div><dt>Conta</dt><dd>${escapeHtml(documentData.account_name || "—")}</dd></div>
      <div><dt>Tipo</dt><dd>${documentData.account_role === "admin" ? "Admin" : documentData.account_role === "technician" ? "Agência" : "Cliente"}</dd></div>
      <div><dt>Agência</dt><dd>${escapeHtml(documentData.agency_name || "—")}</dd></div>
      <div><dt>Responsável</dt><dd>${escapeHtml(documentData.signer_name || "—")}</dd></div>
      <div><dt>Cargo</dt><dd>${escapeHtml(documentData.signer_role || "—")}</dd></div>
      <div><dt>CPF</dt><dd>***.***.***-${escapeHtml(documentData.signer_cpf_last4 || "••••")}</dd></div>
      <div><dt>Aceite</dt><dd>${formatDateTime(documentData.accepted_at)}</dd></div>
      <div><dt>IP registrado</dt><dd>${escapeHtml(documentData.ip_address || "Não disponível")}</dd></div>
    </dl>
    <div class="legal-signature-proof"><span>Assinatura eletrônica</span>${signatureUrl ? `<img src="${signatureUrl}" alt="Assinatura de ${escapeHtml(documentData.signer_name || "responsável")}" />` : "<strong>Imagem indisponível</strong>"}<small>Hash da assinatura · ${escapeHtml(documentData.signature_hash || "—")}</small></div>
    <div class="legal-hash-proof"><span>Hash da evidência</span><code>${escapeHtml(documentData.evidence_hash || "—")}</code></div>`;
  legalDocumentModal.hidden = false;
  syncModalLock();
}

function closeLegalDocumentModal() {
  if (!legalDocumentModal) return;
  legalDocumentModal.hidden = true;
  currentLegalDocument = null;
  legalDocumentContent.innerHTML = "";
  legalDocumentEvidence.innerHTML = "";
  syncModalLock();
}

function downloadCurrentLegalDocument() {
  if (!currentLegalDocument) return;
  const documentData = currentLegalDocument;
  const signatureUrl = String(documentData.signature_data_url || "").startsWith("data:image/png;base64,") ? documentData.signature_data_url : "";
  const html = `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>${escapeHtml(documentData.terms_title || "Termo assinado")}</title><style>body{font:15px/1.6 Arial,sans-serif;color:#182033;max-width:900px;margin:40px auto;padding:0 32px}h1{font-size:28px}h2{font-size:18px;margin-top:28px}p,li{color:#3f4858}.proof{margin-top:36px;padding:24px;border:1px solid #ccd5e2;border-radius:16px}.proof img{display:block;width:320px;max-height:140px;object-fit:contain;border-bottom:1px solid #ccd5e2}.hash{font:11px monospace;overflow-wrap:anywhere;color:#526071}@media print{body{margin:0;max-width:none}}</style></head><body><p>CONTROLE DE LEADS E PROSPECÇÕES · EVIDÊNCIA ELETRÔNICA</p><h1>${escapeHtml(documentData.terms_title || "Termo assinado")}</h1><p>Versão ${escapeHtml(documentData.terms_version || "—")} · aceita em ${escapeHtml(formatDateTime(documentData.accepted_at))}</p>${renderLegalTermsMarkup(documentData.terms_snapshot || "")}<section class="proof"><h2>Comprovante de aceite</h2><p><strong>Conta:</strong> ${escapeHtml(documentData.account_name || "—")}<br><strong>Responsável:</strong> ${escapeHtml(documentData.signer_name || "—")} · ${escapeHtml(documentData.signer_role || "—")}<br><strong>CPF:</strong> ***.***.***-${escapeHtml(documentData.signer_cpf_last4 || "••••")}<br><strong>IP:</strong> ${escapeHtml(documentData.ip_address || "Não disponível")}</p>${signatureUrl ? `<img src="${signatureUrl}" alt="Assinatura eletrônica">` : ""}<p class="hash"><strong>Hash da evidência:</strong> ${escapeHtml(documentData.evidence_hash || "—")}</p><p class="hash"><strong>Hash do documento:</strong> ${escapeHtml(documentData.terms_hash || "—")}</p></section></body></html>`;
  const url = URL.createObjectURL(new Blob([html], { type: "text/html;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = `termo-assinado-${normalizeNick(documentData.account_name || "conta")}-${String(documentData.accepted_at || "").slice(0, 10) || "data"}.html`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
  showAppNotification("Comprovante baixado.");
}

async function handleAnalyticsClientSelection() {
  const storeId = analyticsClientSelector.value;
  selectedAnalyticsStoreId = getDashboardStores().some((store) => store.id === storeId) ? storeId : "";
  syncAiChatStoreScope(selectedAnalyticsStoreId);
  await Promise.all([
    refreshStoreConfiguration(selectedAnalyticsStoreId),
    refreshMarketingConnections(selectedAnalyticsStoreId),
  ]);
  clearAnalyticsFilters();
  renderAll();
}

async function selectAnalyticsClient(storeId) {
  analyticsClientSelector.value = getDashboardStores().some((store) => store.id === storeId) ? storeId : "";
  setAnalyticsClientDropdown(false);
  await handleAnalyticsClientSelection();
}

function setAnalyticsClientDropdown(isOpen, focusTarget = "search") {
  analyticsClientDropdown.hidden = !isOpen;
  analyticsClientSelect.classList.toggle("is-open", isOpen);
  analyticsClientSelectTrigger.setAttribute("aria-expanded", String(isOpen));

  if (!isOpen) {
    analyticsClientSearch.value = "";
    if (focusTarget === "trigger") analyticsClientSelectTrigger.focus();
    return;
  }

  analyticsClientSearch.value = "";
  renderAnalyticsClientOptions();
  requestAnimationFrame(() => {
    if (focusTarget === "option") focusAnalyticsClientOption(0);
    else analyticsClientSearch.focus();
  });
}

function focusAnalyticsClientOption(index) {
  const options = [...analyticsClientOptions.querySelectorAll("[data-analytics-store-id]")];
  if (!options.length) return;
  const safeIndex = Math.max(0, Math.min(index, options.length - 1));
  options[safeIndex].focus();
}

function handleAnalyticsClientOptionsKeydown(event) {
  const options = [...analyticsClientOptions.querySelectorAll("[data-analytics-store-id]")];
  const currentIndex = options.indexOf(document.activeElement);

  if (event.key === "Escape") {
    event.preventDefault();
    setAnalyticsClientDropdown(false, "trigger");
    return;
  }
  if (event.key === "ArrowDown") {
    event.preventDefault();
    focusAnalyticsClientOption(currentIndex >= options.length - 1 ? 0 : currentIndex + 1);
    return;
  }
  if (event.key === "ArrowUp") {
    event.preventDefault();
    focusAnalyticsClientOption(currentIndex <= 0 ? options.length - 1 : currentIndex - 1);
    return;
  }
  if (event.key === "Home") {
    event.preventDefault();
    focusAnalyticsClientOption(0);
    return;
  }
  if (event.key === "End") {
    event.preventDefault();
    focusAnalyticsClientOption(options.length - 1);
  }
}

function renderAnalyticsClientPicker(selectedStore) {
  const dashboardStores = getDashboardStores();
  analyticsClientSelector.innerHTML = '<option value="">Escolha uma loja</option>' + dashboardStores
    .map((store) => `<option value="${store.id}"${store.id === selectedStore?.id ? " selected" : ""}>${escapeHtml(store.name)}</option>`)
    .join("");
  analyticsClientSelector.value = selectedStore?.id || "";
  analyticsClientSelectTrigger.innerHTML = selectedStore
    ? `
        ${renderProfileAvatar(selectedStore.avatarUrl, selectedStore.name, "store")}
        <span class="analytics-client-trigger-copy">
          <strong>${escapeHtml(selectedStore.name)}</strong>
          <small>@${escapeHtml(selectedStore.username)} · ${selectedStore.leadsCount} leads</small>
        </span>
        <i class="fa-solid fa-chevron-down analytics-client-select-chevron" aria-hidden="true"></i>
      `
    : `
        <span class="analytics-client-trigger-placeholder" aria-hidden="true"><i class="fa-solid fa-store"></i></span>
        <span class="analytics-client-trigger-copy">
          <strong>Escolha uma loja</strong>
          <small>Pesquisar na carteira de clientes</small>
        </span>
        <i class="fa-solid fa-chevron-down analytics-client-select-chevron" aria-hidden="true"></i>
      `;
  analyticsClientTitle.textContent = selectedStore?.name || "Selecione uma loja";
  analyticsClientSubtitle.textContent = selectedStore
    ? `@${selectedStore.username} · ${selectedStore.leadsCount} leads cadastrados`
    : "Todos os gráficos serão exclusivos deste cliente.";
  setAvatarPreview(analyticsClientAvatar, selectedStore?.avatarUrl || "", "store");
  renderAnalyticsClientOptions();
}

function renderAnalyticsClientOptions() {
  const search = normalizeSearchText(analyticsClientSearch.value.trim());
  const dashboardStores = getDashboardStores().filter((store) => !search || [store.name, store.username]
    .some((value) => normalizeSearchText(value).includes(search)));

  analyticsClientOptionsEmpty.hidden = dashboardStores.length > 0;
  analyticsClientOptions.innerHTML = dashboardStores
    .map((store) => {
      const isSelected = store.id === selectedAnalyticsStoreId;
      const leadCount = Number(store.leadsCount) || 0;
      return `
        <button
          class="analytics-client-option${isSelected ? " is-selected" : ""}"
          type="button"
          role="option"
          tabindex="-1"
          aria-selected="${String(isSelected)}"
          data-analytics-store-id="${escapeHtml(store.id)}"
        >
          ${renderProfileAvatar(store.avatarUrl, store.name, "store")}
          <span class="analytics-client-option-copy">
            <strong>${escapeHtml(store.name)}</strong>
            <small>@${escapeHtml(store.username)} · ${leadCount} ${leadCount === 1 ? "lead" : "leads"}</small>
          </span>
          ${store.prospectionEnabled ? `<span class="analytics-prospec-badge"><i class="fa-solid fa-phone"></i>PROSPEC</span>` : ""}
          ${store.whatsappEnabled ? `<span class="analytics-prospec-badge is-whatsapp"><i class="fa-brands fa-whatsapp"></i>WHATSAPP</span>` : ""}
          <span class="analytics-client-option-status" aria-hidden="true">
            <i class="fa-solid ${isSelected ? "fa-check" : "fa-chevron-right"}"></i>
          </span>
        </button>
      `;
    })
    .join("");
}

function getDashboardStores() {
  if (activeTechnicianContext) {
    return stores.filter((store) => store.technicianId === activeTechnicianContext.id);
  }
  if (currentProfile?.role === "technician") {
    return stores.filter((store) => store.technicianId === currentProfile.id);
  }
  if (currentProfile?.role === "store") {
    return stores.filter((store) => store.id === currentProfile.storeId);
  }
  return stores;
}

function getDashboardLeads() {
  const storeIds = new Set(getDashboardStores().map((store) => store.id));
  return leads.filter((lead) => storeIds.has(lead.storeId));
}

function getConfigurationStoreId() {
  if (currentProfile?.role === "store") return currentProfile.storeId;
  return activeStoreContext?.id || selectedAnalyticsStoreId || null;
}

function configurationRpcArgs(args = {}) {
  const storeId = getConfigurationStoreId();
  if (!storeId) throw new Error("Selecione uma loja antes de editar as opções.");
  return { ...args, p_store_id: storeId };
}

function getStoreCreationTechnicianId() {
  if (currentProfile?.role === "technician") return currentProfile.id;
  if (activeTechnicianContext) return activeTechnicianContext.id;
  return storeTechnician.value || null;
}

function getSelectedCapacityContext() {
  if (activeTechnicianContext) return activeTechnicianContext;
  if (currentProfile?.role === "technician") {
    return {
      id: currentProfile.id,
      fullName: currentProfile.fullName,
      username: currentProfile.username,
      storeCount: accountUsage?.storeCount ?? stores.length,
      storeLimit: accountUsage?.storeLimit ?? 0,
      prospectionStoreCount: accountUsage?.prospectionStoreCount ?? 0,
      prospectionStoreLimit: accountUsage?.prospectionStoreLimit ?? 0,
      whatsappStoreCount: accountUsage?.whatsappStoreCount ?? 0,
      whatsappStoreLimit: accountUsage?.whatsappStoreLimit ?? 0,
    };
  }
  return technicians.find((technician) => technician.id === storeTechnician.value) || null;
}

function renderClientCapacity() {
  const shouldShow = currentProfile?.role === "technician" || Boolean(activeTechnicianContext);
  clientCapacityPanel.hidden = !shouldShow;
  if (!shouldShow) return;

  const context = getSelectedCapacityContext();
  const count = context?.storeCount ?? getDashboardStores().length;
  const limit = context?.storeLimit ?? 0;
  const remaining = Math.max(limit - count, 0);
  const percent = getCapacityPercent(count, limit);

  clientCapacityEyebrow.textContent = currentProfile?.role === "admin" ? "Capacidade contratada" : "Sua carteira de clientes";
  clientCapacityTitle.textContent = `${count} de ${limit} ${limit === 1 ? "cliente cadastrado" : "clientes cadastrados"}`;
  clientCapacityHint.textContent = count >= limit
    ? "Limite atingido. O administrador precisa ampliar sua capacidade."
    : `${remaining} ${remaining === 1 ? "vaga disponível" : "vagas disponíveis"} para novas lojas.`;
  clientCapacityProgress.style.width = `${percent}%`;
  clientCapacityPercent.textContent = `${percent}%`;
  clientCapacityPanel.classList.toggle("is-full", count >= limit);

  const prospectionCount = Number(context?.prospectionStoreCount ?? accountUsage?.prospectionStoreCount ?? 0);
  const prospectionLimit = Number(context?.prospectionStoreLimit ?? accountUsage?.prospectionStoreLimit ?? 0);
  const whatsappCount = Number(context?.whatsappStoreCount ?? accountUsage?.whatsappStoreCount ?? 0);
  const whatsappLimit = Number(context?.whatsappStoreLimit ?? accountUsage?.whatsappStoreLimit ?? 0);
  featureCapacitySummary.hidden = false;
  prospectionCapacityBadge.innerHTML = `<i class="fa-solid fa-phone" aria-hidden="true"></i><b>${prospectionCount} de ${prospectionLimit}</b> Prospecções + Atendimentos`;
  whatsappCapacityBadge.innerHTML = `<i class="fa-brands fa-whatsapp" aria-hidden="true"></i><b>${whatsappCount} de ${whatsappLimit}</b> WhatsApp`;
  prospectionCapacityBadge.classList.toggle("is-full", prospectionLimit > 0 && prospectionCount >= prospectionLimit);
  whatsappCapacityBadge.classList.toggle("is-full", whatsappLimit > 0 && whatsappCount >= whatsappLimit);
}

function renderStoreCreationContext() {
  const isRootAdmin = currentProfile?.role === "admin" && !activeTechnicianContext;
  const currentSelection = storeTechnician.value;

  storeTechnicianField.hidden = !isRootAdmin;
  storeTechnician.required = isRootAdmin;
  storeFormEyebrow.textContent = isRootAdmin ? "Operação assistida" : "Sua carteira";
  storeFormTitle.textContent = isRootAdmin ? "Criar cliente para agência" : "Criar novo cliente";

  if (isRootAdmin) {
    storeTechnician.innerHTML = '<option value="">Selecione a agência</option>' + technicians
      .map((technician) => `<option value="${technician.id}">${escapeHtml(technician.fullName || technician.username)} · ${technician.storeCount}/${technician.storeLimit}</option>`)
      .join("");
    storeTechnician.value = technicians.some((technician) => technician.id === currentSelection) ? currentSelection : "";
  } else {
    storeTechnician.innerHTML = "";
  }

  syncStoreCreationAvailability();
}

function syncStoreCreationAvailability() {
  const context = getSelectedCapacityContext();
  const submitButton = storeForm.querySelector('button[type="submit"]');
  const hasCapacity = Boolean(context) && context.storeCount < context.storeLimit;

  submitButton.disabled = !hasCapacity;
  if (!context) {
    submitButton.textContent = "Selecione uma agência";
  } else if (!hasCapacity) {
    submitButton.textContent = "Limite de clientes atingido";
  } else {
    submitButton.textContent = "Criar acesso da loja";
  }
}

function getCapacityPercent(count, limit) {
  if (limit <= 0) return count > 0 ? 100 : 0;
  return Math.min(Math.round((count / limit) * 100), 100);
}

function canManageStoreAccount(storeId) {
  if (currentProfile?.role === "admin") return true;
  if (currentProfile?.role !== "technician") return false;
  const store = stores.find((item) => item.id === storeId);
  return Boolean(store && store.technicianId === currentProfile.id);
}

function renderStoreList() {
  if (storeListPanel.hidden) {
    storeEmptyState.hidden = true;
    storeList.innerHTML = "";
    return;
  }

  const allDashboardStores = getDashboardStores();
  const search = normalizeSearchText(clientWalletSearch.value.trim());
  const dashboardStores = search
    ? allDashboardStores.filter((store) => [store.name, store.username, store.technicianName]
        .some((value) => normalizeSearchText(value).includes(search)))
    : allDashboardStores;
  const canEnterStore = ["admin", "technician"].includes(currentProfile?.role);
  clearClientWalletSearch.hidden = !search;
  storeEmptyState.hidden = dashboardStores.length > 0;
  storeEmptyTitle.textContent = search ? "Nenhum cliente encontrado." : "Nenhuma loja cadastrada ainda.";
  storeEmptyText.textContent = search
    ? "Tente buscar por outro nome, login ou agência responsável."
    : "Crie o primeiro acesso para começar a receber leads.";
  storeList.innerHTML = dashboardStores
    .map(
      (store) => `
        <article class="lead-card management-card">
          <div class="management-profile">
            ${renderProfileAvatar(store.avatarUrl, store.name, "store")}
            <div class="management-profile-copy">
            <strong>${escapeHtml(store.name)}</strong>
            <span>${escapeHtml(store.username)}</span>
            ${store.technicianName ? `<small class="management-meta"><i class="fa-solid fa-building" aria-hidden="true"></i>${escapeHtml(store.technicianName)}</small>` : ""}
            <div class="management-stats">
              <span><strong>${store.leadsCount}</strong> leads</span>
              <span><strong>${store.salesCount}</strong> compras</span>
              <span class="feature-plan-badge is-prospection ${store.prospectionEnabled ? "is-enabled" : "is-leads-only"}">
                <i class="fa-solid ${store.prospectionEnabled ? "fa-phone" : "fa-lock"}" aria-hidden="true"></i>
                ${store.prospectionEnabled ? "PROSPEC + ATEND." : "PROSPEC bloqueado"}
              </span>
              <span class="feature-plan-badge is-whatsapp ${store.whatsappEnabled ? "is-enabled" : "is-leads-only"}">
                <i class="fa-brands fa-whatsapp" aria-hidden="true"></i>
                ${store.whatsappEnabled ? "WHATSAPP ativo" : "WHATSAPP bloqueado"}
              </span>
            </div>
            </div>
          </div>
          <div class="card-actions">
            <button class="mini-button client-export-button" type="button" data-store-export="${store.id}">
              <i class="fa-solid fa-file-excel" aria-hidden="true"></i>Exportar dados
            </button>
            <button class="secondary-button" type="button" data-store-analyze="${store.id}">
              <i class="fa-solid fa-chart-line" aria-hidden="true"></i>Analisar
            </button>
            ${canEnterStore ? `<button class="mini-button" type="button" data-store-login="${store.id}">Gerenciar</button>` : ""}
            ${canManageStoreAccount(store.id) ? `<button class="mini-button" type="button" data-account-edit="store" data-account-id="${store.id}">Editar acesso</button>` : ""}
            ${canManageStoreAccount(store.id) ? `<button class="mini-button danger" type="button" data-account-delete="store" data-account-id="${store.id}">Excluir</button>` : ""}
          </div>
        </article>
      `,
    )
    .join("");

}

function renderTechnicianList() {
  if (!technicianList || technicianListPanel.hidden) return;

  technicianEmptyState.hidden = technicians.length > 0;
  technicianList.innerHTML = technicians
    .map((technician) => {
      const prospectionExcess = Math.max(0, technician.prospectionStoreCount - technician.prospectionStoreLimit);
      const whatsappExcess = Math.max(0, technician.whatsappStoreCount - technician.whatsappStoreLimit);
      const hasPlanOverage = prospectionExcess > 0 || whatsappExcess > 0;
      return `
      <article class="lead-card technician-card${hasPlanOverage ? " has-plan-overage" : ""}">
        <div class="management-profile">
          ${renderProfileAvatar(technician.avatarUrl, technician.fullName || technician.username, "building")}
          <div class="technician-card-main">
          <strong>${escapeHtml(technician.fullName || technician.username)}</strong>
          <span>@${escapeHtml(technician.username)}</span>
          <span class="technician-whatsapp-contact"><i class="fa-brands fa-whatsapp" aria-hidden="true"></i>${escapeHtml(formatWhatsAppInput(technician.whatsappPhone) || "WhatsApp pendente")}</span>
          <div class="technician-usage-row">
            <span><i class="fa-solid fa-store" aria-hidden="true"></i>${technician.storeCount} de ${technician.storeLimit} clientes</span>
            <span>${technician.storeLimit > technician.storeCount ? `${technician.storeLimit - technician.storeCount} vagas` : "Limite atingido"}</span>
          </div>
          <div class="technician-usage-track" aria-hidden="true"><i style="width:${getCapacityPercent(technician.storeCount, technician.storeLimit)}%"></i></div>
          <div class="technician-usage-row is-prospection-plan">
            <span><i class="fa-solid fa-phone" aria-hidden="true"></i>${technician.prospectionStoreCount} de ${technician.prospectionStoreLimit} com Prospecções + Atendimentos</span>
            <span class="${prospectionExcess > 0 ? "plan-adjustment" : ""}">${prospectionExcess > 0 ? `${prospectionExcess} acesso${prospectionExcess === 1 ? "" : "s"} para ajustar` : `${technician.prospectionStoreLimit - technician.prospectionStoreCount} licenças livres`}</span>
          </div>
          <div class="technician-usage-track is-prospection-plan" aria-hidden="true"><i style="width:${getCapacityPercent(technician.prospectionStoreCount, technician.prospectionStoreLimit)}%"></i></div>
          <div class="technician-usage-row is-whatsapp-plan">
            <span><i class="fa-brands fa-whatsapp" aria-hidden="true"></i>${technician.whatsappStoreCount} de ${technician.whatsappStoreLimit} com WhatsApp</span>
            <span class="${whatsappExcess > 0 ? "plan-adjustment" : ""}">${whatsappExcess > 0 ? `${whatsappExcess} acesso${whatsappExcess === 1 ? "" : "s"} para ajustar` : `${technician.whatsappStoreLimit - technician.whatsappStoreCount} licenças livres`}</span>
          </div>
          <div class="technician-usage-track is-whatsapp-plan" aria-hidden="true"><i style="width:${getCapacityPercent(technician.whatsappStoreCount, technician.whatsappStoreLimit)}%"></i></div>
          </div>
        </div>
        <div class="card-actions">
          <button class="secondary-button" type="button" data-technician-login="${technician.id}">Acessar</button>
          <button class="mini-button" type="button" data-account-edit="technician" data-account-id="${technician.id}">Editar plano</button>
          <button class="mini-button danger" type="button" data-account-delete="technician" data-account-id="${technician.id}">Excluir</button>
        </div>
      </article>
    `;
    })
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
            ${renderTag(`Etapa: ${formatLifecycleStatus(lead.lifecycleStatus || inferLeadLifecycleStatus(lead))}`)}
            ${renderTag(lead.ownerName ? `Responsável: ${lead.ownerName}` : "")}
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
  renderStoreExportSummary();
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
    guardUnsavedOptions(() => editLeadFromAppointmentMonitor(lead));
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
      <h3>Qualificação comercial</h3>
      <div class="lead-details-grid">
        ${renderLeadDetailItem("Etapa", formatLifecycleStatus(lead.lifecycleStatus || inferLeadLifecycleStatus(lead)))}
        ${renderLeadDetailItem("Responsável", lead.ownerName)}
      </div>
    </div>
    ${(lead.utmSource || lead.utmCampaign || lead.gclid || lead.fbclid || lead.adExternalId) ? `
      <div class="lead-details-section">
        <h3>Atribuição do anúncio</h3>
        <div class="lead-details-grid">
          ${renderLeadDetailItem("UTM source", lead.utmSource)}
          ${renderLeadDetailItem("UTM medium", lead.utmMedium)}
          ${renderLeadDetailItem("UTM campaign", lead.utmCampaign)}
          ${renderLeadDetailItem("UTM content", lead.utmContent)}
          ${renderLeadDetailItem("ID da campanha", lead.campaignExternalId)}
          ${renderLeadDetailItem("ID do anúncio", lead.adExternalId)}
          ${renderLeadDetailItem("Identificador Google", lead.gclid || lead.gbraid || lead.wbraid)}
          ${renderLeadDetailItem("Identificador Meta", lead.fbclid || lead.fbc)}
        </div>
      </div>
    ` : ""}
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

function formatLifecycleStatus(value) {
  return ({
    new: "Novo",
    contacted: "Em atendimento",
    qualified: "Qualificado",
    scheduled: "Agendado",
    visited: "Visitou",
    won: "Ganho",
    lost: "Perdido",
  })[value] || "Novo";
}

function syncModalLock() {
  document.body.classList.toggle("is-modal-open", $$(".modal-backdrop").some((modal) => !modal.hidden));
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
      const sectionTitle = container.closest(".choice-section")?.querySelector(".section-title h3");
      if (sectionTitle) sectionTitle.textContent = labels[group];
      container.innerHTML = options[group].length ? options[group]
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
        .join("") : '<span class="choice-empty-hint">Configure as opções desta loja antes de preencher.</span>';

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
  const selectedStore = getDashboardStores().find((store) => store.id === selectedAnalyticsStoreId);
  analyticsStoreFilter.innerHTML = selectedStore
    ? `<option value="${selectedStore.id}">${escapeHtml(selectedStore.name)}</option>`
    : '<option value="">Selecione um cliente</option>';
  analyticsStoreFilter.value = selectedStore?.id || "";

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
  renderOptionsEditor(storeOptionsList, "store");
}

function renderOrderControls({ action, index, total, label, disabled = false, group = "" }) {
  const groupAttribute = group ? ` data-group="${group}"` : "";
  const isDisabled = disabled || total < 2;
  return `
    <div class="option-order-controls" role="group" aria-label="Ordenar ${escapeHtml(label)}">
      <button class="mini-button option-order-button" type="button" data-option-action="${action}" data-direction="up"${groupAttribute} ${isDisabled || index === 0 ? "disabled" : ""} aria-label="Mover para cima" title="Mover para cima">
        <i class="fa-solid fa-chevron-up" aria-hidden="true"></i>
      </button>
      <button class="mini-button option-order-button" type="button" data-option-action="${action}" data-direction="down"${groupAttribute} ${isDisabled || index === total - 1 ? "disabled" : ""} aria-label="Mover para baixo" title="Mover para baixo">
        <i class="fa-solid fa-chevron-down" aria-hidden="true"></i>
      </button>
    </div>
  `;
}

function renderOptionsEditor(container, scope) {
  const standardGroups = optionGroups
    .map((group) => {
      const isFixed = fixedOptionGroups.has(group);
      const records = optionRecords[group] || [];
      const hasPendingRecord = records.some((record) => record.pending);
      const chips = records
        .map((record, index) =>
          isFixed || record.fixed
            ? `<span class="option-chip fixed-option-chip"><i class="fa-solid fa-lock" aria-hidden="true"></i>${escapeHtml(record.value)}</span>`
            : `<div class="option-row${record.pending ? " is-pending" : ""}" data-group="${group}" data-option-id="${record.id}">
                <span class="option-row-handle" aria-hidden="true"><i class="fa-solid fa-grip-vertical"></i></span>
                <input value="${escapeHtml(dirtyOptionValues.get(record.id) ?? record.value)}" aria-label="${labels[group]}" />
                <div class="option-row-actions">
                  ${renderOrderControls({ action: "move", index, total: records.length, label: record.value || labels[group], disabled: record.pending || hasPendingRecord, group })}
                  <button class="mini-button option-save" type="button" data-option-action="save" ${record.pending || dirtyOptionKeys.has(record.id) ? "" : "hidden"}>Salvar</button>
                  <button class="mini-button danger option-delete-button" type="button" data-option-action="delete" aria-label="Excluir ${escapeHtml(record.value || "opção")}" title="Excluir">
                    <i class="fa-solid fa-trash" aria-hidden="true"></i><span>Excluir</span>
                  </button>
                </div>
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
            <div class="option-group-title">
              <span>Nome da categoria</span>
              <div class="category-label-editor">
                <input value="${escapeHtml(dirtyGroupLabels.get(group) ?? labels[group])}" data-group-label="${group}" aria-label="Nome da categoria ${escapeHtml(labels[group])}" />
                <button class="mini-button option-save" type="button" data-option-action="save-group-label" data-group="${group}" ${dirtyGroupLabels.has(group) ? "" : "hidden"}>Salvar nome</button>
              </div>
            </div>
            ${addButton}
          </div>
          ${isFixed ? '<span class="fixed-category-note"><i class="fa-solid fa-lock" aria-hidden="true"></i>Os valores Sim e Não são protegidos.</span>' : ""}
          <div class="option-list">${chips || '<span class="option-chip">Nenhum card criado</span>'}</div>
        </section>
      `;
    })
    .join("");

  container.innerHTML = standardGroups + renderCustomCategoriesEditor(scope);
}

function renderCustomCategoriesEditor(scope) {
  const hasPendingCategory = customCategories.some((category) => category.pending);
  const categoryCards = customCategories
    .map((category, categoryIndex) => {
      const categoryKey = category.id;
      const categoryName = dirtyOptionValues.get(categoryKey) ?? category.name;
      const hasPendingCustomOption = category.options.some((option) => option.pending);
      const optionRows = category.options
        .map((option, optionIndex) => `
          <div class="option-row custom-option-row${option.pending ? " is-pending" : ""}" data-custom-category-id="${category.id}" data-option-id="${option.id}">
            <span class="option-row-handle" aria-hidden="true"><i class="fa-solid fa-grip-vertical"></i></span>
            <input value="${escapeHtml(dirtyOptionValues.get(option.id) ?? option.value)}" aria-label="${escapeHtml(category.name)}" />
            <div class="option-row-actions">
              ${renderOrderControls({ action: "move-custom-option", index: optionIndex, total: category.options.length, label: option.value || category.name, disabled: option.pending || hasPendingCustomOption })}
              <button class="mini-button option-save" type="button" data-option-action="save-custom-option" ${option.pending || dirtyOptionKeys.has(option.id) ? "" : "hidden"}>Salvar</button>
              <button class="mini-button danger option-delete-button" type="button" data-option-action="delete-custom-option" aria-label="Excluir ${escapeHtml(option.value || "opção")}" title="Excluir">
                <i class="fa-solid fa-trash" aria-hidden="true"></i><span>Excluir</span>
              </button>
            </div>
          </div>
        `)
        .join("");

      return `
        <div class="custom-category-editor${category.pending ? " is-pending" : ""}" data-custom-category-id="${category.id}">
          <div class="custom-category-heading">
            <input value="${escapeHtml(categoryName)}" data-custom-category-name aria-label="Nome da categoria adicional" placeholder="Nome da categoria" />
            ${renderOrderControls({ action: "move-custom-category", index: categoryIndex, total: customCategories.length, label: category.name || "categoria", disabled: category.pending || hasPendingCategory })}
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
  if (event.target.matches("[data-group-label]")) {
    const group = event.target.dataset.groupLabel;
    dirtyGroupLabels.set(group, event.target.value);
    const saveButton = event.target.closest(".category-label-editor")?.querySelector("[data-option-action='save-group-label']");
    if (saveButton) saveButton.hidden = false;
    return;
  }

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

function moveRecord(records, recordId, direction) {
  const currentIndex = records.findIndex((record) => record.id === recordId);
  const targetIndex = direction === "up" ? currentIndex - 1 : currentIndex + 1;
  if (currentIndex < 0 || targetIndex < 0 || targetIndex >= records.length) return false;
  [records[currentIndex], records[targetIndex]] = [records[targetIndex], records[currentIndex]];
  records.forEach((record, index) => {
    record.sortOrder = (index + 1) * 10;
  });
  return true;
}

async function moveStandardOption(group, optionId, direction) {
  const records = optionRecords[group] || [];
  const previousOrder = [...records];
  if (!moveRecord(records, optionId, direction)) return;
  options[group] = records.map((record) => record.value);
  renderAll();
  try {
    await authenticatedRpc("lc_reorder_options", configurationRpcArgs({
      p_group_key: group,
      p_option_ids: records.filter((record) => !record.pending && !record.fixed).map((record) => record.id),
    }));
    showOptionsMessage(storeOptionsMessage, "Ordem dos cards atualizada.", "success");
  } catch (error) {
    optionRecords[group] = previousOrder;
    options[group] = previousOrder.map((record) => record.value);
    renderAll();
    throw error;
  }
}

async function moveCustomCategory(categoryId, direction) {
  const previousOrder = [...customCategories];
  if (!moveRecord(customCategories, categoryId, direction)) return;
  renderAll();
  try {
    await authenticatedRpc("lc_reorder_custom_categories", configurationRpcArgs({
      p_category_ids: customCategories.filter((category) => !category.pending).map((category) => category.id),
    }));
    showOptionsMessage(storeOptionsMessage, "Ordem das categorias atualizada.", "success");
  } catch (error) {
    customCategories = previousOrder;
    renderAll();
    throw error;
  }
}

async function moveCustomOption(categoryId, optionId, direction) {
  const category = getCustomCategory(categoryId);
  if (!category) return;
  const previousOrder = [...category.options];
  if (!moveRecord(category.options, optionId, direction)) return;
  renderAll();
  try {
    await authenticatedRpc("lc_reorder_custom_options", configurationRpcArgs({
      p_category_id: categoryId,
      p_option_ids: category.options.filter((option) => !option.pending).map((option) => option.id),
    }));
    showOptionsMessage(storeOptionsMessage, "Ordem dos cards atualizada.", "success");
  } catch (error) {
    category.options = previousOrder;
    renderAll();
    throw error;
  }
}

async function saveGroupLabel(group, input) {
  const value = input.value.trim();
  if (!value) {
    showOptionsMessage(storeOptionsMessage, "Digite o nome da categoria.");
    input.focus();
    return;
  }
  const duplicate = optionGroups.some((item) => item !== group && labels[item].trim().toLowerCase() === value.toLowerCase());
  if (duplicate) {
    showOptionsMessage(storeOptionsMessage, "Já existe uma categoria com esse nome.");
    input.focus();
    return;
  }
  await authenticatedRpc("lc_update_configuration_label", configurationRpcArgs({ p_group_key: group, p_label: value }));
  labels[group] = value;
  const analyticsSection = analyticsSections.find((section) => section.optionGroup === group);
  if (analyticsSection) analyticsSection.label = value;
  dirtyGroupLabels.delete(group);
  renderAll();
  showOptionsMessage(storeOptionsMessage, "Nome da categoria atualizado.", "success");
}

async function handleOptionsEditorClick(event) {
  const button = event.target.closest("[data-option-action]");
  if (!button) return;

  const action = button.dataset.optionAction;
  const messageTarget = storeOptionsMessage;

  try {
    if (action === "save-group-label") {
      button.disabled = true;
      const input = button.closest(".category-label-editor")?.querySelector("[data-group-label]");
      if (input) await saveGroupLabel(button.dataset.group, input);
      return;
    }

    if (action === "move") {
      button.disabled = true;
      const row = button.closest(".option-row");
      if (row) await moveStandardOption(button.dataset.group || row.dataset.group, row.dataset.optionId, button.dataset.direction);
      return;
    }

    if (action === "move-custom-category") {
      button.disabled = true;
      const editor = button.closest(".custom-category-editor");
      if (editor) await moveCustomCategory(editor.dataset.customCategoryId, button.dataset.direction);
      return;
    }

    if (action === "move-custom-option") {
      button.disabled = true;
      const row = button.closest(".custom-option-row");
      if (row) await moveCustomOption(row.dataset.customCategoryId, row.dataset.optionId, button.dataset.direction);
      return;
    }
  } catch (error) {
    showOptionsMessage(messageTarget, readableError(error));
    return;
  } finally {
    button.disabled = false;
  }

  if (action.includes("custom")) {
    await handleCustomOptionsEditorClick(button);
    return;
  }

  const row = button.closest(".option-row");
  const group = button.dataset.group || row?.dataset.group;

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

      await authenticatedRpc("lc_delete_option", configurationRpcArgs({ p_option_id: row.dataset.optionId }));
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
          p_store_id: getConfigurationStoreId(),
        });
      } else {
        await authenticatedRpc("lc_update_option", {
          p_option_id: row.dataset.optionId,
          p_value: value,
          p_store_id: getConfigurationStoreId(),
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
  const messageTarget = storeOptionsMessage;

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
      await authenticatedRpc("lc_delete_custom_category", configurationRpcArgs({ p_category_id: categoryId }));
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
      await authenticatedRpc("lc_delete_custom_option", configurationRpcArgs({ p_option_id: row.dataset.optionId }));
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
        await authenticatedRpc("lc_add_custom_category", configurationRpcArgs({ p_name: value }));
      } else {
        await authenticatedRpc("lc_update_custom_category", configurationRpcArgs({ p_category_id: categoryId, p_name: value }));
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
        await authenticatedRpc("lc_add_custom_option", configurationRpcArgs({ p_category_id: categoryId, p_value: value }));
      } else {
        await authenticatedRpc("lc_update_custom_option", configurationRpcArgs({ p_option_id: row.dataset.optionId, p_value: value }));
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
  const activeStore = getActiveStore();
  const canManage = Boolean(activeStore) && (
    currentProfile?.role === "admin" ||
    currentProfile?.role === "store" ||
    (currentProfile?.role === "technician" && activeStore.technicianId === currentProfile.id)
  );
  if (shouldOpen && !canManage) {
    showAppNotification("Você não tem permissão para editar esta loja.", "error");
    return;
  }

  storeOptionsPanel.hidden = !shouldOpen;
  if (shouldOpen) {
    storeOptionsTitle.textContent = `Personalizar ${activeStore.name}`;
    storeOptionsSubtitle.textContent = `Categorias, cards e campanhas exclusivos de ${activeStore.name}.`;
    storeOptionsMessage.textContent = "";
    document.body.appendChild(storeOptionsPanel);
    requestAnimationFrame(() => storeOptionsClose.focus());
  }
  syncModalLock();
}

function requestCloseStoreOptions() {
  guardUnsavedOptions(() => toggleStoreOptionsMode(false));
}

function hasUnsavedOptions() {
  return dirtyOptionKeys.size > 0 || dirtyGroupLabels.size > 0;
}

function guardUnsavedOptions(nextAction) {
  if (!hasUnsavedOptions()) {
    nextAction();
    return;
  }

  pendingUnsavedAction = nextAction;
  unsavedOptionsModal.hidden = false;
  syncModalLock();
}

function closeUnsavedOptionsModal() {
  pendingUnsavedAction = null;
  unsavedOptionsModal.hidden = true;
  syncModalLock();
}

function discardUnsavedOptionsAndContinue() {
  clearPendingOptions();
  dirtyOptionKeys.clear();
  dirtyOptionValues.clear();
  dirtyGroupLabels.clear();
  renderOptionsEditors();
  continuePendingAction();
}

async function saveUnsavedOptionsAndContinue() {
  try {
    await saveDirtyOptions();
    continuePendingAction();
  } catch (error) {
    showOptionsMessage(storeOptionsMessage, readableError(error));
  }
}

async function saveDirtyOptions() {
  const nextLabels = { ...labels, ...Object.fromEntries(dirtyGroupLabels) };
  const normalizedLabels = optionGroups.map((group) => String(nextLabels[group] || "").trim().toLowerCase());
  if (normalizedLabels.some((label) => !label)) throw new Error("Digite o nome de todas as categorias.");
  if (new Set(normalizedLabels).size !== normalizedLabels.length) throw new Error("Os nomes das categorias precisam ser diferentes.");

  for (const [group, rawValue] of dirtyGroupLabels) {
    const value = rawValue.trim();
    await authenticatedRpc("lc_update_configuration_label", configurationRpcArgs({ p_group_key: group, p_label: value }));
    labels[group] = value;
  }

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
          p_store_id: getConfigurationStoreId(),
        });
      } else {
        await authenticatedRpc("lc_update_option", {
          p_option_id: optionId,
          p_value: value,
          p_store_id: getConfigurationStoreId(),
        });
      }
    }

    if (record.kind === "custom-category") {
      if (isDuplicateCustomCategoryName(optionId, value)) {
        throw new Error(`A categoria "${value}" já existe.`);
      }
      if (isPendingOption(optionId)) {
        await authenticatedRpc("lc_add_custom_category", configurationRpcArgs({ p_name: value }));
      } else {
        await authenticatedRpc("lc_update_custom_category", {
          p_category_id: optionId,
          p_name: value,
          p_store_id: getConfigurationStoreId(),
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
          p_store_id: getConfigurationStoreId(),
        });
      } else {
        await authenticatedRpc("lc_update_custom_option", {
          p_option_id: optionId,
          p_value: value,
          p_store_id: getConfigurationStoreId(),
        });
      }
    }
  }

  dirtyOptionKeys.clear();
  dirtyOptionValues.clear();
  dirtyGroupLabels.clear();
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
  renderMarketingIntelligence(filtered);

  analyticsSections.forEach((section) => {
    renderAnalyticsCategoryCards(section, filtered);
  });
  renderCustomAnalyticsSections(filtered);
  renderAnalyticsChartsPanel();
  syncAnalyticsViewMode();
  updateAiContextLabel(filtered);
}

function renderMarketingIntelligence(rows) {
  if (!marketingIntelligencePanel || !marketingFunnel) return;

  const total = rows.length;
  const qualified = rows.filter((lead) => lead.qualified || lead.lifecycleStatus === "qualified").length;
  const scheduled = countByValue(rows, "scheduled", "Sim");
  const visited = countByValue(rows, "visited", "Sim");
  const bought = countByValue(rows, "bought", "Sim");
  const revenue = rows.reduce((sum, lead) => sum + (lead.bought === "Sim" ? Number(lead.purchaseAmount || 0) : 0), 0);
  const averageTicket = bought ? revenue / bought : 0;
  const today = toLocalDateInput(new Date());
  const dueAppointments = rows.filter((lead) => (
    lead.scheduled === "Sim" && lead.scheduledVisitDate && lead.scheduledVisitDate <= today
  ));
  const attendedAppointments = dueAppointments.filter((lead) => lead.visited === "Sim").length;
  const showRate = formatPercent(attendedAppointments, dueAppointments.length);
  const closeRate = formatPercent(bought, visited);
  const mediaRows = getFilteredAdMetrics();
  const spend = mediaRows.reduce((sum, metric) => sum + metric.spend, 0);
  const cpl = spend > 0 && total ? spend / total : null;
  const cac = spend > 0 && bought ? spend / bought : null;
  const roas = spend > 0 ? revenue / spend : null;
  const quality = calculateLeadDataQuality(rows);

  const funnelSteps = [
    { label: "Captados", value: total, icon: "fa-users" },
    { label: "Qualificados", value: qualified, icon: "fa-user-check" },
    { label: "Agendados", value: scheduled, icon: "fa-calendar-check" },
    { label: "Visitaram", value: visited, icon: "fa-store" },
    { label: "Compraram", value: bought, icon: "fa-bag-shopping" },
  ];
  marketingFunnel.innerHTML = funnelSteps.map((step, index) => {
    const previous = index ? funnelSteps[index - 1].value : total;
    const rate = index ? formatPercent(step.value, previous) : "100%";
    const width = total ? Math.max((step.value / total) * 100, step.value ? 7 : 0) : 0;
    return `
      <article class="marketing-funnel-step">
        <div class="marketing-funnel-label">
          <span><i class="fa-solid ${step.icon}" aria-hidden="true"></i>${step.label}</span>
          <b>${step.value}</b>
        </div>
        <div class="marketing-funnel-track"><i style="width:${width.toFixed(2)}%"></i></div>
        <small>${index ? `${rate} da etapa anterior` : "Base do período"}</small>
      </article>
    `;
  }).join("");

  $("#analyticsRevenue").textContent = formatCurrency(revenue);
  $("#analyticsAverageTicket").textContent = formatCurrency(averageTicket);
  $("#analyticsShowRate").textContent = showRate;
  $("#analyticsShowRateHint").textContent = dueAppointments.length
    ? `No-show ${formatPercent(dueAppointments.length - attendedAppointments, dueAppointments.length)} · ${attendedAppointments} de ${dueAppointments.length}`
    : "Sem agendas vencidas no período";
  $("#analyticsVisitCloseRate").textContent = closeRate;
  $("#analyticsCpl").textContent = cpl === null ? "—" : formatCurrency(cpl);
  $("#analyticsCac").textContent = cac === null ? "—" : formatCurrency(cac);
  $("#analyticsRoas").textContent = roas === null ? "—" : `${formatDecimal(roas)}x`;
  $("#analyticsDataQuality").textContent = `${quality.percent}%`;
  $("#analyticsDataQualityHint").textContent = quality.missing
    ? `${quality.missing} campos essenciais ausentes`
    : "Base pronta para análise";
  $("#analyticsRevenueHint").textContent = bought === 1 ? "1 compra no período" : `${bought} compras no período`;
  $("#analyticsCplHint").textContent = spend > 0 ? `${formatCurrency(spend)} investidos` : "Informe o investimento";
  marketingDataBadge.textContent = mediaRows.length ? "Mídia + dados próprios" : "Dados próprios";
  marketingDataBadge.classList.toggle("is-connected", mediaRows.length > 0);

  renderMarketingGoalProgress({ total, qualified, bought, revenue, spend, roas });
  renderMarketingSourcePerformance(rows);

  syncMarketingTargetForm();
  renderMarketingConnectionStatus();
  const marketingStore = getDashboardStores().find((store) => store.id === selectedAnalyticsStoreId);
  const marketingRange = getAnalyticsSelectedDateRange(getAnalyticsBaseLeads());
  const marketingTarget = marketingTargets.find((item) => item.storeId === selectedAnalyticsStoreId) || null;
  window.MarketingAttributionModule?.setContext?.({
    profile: currentProfile ? { ...currentProfile } : null,
    storeId: marketingStore?.id || "",
    storeName: marketingStore?.name || "",
    dateStart: marketingRange.start,
    dateEnd: marketingRange.end,
    targets: marketingTarget,
    rpc: authenticatedRpc,
    edge: callMarketingEdge,
    notify: showAppNotification,
    supabaseUrl: SUPABASE_URL,
  }).catch((error) => console.warn("Marketing attribution:", error));
}

function renderMarketingGoalProgress(metrics) {
  if (!marketingGoalSummary) return;
  const target = marketingTargets.find((item) => item.storeId === selectedAnalyticsStoreId);
  if (!target || ![target.leadGoal, target.qualifiedGoal, target.salesGoal, target.revenueGoal, target.monthlyBudget].some((value) => value != null)) {
    marketingGoalSummary.innerHTML = '<span class="marketing-goal-empty"><i class="fa-solid fa-bullseye" aria-hidden="true"></i>Defina metas mensais para acompanhar o ritmo deste cliente.</span>';
    return;
  }
  const goals = [
    { label: "Leads", value: metrics.total, target: target.leadGoal },
    { label: "Qualificados", value: metrics.qualified, target: target.qualifiedGoal },
    { label: "Vendas", value: metrics.bought, target: target.salesGoal },
    { label: "Receita", value: metrics.revenue, target: target.revenueGoal, currency: true },
    { label: "Orçamento usado", value: metrics.spend, target: target.monthlyBudget, currency: true, budget: true },
  ].filter((item) => item.target != null);
  marketingGoalSummary.innerHTML = goals.map((item) => {
    const percent = item.target > 0 ? Math.round((item.value / item.target) * 100) : 0;
    const progress = Math.min(Math.max(percent, 0), 100);
    const isOverBudget = item.budget && percent > 100;
    return `
      <article class="marketing-goal-card${isOverBudget ? " is-alert" : ""}">
        <div><span>${item.label}</span><b>${percent}%</b></div>
        <strong>${item.currency ? formatCurrency(item.value) : item.value} <small>de ${item.currency ? formatCurrency(item.target) : item.target}</small></strong>
        <div class="marketing-goal-track"><i style="width:${progress}%"></i></div>
      </article>
    `;
  }).join("");
}

function renderMarketingSourcePerformance(rows) {
  if (!marketingSourcePerformanceList) return;
  const campaigns = buildAiBreakdown(rows, "campaign").slice(0, 8);
  const mediaRows = getFilteredAdMetrics();
  if (!campaigns.length) {
    marketingSourcePerformanceList.innerHTML = '<div class="marketing-source-empty">Nenhuma campanha no filtro atual.</div>';
    return;
  }
  marketingSourcePerformanceList.innerHTML = campaigns.map((item) => {
    const campaignSpend = mediaRows
      .filter((metric) => metric.campaignName === item.item)
      .reduce((sum, metric) => sum + metric.spend, 0);
    const campaignRoas = campaignSpend > 0 ? item.receita / campaignSpend : null;
    return `
      <article class="marketing-source-row">
        <div class="marketing-source-name"><strong>${escapeHtml(item.item)}</strong><small>${item.leads} ${item.leads === 1 ? "lead" : "leads"}</small></div>
        <span><small>Vendas</small><b>${item.compras}</b></span>
        <span><small>Receita</small><b>${formatCurrency(item.receita)}</b></span>
        <span><small>Investimento</small><b>${campaignSpend ? formatCurrency(campaignSpend) : "—"}</b></span>
        <span><small>ROAS</small><b>${campaignRoas === null ? "—" : `${formatDecimal(campaignRoas)}x`}</b></span>
        <span><small>Conversão</small><b>${item.conversao}</b></span>
      </article>
    `;
  }).join("");
}

function getFilteredAdMetrics() {
  if (!selectedAnalyticsStoreId) return [];
  const baseRows = getAnalyticsBaseLeads();
  const range = getAnalyticsSelectedDateRange(baseRows);
  const selectedCampaign = analyticsCampaignFilter.value;
  return adDailyMetrics.filter((metric) => (
    metric.storeId === selectedAnalyticsStoreId
    && (!range.start || metric.date >= range.start)
    && (!range.end || metric.date <= range.end)
    && (!selectedCampaign || metric.campaignName === selectedCampaign)
  ));
}

function calculateLeadDataQuality(rows) {
  if (!rows.length) return { percent: 0, missing: 0 };
  const fields = ["phone", "contactDate", "channel", "campaign", "conclusion", "scheduled"];
  const possible = rows.length * fields.length;
  const completed = rows.reduce((sum, lead) => (
    sum + fields.filter((field) => String(lead[field] || "").trim()).length
  ), 0);
  return {
    percent: Math.round((completed / possible) * 100),
    missing: possible - completed,
  };
}

function formatDecimal(value, digits = 2) {
  return new Intl.NumberFormat("pt-BR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: digits,
  }).format(Number(value || 0));
}

function syncMarketingTargetForm() {
  if (!marketingTargetsForm || marketingTargetsForm.contains(document.activeElement)) return;
  const target = marketingTargets.find((item) => item.storeId === selectedAnalyticsStoreId);
  marketingMonthlyBudget.value = target?.monthlyBudget == null ? "" : formatCurrencyInput(target.monthlyBudget);
  marketingLeadGoal.value = target?.leadGoal ?? "";
  marketingQualifiedGoal.value = target?.qualifiedGoal ?? "";
  marketingSalesGoal.value = target?.salesGoal ?? "";
  marketingRevenueGoal.value = target?.revenueGoal == null ? "" : formatCurrencyInput(target.revenueGoal);
  marketingTargetRoas.value = target?.targetRoas ?? "";
}

function renderMarketingConnectionStatus() {
  ["meta", "google"].forEach((provider) => {
    const row = marketingConnections.find((item) => item.provider === provider);
    const status = row?.status || "disconnected";
    const badge = $(`#${provider}ConnectionBadge`);
    const label = $(`#${provider}ConnectionStatus`);
    if (!badge || !label) return;
    badge.textContent = status === "active" ? "Conectado" : status === "error" ? "Atenção" : "Desconectado";
    badge.classList.toggle("is-active", status === "active");
    badge.classList.toggle("is-error", status === "error");
    label.textContent = status === "active"
      ? `${row.account_name || "Conta conectada"}${row.last_sync_at ? ` · ${formatDateTime(row.last_sync_at)}` : ""}`
      : row?.last_error || "Aguardando conexão segura";
  });
}

async function forceApplyAnalyticsFilters() {
  if (!selectedAnalyticsStoreId) {
    showAppNotification("Selecione um cliente antes de aplicar os filtros.", "error");
    return;
  }

  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  if (
    mode === "range" &&
    analyticsStartDate.value &&
    analyticsEndDate.value &&
    analyticsStartDate.value > analyticsEndDate.value
  ) {
    analyticsFilterStatus.textContent = "Revise o período informado.";
    analyticsFilterStatus.classList.remove("is-success");
    analyticsFilterStatus.classList.add("is-error");
    analyticsStartDate.focus();
    showAppNotification("A data inicial não pode ser maior que a data final.", "error");
    return;
  }

  analyticsApplyFiltersButton.disabled = true;
  analyticsApplyFiltersButton.classList.add("is-loading");
  analyticsApplyFiltersButton.setAttribute("aria-busy", "true");
  analyticsApplyFiltersButton.querySelector("span").textContent = "Aplicando...";
  analyticsContent.setAttribute("aria-busy", "true");
  analyticsFilterStatus.textContent = "Atualizando dados e recalculando resultados...";
  analyticsFilterStatus.classList.remove("is-success", "is-error");

  // Aplica imediatamente sobre os dados atuais e depois confirma com uma nova leitura do servidor.
  renderAdminAnalytics();

  try {
    await refreshRemoteState();
    renderAll();
    const total = getAnalyticsLeads().length;
    const resultLabel = total === 1 ? "1 lead encontrado" : `${total} leads encontrados`;
    analyticsFilterStatus.textContent = `Filtros aplicados · ${resultLabel}`;
    analyticsFilterStatus.classList.add("is-success");
    showAppNotification(`Filtros aplicados: ${resultLabel}.`);
  } catch (error) {
    renderAdminAnalytics();
    analyticsFilterStatus.textContent = "Filtros aplicados aos dados já carregados.";
    analyticsFilterStatus.classList.add("is-error");
    showAppNotification(`Filtros aplicados, mas não foi possível atualizar os dados: ${readableError(error)}`, "error");
  } finally {
    analyticsContent.removeAttribute("aria-busy");
    analyticsApplyFiltersButton.disabled = false;
    analyticsApplyFiltersButton.classList.remove("is-loading");
    analyticsApplyFiltersButton.removeAttribute("aria-busy");
    analyticsApplyFiltersButton.querySelector("span").textContent = "Aplicar filtros";
  }
}

async function handleAdMetricSubmit(event) {
  event.preventDefault();
  if (!selectedAnalyticsStoreId) {
    showAppNotification("Selecione um cliente para lançar o investimento.", "error");
    return;
  }
  const spend = parseCurrencyInput(adMetricSpend.value);
  if (!adMetricDate.value || !spend || spend <= 0) {
    adMetricMessage.textContent = "Informe a data e um investimento maior que zero.";
    return;
  }

  try {
    setFormBusy(adMetricForm, true);
    await authenticatedRpc("lc_upsert_ad_daily_metric", {
      p_payload: {
        store_id: selectedAnalyticsStoreId,
        metric_date: adMetricDate.value,
        platform: adMetricPlatform.value,
        campaign_name: adMetricCampaign.value.trim(),
        spend,
        impressions: Number(adMetricImpressions.value || 0),
        reach: Number(adMetricReach.value || 0),
        clicks: Number(adMetricClicks.value || 0),
        currency: "BRL",
      },
    });
    await refreshMarketingIntelligenceData();
    adMetricMessage.textContent = "Investimento salvo e métricas recalculadas.";
    adMetricMessage.classList.add("success");
    adMetricSpend.value = "";
    renderAdminAnalytics();
  } catch (error) {
    adMetricMessage.classList.remove("success");
    adMetricMessage.textContent = readableError(error);
  } finally {
    setFormBusy(adMetricForm, false);
  }
}

async function handleMarketingTargetsSubmit(event) {
  event.preventDefault();
  if (!selectedAnalyticsStoreId) {
    showAppNotification("Selecione um cliente para definir metas.", "error");
    return;
  }
  try {
    setFormBusy(marketingTargetsForm, true);
    await authenticatedRpc("lc_save_marketing_targets", {
      p_store_id: selectedAnalyticsStoreId,
      p_payload: {
        monthly_budget: parseOptionalCurrency(marketingMonthlyBudget.value),
        lead_goal: parseOptionalInteger(marketingLeadGoal.value),
        qualified_goal: parseOptionalInteger(marketingQualifiedGoal.value),
        sales_goal: parseOptionalInteger(marketingSalesGoal.value),
        revenue_goal: parseOptionalCurrency(marketingRevenueGoal.value),
        target_roas: parseOptionalNumber(marketingTargetRoas.value),
      },
    });
    await refreshMarketingIntelligenceData();
    marketingTargetsMessage.textContent = "Metas salvas para este cliente.";
    marketingTargetsMessage.classList.add("success");
    renderAdminAnalytics();
  } catch (error) {
    marketingTargetsMessage.classList.remove("success");
    marketingTargetsMessage.textContent = readableError(error);
  } finally {
    setFormBusy(marketingTargetsForm, false);
  }
}

async function refreshMarketingIntelligenceData() {
  const [metricRows, targetRows] = await Promise.all([
    authenticatedRpc("lc_list_ad_daily_metrics").catch((error) => {
      if (isMissingRpcError(error)) return [];
      throw error;
    }),
    authenticatedRpc("lc_list_marketing_targets").catch((error) => {
      if (isMissingRpcError(error)) return [];
      throw error;
    }),
  ]);
  adDailyMetrics = (metricRows || []).map(mapAdDailyMetricRow);
  marketingTargets = (targetRows || []).map(mapMarketingTargetRow);
}

async function refreshMarketingConnections(storeId) {
  if (!storeId) {
    marketingConnections = [];
    return;
  }
  marketingConnections = await authenticatedRpc("lc_list_marketing_connections", {
    p_store_id: storeId,
  }).catch((error) => {
    if (isMissingRpcError(error)) return [];
    throw error;
  });
}

function parseOptionalCurrency(value) {
  return String(value || "").trim() ? parseCurrencyInput(value) : null;
}

function parseOptionalInteger(value) {
  return String(value || "").trim() ? Math.max(0, Math.round(Number(value))) : null;
}

function parseOptionalNumber(value) {
  if (!String(value || "").trim()) return null;
  return Math.max(0, Number(String(value).replace(",", ".")) || 0);
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
  const chartMinWidth = Math.max(760, buckets.length * 54);
  const xLabelSize = buckets.length > 24 ? 8 : buckets.length > 16 ? 9 : 10;
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
        <svg class="analytics-line-chart" style="min-width:${chartMinWidth}px" viewBox="0 0 850 280" role="img" aria-label="${escapeHtml(`Gráfico de linhas de ${section.label}`)}">
          ${yTicks.map((tick) => `
            <line x1="${left}" y1="${tick.y}" x2="${right}" y2="${tick.y}" class="analytics-chart-grid-line"></line>
            <text x="12" y="${tick.y + 4}" class="analytics-chart-axis-label">${tick.value}</text>
          `).join("")}
          ${buckets.map((bucket, index) => {
            const x = buckets.length === 1 ? left + width / 2 : left + (index / (buckets.length - 1)) * width;
            return `<text x="${x}" y="270" style="font-size:${xLabelSize}px" class="analytics-chart-axis-label is-x">${escapeHtml(bucket.label)}</text>`;
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
    return getDashboardStores().map((store) => store.name).filter(Boolean);
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
  if (marketingIntelligencePanel) marketingIntelligencePanel.hidden = analyticsChartsVisible;
  analyticsBoard.hidden = analyticsChartsVisible;
  analyticsChartsPanel.hidden = !analyticsChartsVisible;
  analyticsChartsButton.classList.toggle("is-active", analyticsChartsVisible);
  analyticsChartsButton.setAttribute("aria-pressed", String(analyticsChartsVisible));
  analyticsChartsButton.innerHTML = analyticsChartsVisible
    ? '<i class="fa-solid fa-table-cells-large" aria-hidden="true"></i><span>Geral</span>'
    : '<i class="fa-solid fa-chart-simple" aria-hidden="true"></i><span>Gráficos</span>';
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

function initializeStoreExportDates() {
  const { start, end } = getCurrentWeekDateRange();
  if (storeExportStartDate) storeExportStartDate.value = start;
  if (storeExportEndDate) storeExportEndDate.value = end;
  renderStoreExportSummary();
}

function renderStoreExportSummary() {
  if (!storeExportButton || storeView.hidden) return;

  const total = getStoreExportLeads().length;
  const label = total === 1 ? "1 lead no período" : `${total} leads no período`;
  storeExportButton.title = label;
  storeExportButton.setAttribute("aria-label", `Exportar ${label}`);
}

function getStoreExportLeads() {
  const { start, end } = getStoreExportDateRange();
  return getVisibleStoreLeads().filter((lead) => {
    const createdDate = getLeadCreatedDateValue(lead);
    if (!createdDate) return false;
    if (start && createdDate < start) return false;
    if (end && createdDate > end) return false;
    return true;
  });
}

function getStoreExportDateRange() {
  return {
    start: storeExportStartDate?.value || "",
    end: storeExportEndDate?.value || "",
  };
}

function formatStoreExportPeriodLabel(start, end) {
  if (start && end) return `Cadastros de ${formatDateInputValue(start)} até ${formatDateInputValue(end)}`;
  if (start) return `Cadastros a partir de ${formatDateInputValue(start)}`;
  if (end) return `Cadastros até ${formatDateInputValue(end)}`;
  return "Todos os cadastros da loja";
}

function exportLeadsToExcel() {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;

  const selectedStore = getDashboardStores().find((store) => store.id === selectedAnalyticsStoreId);
  if (!selectedStore) {
    showAppNotification("Selecione um cliente antes de exportar.", "error");
    return;
  }

  const exportRows = [...getAnalyticsLeads()].sort((a, b) => getLeadSortDate(b).localeCompare(getLeadSortDate(a)));
  if (!exportRows.length) {
    showAppNotification("Nenhum lead deste cliente no filtro atual.", "error");
    return;
  }

  downloadLeadsWorkbook(exportRows, {
    filePrefix: `leads-${slugifyFileName(selectedStore.name)}`,
    scopeLabel: `Cliente: ${selectedStore.name}`,
  });
  showAppNotification("Excel exportado.");
}

function exportFilteredStoreLeadsToExcel() {
  const selectedStore = getActiveStore();
  if (!selectedStore) {
    showAppNotification("Loja não encontrada para exportação.", "error");
    return;
  }

  const exportRows = [...getFilteredLeads()].sort((a, b) => getLeadSortDate(b).localeCompare(getLeadSortDate(a)));
  if (!exportRows.length) {
    showAppNotification("Nenhum lead no filtro atual.", "error");
    return;
  }

  downloadLeadsWorkbook(exportRows, {
    filePrefix: `leads-${slugifyFileName(selectedStore.name)}`,
    scopeLabel: `Leads visíveis no filtro atual · ${selectedStore.name}`,
  });
  showAppNotification("Dados exportados para Excel.");
}

function exportManagedStoreLeads(storeId) {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;
  const selectedStore = getDashboardStores().find((store) => store.id === storeId);
  if (!selectedStore) {
    showAppNotification("Cliente não encontrado para exportação.", "error");
    return;
  }

  const exportRows = leads
    .filter((lead) => lead.storeId === selectedStore.id)
    .sort((a, b) => getLeadSortDate(b).localeCompare(getLeadSortDate(a)));
  if (!exportRows.length) {
    showAppNotification("Este cliente ainda não possui leads para exportar.", "error");
    return;
  }

  downloadLeadsWorkbook(exportRows, {
    filePrefix: `leads-${slugifyFileName(selectedStore.name)}`,
    scopeLabel: `Todos os leads · ${selectedStore.name}`,
  });
  showAppNotification(`Dados de ${selectedStore.name} exportados.`);
}

function downloadExcelWorkbook(workbook, filename) {
  const blob = new Blob(["\ufeff", workbook], { type: "application/vnd.ms-excel;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function exportStoreLeadsToExcel() {
  if (storeView.hidden) return;

  const { start, end } = getStoreExportDateRange();
  if (start && end && start > end) {
    showAppNotification("A data inicial não pode ser maior que a final.", "error");
    storeExportStartDate.focus();
    return;
  }

  const exportRows = getStoreExportLeads().sort((a, b) => {
    const createdCompare = getLeadCreatedDateValue(b).localeCompare(getLeadCreatedDateValue(a));
    return createdCompare || getLeadSortDate(b).localeCompare(getLeadSortDate(a));
  });

  if (!exportRows.length) {
    showAppNotification("Nenhum lead cadastrado nesse período.", "error");
    return;
  }

  const store = getActiveStore();
  const storeName = store?.name || currentProfile?.storeName || currentProfile?.username || "Loja";
  downloadLeadsWorkbook(exportRows, {
    filePrefix: `leads-${slugifyFileName(storeName)}`,
    scopeLabel: `Loja: ${storeName}`,
    periodLabel: formatStoreExportPeriodLabel(start, end),
  });
  showAppNotification("Excel da loja exportado.");
}

function downloadLeadsWorkbook(exportRows, { filePrefix = "leads", scopeLabel, periodLabel } = {}) {
  const workbook = buildLeadsExcelWorkbook(exportRows, { scopeLabel, periodLabel });
  const blob = new Blob([workbook], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${filePrefix}-${formatExportFileDate(new Date())}.xlsx`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function buildLeadsExcelWorkbook(exportRows, { scopeLabel = "Todos os leads carregados para este acesso", periodLabel = "" } = {}) {
  const visited = countByValue(exportRows, "visited", "Sim");
  const scheduled = countByValue(exportRows, "scheduled", "Sim");
  const bought = countByValue(exportRows, "bought", "Sim");
  const totalRevenue = exportRows.reduce((sum, lead) => sum + Number(lead.purchaseAmount || 0), 0);
  const tableColumns = buildLeadTableExportColumns();
  const summaryRows = [
    ["Gerado em", formatDateTime(new Date().toISOString())],
    ["Escopo", scopeLabel],
    ...(periodLabel ? [["Período", periodLabel]] : []),
    ["Total de leads", exportRows.length],
    ["Agendaram visita", scheduled],
    ["Visitaram a loja", visited],
    ["Compraram", bought],
    ["Conversão", formatPercent(bought, exportRows.length)],
    ["Receita registrada", formatCurrency(totalRevenue)],
  ];
  const leadRows = buildLeadTableRows(exportRows, tableColumns, totalRevenue);

  return buildXlsxWorkbook([
    {
      name: "Leads",
      rows: leadRows,
      columnWidths: [12, 18, 28, 16, 54, 72, 18, 16, 14, 14, 14],
      tableColumnCount: 11,
      frozenRows: 1,
    },
    {
      name: "Resumo",
      rows: [["Exportação de Leads"], ["Controle de Leads | Ótica"], [], ...summaryRows],
      columnWidths: [28, 48],
    },
  ]);
}

function buildLeadTableExportColumns() {
  const productCategory = customCategories.find((category) =>
    normalizeSearchText(category.name).includes("produto") ||
    normalizeSearchText(category.name).includes("interesse")
  );

  return [
    { header: "DATA", value: (lead) => formatLeadContactDate(lead) || formatDateInputValue(getLeadCreatedDateValue(lead)) },
    { header: "TELEFONE", value: (lead) => lead.phone || "" },
    { header: "NOME", value: (lead) => lead.name || "" },
    { header: "CANAL", value: (lead) => lead.channel || "" },
    {
      header: productCategory?.name || "Qual produto tem interesse?",
      value: (lead) => productCategory
        ? lead.customValues[productCategory.id] || ""
        : lead.conversationStart || "",
    },
    { header: "STATUS", value: (lead) => lead.conclusion || "" },
    { header: "Veio até a loja?", value: (lead) => lead.visited || "" },
    { header: "Comprou?", value: (lead) => lead.bought || "" },
    { header: "Valor", value: (lead) => Number(lead.purchaseAmount || 0) || "" },
  ];
}

function buildLeadTableRows(exportRows, tableColumns, totalRevenue) {
  const rows = [
    [...tableColumns.map((column) => column.header), "TT", "LUCRO"],
    ...exportRows.map((lead) => [
      ...tableColumns.map((column) => column.value(lead)),
      "",
      "",
    ]),
  ];

  if (rows.length < 32) {
    const emptyRow = Array.from({ length: 11 }, () => "");
    while (rows.length < 32) rows.push([...emptyRow]);
  }

  rows[1] = rows[1] || Array.from({ length: 11 }, () => "");
  rows[1][9] = totalRevenue || 0;
  rows[1][10] = "";
  return rows;
}

function buildLegacyLeadsExcelWorkbook(
  exportRows,
  selectedStore,
  { scopeLabel = "Somente os leads deste cliente no filtro atual", categories = customCategories } = {},
) {
  const visited = countByValue(exportRows, "visited", "Sim");
  const scheduled = countByValue(exportRows, "scheduled", "Sim");
  const bought = countByValue(exportRows, "bought", "Sim");
  const totalRevenue = exportRows.reduce((sum, lead) => sum + Number(lead.purchaseAmount || 0), 0);
  const columns = buildLeadExportColumns(categories);
  const summaryRows = [
    ["Gerado em", formatDateTime(new Date().toISOString())],
    ["Cliente", selectedStore.name],
    ["Escopo", scopeLabel],
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
    <p class="subtitle">Controle de Leads | ${excelCell(selectedStore.name)}</p>
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

function buildLeadExportColumns(categories = customCategories) {
  return [
    { header: "#", value: (_lead, index) => index + 1 },
    { header: "Data do contato", className: "date", value: (lead) => formatLeadContactDate(lead) },
    { header: "Registrado em", className: "date", value: (lead) => formatDateTime(lead.createdAt) },
    { header: "Loja", value: (lead) => lead.storeName },
    { header: "Nome do lead", value: (lead) => lead.name },
    { header: "Telefone", value: (lead) => lead.phone },
    { header: "E-mail", value: (lead) => lead.email || "" },
    { header: "Etapa comercial", value: (lead) => formatLifecycleStatus(lead.lifecycleStatus || inferLeadLifecycleStatus(lead)) },
    { header: "Qualificado", value: (lead) => lead.qualified ? "Sim" : "Não" },
    { header: "Responsável", value: (lead) => lead.ownerName || "" },
    { header: "Motivo da perda", value: (lead) => lead.lossReason || "" },
    { header: "Plataforma / canal", value: (lead) => lead.channel || "Sem resposta" },
    { header: "Campanha", value: (lead) => lead.campaign || "Sem resposta" },
    { header: "Início da conversa", value: (lead) => lead.conversationStart || "Sem resposta" },
    { header: "Conclusão", value: (lead) => lead.conclusion || "Sem resposta" },
    { header: "Agendou visita", value: (lead) => lead.scheduled || "Sem resposta" },
    { header: "Data da visita agendada", className: "date", value: (lead) => getScheduledVisitLabel(lead) || "" },
    { header: "Visitou a loja", value: (lead) => lead.visited || "Sem resposta" },
    { header: "Comprou", value: (lead) => lead.bought || "Sem resposta" },
    { header: "Valor da compra", className: "currency", value: (lead) => lead.purchaseAmount ? formatCurrency(lead.purchaseAmount) : "" },
    { header: "OS", value: (lead) => lead.serviceOrder || "" },
    { header: "UTM source", value: (lead) => lead.utmSource || "" },
    { header: "UTM medium", value: (lead) => lead.utmMedium || "" },
    { header: "UTM campaign", value: (lead) => lead.utmCampaign || "" },
    { header: "UTM content", value: (lead) => lead.utmContent || "" },
    { header: "ID campanha", value: (lead) => lead.campaignExternalId || "" },
    { header: "ID anúncio", value: (lead) => lead.adExternalId || "" },
    { header: "GCLID", value: (lead) => lead.gclid || "" },
    { header: "FBCLID", value: (lead) => lead.fbclid || "" },
    { header: "Consentimento marketing", value: (lead) => lead.marketingConsent ? "Sim" : "Não" },
    { header: "Cliente recorrente", value: (lead) => lead.returningCustomer ? "Sim" : "Não" },
    { header: "Inspecionado", value: (lead) => lead.inspected ? "Sim" : "Não" },
    ...categories.map((category) => ({
      header: category.name,
      value: (lead) => lead.customValues[category.id] || "Sem resposta",
    })),
    { header: "Observações", className: "notes", value: (lead) => lead.notes || "" },
    { header: "ID interno", value: (lead) => lead.id },
  ];
}

function buildXlsxWorkbook(sheets) {
  const workbookFiles = [
    {
      name: "[Content_Types].xml",
      content: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  ${sheets.map((_sheet, index) => `<Override PartName="/xl/worksheets/sheet${index + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("")}
</Types>`,
    },
    {
      name: "_rels/.rels",
      content: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`,
    },
    {
      name: "xl/workbook.xml",
      content: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    ${sheets.map((sheet, index) => `<sheet name="${xmlAttribute(cleanSheetName(sheet.name))}" sheetId="${index + 1}" r:id="rId${index + 1}"/>`).join("")}
  </sheets>
</workbook>`,
    },
    {
      name: "xl/_rels/workbook.xml.rels",
      content: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  ${sheets.map((_sheet, index) => `<Relationship Id="rId${index + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${index + 1}.xml"/>`).join("")}
  <Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`,
    },
    {
      name: "xl/styles.xml",
      content: buildXlsxStyles(),
    },
    ...sheets.map((sheet, index) => ({
      name: `xl/worksheets/sheet${index + 1}.xml`,
      content: buildXlsxWorksheet(sheet.rows, sheet),
    })),
  ];

  return createZipArchive(workbookFiles);
}

function buildXlsxWorksheet(rows, options = {}) {
  const normalizedRows = rows.map((row) => Array.isArray(row) ? row : [row]);
  const maxColumnCount = options.tableColumnCount || normalizedRows.reduce((max, row) => Math.max(max, row.length), 1);
  const dimension = `A1:${columnName(maxColumnCount)}${Math.max(normalizedRows.length, 1)}`;
  const columnsXml = Array.isArray(options.columnWidths)
    ? `<cols>${options.columnWidths.map((width, index) => `<col min="${index + 1}" max="${index + 1}" width="${width}" customWidth="1"/>`).join("")}</cols>`
    : "";
  const freezeXml = options.frozenRows
    ? `<sheetViews><sheetView workbookViewId="0"><pane ySplit="${options.frozenRows}" topLeftCell="A${options.frozenRows + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>`
    : `<sheetViews><sheetView workbookViewId="0"/></sheetViews>`;
  const rowXml = normalizedRows
    .map((row, rowIndex) => {
      const rowNumber = rowIndex + 1;
      const rowValues = options.tableColumnCount
        ? Array.from({ length: options.tableColumnCount }, (_value, index) => row[index] ?? "")
        : row;
      const rowHeight = rowIndex === 0 ? 22 : 21;
      const cells = rowValues
        .map((value, columnIndex) => {
          const isCurrencyColumn = options.tableColumnCount && columnIndex >= 8;
          const styleId = options.tableColumnCount
            ? rowIndex === 0 ? 1 : isCurrencyColumn ? 3 : 2
            : 0;
          return buildXlsxCell(value, `${columnName(columnIndex + 1)}${rowNumber}`, styleId);
        })
        .join("");
      return `<row r="${rowNumber}" ht="${rowHeight}" customHeight="1">${cells}</row>`;
    })
    .join("");

  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <dimension ref="${dimension}"/>
  ${freezeXml}
  <sheetFormatPr defaultRowHeight="21"/>
  ${columnsXml}
  <sheetData>${rowXml}</sheetData>
</worksheet>`;
}

function buildXlsxCell(value, reference, styleId = 0) {
  const styleAttribute = styleId ? ` s="${styleId}"` : "";
  if (value === null || value === undefined || value === "") {
    return `<c r="${reference}"${styleAttribute}/>`;
  }

  if (typeof value === "number" && Number.isFinite(value)) {
    return `<c r="${reference}"${styleAttribute}><v>${value}</v></c>`;
  }

  const text = String(value);
  const protectedText = /^[=+\-@]/.test(text.trim()) ? `'${text}` : text;
  return `<c r="${reference}"${styleAttribute} t="inlineStr"><is><t xml:space="preserve">${xmlText(protectedText)}</t></is></c>`;
}

function buildXlsxStyles() {
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="1">
    <numFmt numFmtId="164" formatCode="R$ #,##0.00"/>
  </numFmts>
  <fonts count="2">
    <font><sz val="11"/><name val="Arial"/></font>
    <font><b/><sz val="11"/><name val="Arial"/></font>
  </fonts>
  <fills count="3">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFD9EAD3"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="2">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border>
      <left style="thin"><color rgb="FF3F3F3F"/></left>
      <right style="thin"><color rgb="FF3F3F3F"/></right>
      <top style="thin"><color rgb="FF3F3F3F"/></top>
      <bottom style="thin"><color rgb="FF3F3F3F"/></bottom>
      <diagonal/>
    </border>
  </borders>
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="4">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">
      <alignment vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="right" vertical="center" wrapText="1"/>
    </xf>
  </cellXfs>
  <cellStyles count="1">
    <cellStyle name="Normal" xfId="0" builtinId="0"/>
  </cellStyles>
</styleSheet>`;
}

function createZipArchive(files) {
  const encoder = new TextEncoder();
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  const now = new Date();
  const dosTime = (now.getHours() << 11) | (now.getMinutes() << 5) | Math.floor(now.getSeconds() / 2);
  const dosDate = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();

  files.forEach((file) => {
    const fileName = encoder.encode(file.name);
    const content = typeof file.content === "string" ? encoder.encode(file.content) : file.content;
    const crc = crc32(content);
    const localHeader = new Uint8Array(30 + fileName.length);
    const localView = new DataView(localHeader.buffer);
    localView.setUint32(0, 0x04034b50, true);
    localView.setUint16(4, 20, true);
    localView.setUint16(6, 0x0800, true);
    localView.setUint16(8, 0, true);
    localView.setUint16(10, dosTime, true);
    localView.setUint16(12, dosDate, true);
    localView.setUint32(14, crc, true);
    localView.setUint32(18, content.length, true);
    localView.setUint32(22, content.length, true);
    localView.setUint16(26, fileName.length, true);
    localHeader.set(fileName, 30);
    localParts.push(localHeader, content);

    const centralHeader = new Uint8Array(46 + fileName.length);
    const centralView = new DataView(centralHeader.buffer);
    centralView.setUint32(0, 0x02014b50, true);
    centralView.setUint16(4, 20, true);
    centralView.setUint16(6, 20, true);
    centralView.setUint16(8, 0x0800, true);
    centralView.setUint16(10, 0, true);
    centralView.setUint16(12, dosTime, true);
    centralView.setUint16(14, dosDate, true);
    centralView.setUint32(16, crc, true);
    centralView.setUint32(20, content.length, true);
    centralView.setUint32(24, content.length, true);
    centralView.setUint16(28, fileName.length, true);
    centralView.setUint32(42, offset, true);
    centralHeader.set(fileName, 46);
    centralParts.push(centralHeader);

    offset += localHeader.length + content.length;
  });

  const centralOffset = offset;
  const centralSize = centralParts.reduce((sum, part) => sum + part.length, 0);
  const endRecord = new Uint8Array(22);
  const endView = new DataView(endRecord.buffer);
  endView.setUint32(0, 0x06054b50, true);
  endView.setUint16(8, files.length, true);
  endView.setUint16(10, files.length, true);
  endView.setUint32(12, centralSize, true);
  endView.setUint32(16, centralOffset, true);

  return concatUint8Arrays([...localParts, ...centralParts, endRecord]);
}

function concatUint8Arrays(parts) {
  const totalLength = parts.reduce((sum, part) => sum + part.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  parts.forEach((part) => {
    result.set(part, offset);
    offset += part.length;
  });
  return result;
}

let crc32Lookup = null;

function crc32(bytes) {
  if (!crc32Lookup) {
    crc32Lookup = Array.from({ length: 256 }, (_value, index) => {
      let current = index;
      for (let bit = 0; bit < 8; bit += 1) {
        current = current & 1 ? 0xedb88320 ^ (current >>> 1) : current >>> 1;
      }
      return current >>> 0;
    });
  }

  let crc = 0xffffffff;
  bytes.forEach((byte) => {
    crc = crc32Lookup[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  });
  return (crc ^ 0xffffffff) >>> 0;
}

function columnName(index) {
  let name = "";
  let current = index;
  while (current > 0) {
    const remainder = (current - 1) % 26;
    name = String.fromCharCode(65 + remainder) + name;
    current = Math.floor((current - 1) / 26);
  }
  return name;
}

function cleanSheetName(value) {
  return String(value || "Planilha").replace(/[:\\/?*\[\]]/g, " ").slice(0, 31) || "Planilha";
}

function xmlText(value) {
  return String(value)
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function xmlAttribute(value) {
  return xmlText(value).replace(/"/g, "&quot;");
}

function formatExportFileDate(date) {
  return date.toISOString().slice(0, 19).replace(/[:T]/g, "-");
}

function isBackupSupported() {
  return typeof window.showDirectoryPicker === "function" && typeof indexedDB !== "undefined";
}

function createEmptyBackupManifest() {
  return {
    version: 1,
    ownerId: "",
    updatedAt: null,
    lastRunAt: null,
    lastAutoRunDate: "",
    stores: {},
  };
}

function getBackupOwnerKey() {
  if (!currentProfile) return "guest";
  return `${currentProfile.role}:${currentProfile.id || currentProfile.username || "current"}`;
}

async function initializeBackupSystem() {
  stopBackupScheduler();
  backupDirectoryHandle = null;
  backupManifest = createEmptyBackupManifest();
  backupPermissionState = "prompt";
  backupAutoAttemptDate = "";

  if (!["admin", "technician"].includes(currentProfile?.role) || !isBackupSupported()) {
    renderBackupCenter();
    return;
  }

  try {
    backupManifest = await loadBackupManifest();
    backupDirectoryHandle = await loadBackupDirectoryHandle();
    if (backupDirectoryHandle) {
      backupPermissionState = await queryBackupPermission(backupDirectoryHandle);
    }
  } catch (error) {
    console.warn("Não foi possível restaurar o HD de backup:", error);
    backupDirectoryHandle = null;
    backupPermissionState = "prompt";
  }

  startBackupScheduler();
  renderBackupCenter();
  window.setTimeout(() => checkScheduledBackup(), 1200);
}

function startBackupScheduler() {
  stopBackupScheduler();
  if (!["admin", "technician"].includes(currentProfile?.role) || !isBackupSupported()) return;
  backupSchedulerTimer = window.setInterval(checkScheduledBackup, 60 * 1000);
}

function stopBackupScheduler() {
  if (backupSchedulerTimer) window.clearInterval(backupSchedulerTimer);
  backupSchedulerTimer = null;
}

async function checkScheduledBackup() {
  if (backupIsRunning || !backupDirectoryHandle || backupPermissionState !== "granted") return;
  const now = new Date();
  const today = formatLocalDateKey(now);
  if (now.getHours() < BACKUP_SCHEDULE_HOUR) return;
  if (backupManifest.lastAutoRunDate === today || backupAutoAttemptDate === today) return;

  backupAutoAttemptDate = today;
  try {
    await runBackup({ manual: false });
  } catch (error) {
    showBackupMessage(`Backup automático pendente: ${readableError(error)}`, "error");
  }
}

async function chooseBackupDirectory() {
  if (!isBackupSupported()) {
    showBackupMessage("Use Chrome ou Edge no computador para escolher um HD externo.", "error");
    return;
  }

  try {
    const handle = await window.showDirectoryPicker({
      id: `lead-control-${normalizeNick(currentProfile?.username || "backup")}`,
      mode: "readwrite",
      startIn: "downloads",
    });
    const permission = await requestBackupPermission(handle);
    if (permission !== "granted") throw new Error("Autorize a gravação na pasta escolhida.");

    const isSameDirectory = backupDirectoryHandle?.isSameEntry
      ? await backupDirectoryHandle.isSameEntry(handle)
      : false;

    backupDirectoryHandle = handle;
    backupPermissionState = permission;
    if (!isSameDirectory) {
      backupManifest = createEmptyBackupManifest();
      await saveBackupManifest(backupManifest);
    } else {
      backupManifest = await loadBackupManifest();
    }
    await saveBackupDirectoryHandle(handle);
    renderBackupCenter();
    showBackupMessage(`Destino conectado: ${handle.name}.`, "success");
  } catch (error) {
    if (error?.name === "AbortError") return;
    showBackupMessage(readableError(error), "error");
  }
}

async function runBackup({ manual = false } = {}) {
  if (backupIsRunning) return;
  if (!isBackupSupported()) throw new Error("Backup em HD não suportado neste navegador.");
  if (!backupDirectoryHandle) throw new Error("Escolha primeiro o HD ou a pasta de destino.");

  const permission = manual
    ? await requestBackupPermission(backupDirectoryHandle)
    : await queryBackupPermission(backupDirectoryHandle);
  backupPermissionState = permission;
  if (permission !== "granted") {
    renderBackupCenter();
    throw new Error("Reconecte o HD e autorize o acesso para continuar.");
  }

  backupIsRunning = true;
  backupRunNow.disabled = true;
  backupChooseDirectory.disabled = true;
  showBackupMessage(manual ? "Verificando diferenças e preparando os arquivos..." : "Executando backup automático das 20h...");

  try {
    await refreshRemoteState();
    backupManifest = await loadBackupManifest();
    const targetStores = getDashboardStores();
    const results = [];

    for (const store of targetStores) {
      const storeRows = leads
        .filter((lead) => lead.storeId === store.id)
        .sort((a, b) => getLeadSortDate(a).localeCompare(getLeadSortDate(b)));
      results.push(await backupStoreLeads(store, storeRows, new Date()));
      backupManifest.ownerId = getBackupOwnerKey();
      backupManifest.updatedAt = new Date().toISOString();
      await saveBackupManifest(backupManifest);
    }

    const now = new Date();
    backupManifest.ownerId = getBackupOwnerKey();
    backupManifest.updatedAt = now.toISOString();
    backupManifest.lastRunAt = now.toISOString();
    if (!manual || now.getHours() >= BACKUP_SCHEDULE_HOUR) {
      backupManifest.lastAutoRunDate = formatLocalDateKey(now);
    }
    await saveBackupManifest(backupManifest);

    const exportedStores = results.filter((result) => result.exported > 0);
    const exportedLeads = exportedStores.reduce((total, result) => total + result.exported, 0);
    const currentStores = results.filter((result) => result.exported === 0).length;
    const summary = exportedLeads
      ? `${exportedLeads} ${exportedLeads === 1 ? "lead novo ou alterado" : "leads novos ou alterados"} em ${exportedStores.length} ${exportedStores.length === 1 ? "cliente" : "clientes"}.`
      : "Nenhuma diferença encontrada. Todos os backups já estavam atualizados.";
    showBackupMessage(`${summary}${currentStores && exportedLeads ? ` ${currentStores} sem alterações.` : ""}`, "success");
    renderAll();
  } finally {
    backupIsRunning = false;
    backupChooseDirectory.disabled = false;
    renderBackupCenter();
  }
}

async function backupStoreLeads(store, storeRows, now) {
  const previousStore = backupManifest.stores[store.id] || { records: {} };
  const nextRecords = {};
  const changedRows = [];

  for (const lead of storeRows) {
    const fingerprint = await fingerprintLead(lead);
    nextRecords[lead.id] = fingerprint;
    if (previousStore.records?.[lead.id] !== fingerprint) changedRows.push(lead);
  }

  const isFirstBackup = !backupManifest.stores[store.id];
  if (changedRows.length) {
    const destination = await getBackupStoreDirectory(backupDirectoryHandle, store, now);
    const categories = getLeadCategoriesForExport(storeRows);
    const workbook = buildLegacyLeadsExcelWorkbook(changedRows, store, {
      scopeLabel: isFirstBackup
        ? "Primeiro backup completo deste cliente"
        : "Backup incremental: somente leads novos ou alterados",
      categories,
    });
    const kind = isFirstBackup ? "completo" : "incremental";
    const filename = `backup-${kind}-${formatExportFileDate(now)}.xls`;
    await writeDirectoryFile(destination, filename, `\ufeff${workbook}`);
  }

  backupManifest.stores[store.id] = {
    name: store.name,
    username: store.username,
    lastRunAt: now.toISOString(),
    lastExportedCount: changedRows.length,
    totalRecords: storeRows.length,
    records: nextRecords,
  };

  return { storeId: store.id, exported: changedRows.length, total: storeRows.length };
}

function getLeadCategoriesForExport(storeRows) {
  const categories = new Map();
  storeRows.forEach((lead) => {
    lead.customValueRows.forEach((row) => {
      if (row.categoryId && !categories.has(row.categoryId)) {
        categories.set(row.categoryId, { id: row.categoryId, name: row.categoryName || "Campo personalizado" });
      }
    });
  });
  return [...categories.values()];
}

async function fingerprintLead(lead) {
  const snapshot = JSON.stringify({
    id: lead.id,
    updatedAt: lead.updatedAt,
    contactDate: lead.contactDate,
    name: lead.name,
    phone: lead.phone,
    channel: lead.channel,
    campaign: lead.campaign,
    conversationStart: lead.conversationStart,
    conclusion: lead.conclusion,
    scheduled: lead.scheduled,
    scheduledVisitDate: lead.scheduledVisitDate,
    scheduledVisitTime: lead.scheduledVisitTime,
    visited: lead.visited,
    bought: lead.bought,
    purchaseAmount: lead.purchaseAmount,
    serviceOrder: lead.serviceOrder,
    inspected: lead.inspected,
    notes: lead.notes,
    customValues: [...lead.customValueRows]
      .sort((a, b) => String(a.categoryId).localeCompare(String(b.categoryId)))
      .map((row) => [row.categoryId, row.value]),
  });

  if (globalThis.crypto?.subtle && typeof TextEncoder !== "undefined") {
    const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(snapshot));
    return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  let hash = 2166136261;
  for (let index = 0; index < snapshot.length; index += 1) {
    hash ^= snapshot.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}

async function getBackupStoreDirectory(rootHandle, store, date) {
  const root = await rootHandle.getDirectoryHandle(BACKUP_ROOT_FOLDER, { create: true });
  const owner = await root.getDirectoryHandle(sanitizePathSegment(getBackupOwnerLabel()), { create: true });
  const storeFolder = await owner.getDirectoryHandle(
    sanitizePathSegment(`${store.name} (@${store.username || "cliente"})`),
    { create: true },
  );
  const year = await storeFolder.getDirectoryHandle(String(date.getFullYear()), { create: true });
  const monthNumber = String(date.getMonth() + 1).padStart(2, "0");
  const monthName = new Intl.DateTimeFormat("pt-BR", { month: "long" }).format(date);
  const month = await year.getDirectoryHandle(sanitizePathSegment(`${monthNumber} - ${monthName}`), { create: true });
  const week = String(Math.ceil(date.getDate() / 7)).padStart(2, "0");
  return month.getDirectoryHandle(`Semana ${week}`, { create: true });
}

function getBackupOwnerLabel() {
  if (currentProfile?.role === "technician") {
    return currentProfile.fullName || currentProfile.username || "Agência B2B";
  }
  return currentProfile?.fullName || currentProfile?.username || "Administrador";
}

function sanitizePathSegment(value) {
  return String(value || "Sem nome")
    .normalize("NFC")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-")
    .replace(/[. ]+$/g, "")
    .trim()
    .slice(0, 100) || "Sem nome";
}

function formatLocalDateKey(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

async function queryBackupPermission(handle) {
  if (!handle?.queryPermission) return "prompt";
  return handle.queryPermission({ mode: "readwrite" });
}

async function requestBackupPermission(handle) {
  const current = await queryBackupPermission(handle);
  if (current === "granted") return current;
  if (!handle?.requestPermission) return current;
  return handle.requestPermission({ mode: "readwrite" });
}

async function writeDirectoryFile(directoryHandle, filename, content) {
  const fileHandle = await directoryHandle.getFileHandle(filename, { create: true });
  const writable = await fileHandle.createWritable();
  try {
    await writable.write(content);
    await writable.close();
  } catch (error) {
    await writable.abort?.().catch(() => {});
    throw error;
  }
}

function openBackupDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(BACKUP_DB_NAME, BACKUP_DB_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(BACKUP_HANDLE_STORE)) {
        database.createObjectStore(BACKUP_HANDLE_STORE);
      }
      if (!database.objectStoreNames.contains(BACKUP_MANIFEST_STORE)) {
        database.createObjectStore(BACKUP_MANIFEST_STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function saveBackupDirectoryHandle(handle) {
  const database = await openBackupDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(BACKUP_HANDLE_STORE, "readwrite");
    transaction.objectStore(BACKUP_HANDLE_STORE).put(handle, getBackupOwnerKey());
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
  database.close();
}

async function loadBackupDirectoryHandle() {
  const database = await openBackupDatabase();
  const handle = await new Promise((resolve, reject) => {
    const transaction = database.transaction(BACKUP_HANDLE_STORE, "readonly");
    const request = transaction.objectStore(BACKUP_HANDLE_STORE).get(getBackupOwnerKey());
    request.onsuccess = () => resolve(request.result || null);
    request.onerror = () => reject(request.error);
  });
  database.close();
  return handle;
}

async function saveBackupManifest(manifest) {
  const database = await openBackupDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(BACKUP_MANIFEST_STORE, "readwrite");
    transaction.objectStore(BACKUP_MANIFEST_STORE).put(manifest, getBackupOwnerKey());
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
  database.close();
}

async function loadBackupManifest() {
  const database = await openBackupDatabase();
  const saved = await new Promise((resolve, reject) => {
    const transaction = database.transaction(BACKUP_MANIFEST_STORE, "readonly");
    const request = transaction.objectStore(BACKUP_MANIFEST_STORE).get(getBackupOwnerKey());
    request.onsuccess = () => resolve(request.result || null);
    request.onerror = () => reject(request.error);
  });
  database.close();
  return saved && typeof saved === "object"
    ? { ...createEmptyBackupManifest(), ...saved, stores: saved.stores || {} }
    : createEmptyBackupManifest();
}

function renderBackupCenter() {
  if (!backupCenter) return;
  const supported = isBackupSupported();
  const storesForBackup = getDashboardStores();
  const hasDirectory = Boolean(backupDirectoryHandle);
  const isReady = supported && hasDirectory && backupPermissionState === "granted";

  backupSupportBadge.classList.toggle("is-ready", isReady);
  backupSupportBadge.classList.toggle("is-error", !supported);
  backupSupportBadge.textContent = !supported
    ? "Navegador incompatível"
    : isReady
      ? "HD conectado"
      : hasDirectory
        ? "Reconectar HD"
        : "Aguardando pasta";
  backupDirectoryLabel.textContent = hasDirectory ? backupDirectoryHandle.name : "Nenhum HD selecionado";
  backupDirectoryHint.textContent = !supported
    ? "Abra o sistema no Chrome ou Edge para usar o backup em disco."
    : isReady
      ? "Acesso autorizado. O backup automático está preparado."
      : hasDirectory
        ? "Clique em escolher HD ou pasta para renovar a autorização."
        : "Escolha uma pasta do HD externo e autorize o acesso.";
  backupLastRun.textContent = backupManifest.lastRunAt ? formatDateTime(backupManifest.lastRunAt) : "Ainda não realizado";
  backupRunNow.disabled = backupIsRunning || !supported || !hasDirectory;
  backupChooseDirectory.disabled = backupIsRunning || !supported;
  backupChooseDirectory.innerHTML = hasDirectory
    ? '<i class="fa-solid fa-plug-circle-check" aria-hidden="true"></i> Trocar ou reconectar HD'
    : '<i class="fa-solid fa-hard-drive" aria-hidden="true"></i> Escolher HD ou pasta';
  backupClientsTitle.textContent = `${storesForBackup.length} ${storesForBackup.length === 1 ? "cliente preparado" : "clientes preparados"}`;
  backupClientList.innerHTML = storesForBackup.length
    ? storesForBackup.map((store) => {
        const storeManifest = backupManifest.stores[store.id];
        const total = leads.filter((lead) => lead.storeId === store.id).length;
        return `
          <article class="backup-client-row">
            <i class="fa-solid fa-building" aria-hidden="true"></i>
            <div class="backup-client-main">
              <strong>${escapeHtml(store.name)}</strong>
              <span>@${escapeHtml(store.username || "cliente")} · ${total} ${total === 1 ? "lead" : "leads"}</span>
            </div>
            <small>${storeManifest?.lastRunAt ? `Último: ${escapeHtml(formatDateTime(storeManifest.lastRunAt))}` : "Aguardando primeiro backup"}</small>
          </article>
        `;
      }).join("")
    : '<div class="empty-state"><strong>Nenhum cliente nesta carteira.</strong><span>Cadastre um cliente antes de iniciar os backups.</span></div>';
}

function showBackupMessage(message, type = "") {
  if (!backupMessage) return;
  backupMessage.textContent = message;
  backupMessage.classList.toggle("success", type === "success");
}

function slugifyFileName(value) {
  return String(value || "loja")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    || "loja";
}

function openAiChat() {
  if (!["admin", "technician"].includes(currentProfile?.role)) return;
  if (!selectedAnalyticsStoreId) {
    showAppNotification("Selecione um cliente antes de abrir a análise por IA.", "error");
    return;
  }

  syncAiChatStoreScope(selectedAnalyticsStoreId);
  ensureActiveAiChat();
  updateAiContextLabel();
  renderAiMessages();
  renderAiHistoryList();
  renderAiSettingsForm();
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
  if (!canConfigureAiSettings()) {
    aiSettingsPanel.hidden = true;
    aiChatDialogSettingsState();
    return;
  }
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
  const canConfigure = canConfigureAiSettings();
  aiSettingsToggle.hidden = !canConfigure;
  aiSettingsToggle.disabled = !canConfigure;
  if (!canConfigure) aiSettingsPanel.hidden = true;
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

function syncAiChatStoreScope(storeId) {
  const nextScopeId = storeId || "";
  if (aiChatStoreScopeId === nextScopeId) return;
  saveActiveAiChatMessages();
  aiChatStoreScopeId = nextScopeId;
  loadAiChatSessions();
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
  return `${currentProfile.role}:${currentProfile.id || currentProfile.username || "current"}:store:${aiChatStoreScopeId || "none"}`;
}

function handleAiProviderChange() {
  const provider = aiProvider.value;
  renderAiModelOptions(provider);
  aiModel.value = aiSettings.models[provider] || aiProviderOptions[provider]?.models[0] || "";
  aiApiKey.value = "";
  aiApiKey.placeholder = aiSettings.hasApiKey && provider === aiSettings.provider
    ? "Chave já salva — deixe vazio para manter"
    : "Cole a chave da API";
  clearAiKeyStatus();
}

async function handleAiSettingsSubmit(event) {
  event.preventDefault();
  if (!canConfigureAiSettings()) return;

  try {
    setFormBusy(aiSettingsForm, true);
    await saveCentralAiSettings({
      provider: aiProvider.value,
      model: aiModel.value,
      apiKey: aiApiKey.value,
      systemPrompt: aiSystemPrompt.value,
    });
    renderAiSettingsForm();
    renderAdminAiSettingsForm();
    showAiSettingsMessage("Configuração central salva para todas as agências.", "success");
  } catch (error) {
    showAiSettingsMessage(readableError(error));
  } finally {
    setFormBusy(aiSettingsForm, false);
  }
}

async function handleAiValidateKey() {
  if (!canConfigureAiSettings()) return;

  aiValidateKeyButton.disabled = true;
  showAiKeyStatus("Salvando e validando...", "pending");

  try {
    await saveCentralAiSettings({
      provider: aiProvider.value,
      model: aiModel.value,
      apiKey: aiApiKey.value,
      systemPrompt: aiSystemPrompt.value,
    });
    await validateCentralAiConfiguration();
    renderAiSettingsForm();
    renderAdminAiSettingsForm();
    showAiKeyStatus("Configuração válida e pronta para o B2B.", "success");
  } catch (error) {
    showAiKeyStatus(readableError(error), "error");
  } finally {
    aiValidateKeyButton.disabled = false;
  }
}

function handleAdminAiProviderChange() {
  const provider = adminAiProvider.value;
  renderAiModelOptionsFor(adminAiModel, provider, aiSettings.models[provider]);
  adminAiApiKey.value = "";
  adminAiApiKey.placeholder = aiSettings.hasApiKey && provider === aiSettings.provider
    ? "Chave já salva — deixe vazio para manter"
    : "Cole a chave da API";
  showAdminAiSettingsMessage("");
}

async function handleAdminAiSettingsSubmit(event) {
  event.preventDefault();
  if (currentProfile?.role !== "admin") return;

  try {
    setFormBusy(adminAiSettingsForm, true);
    await saveCentralAiSettings({
      provider: adminAiProvider.value,
      model: adminAiModel.value,
      apiKey: adminAiApiKey.value,
      systemPrompt: adminAiSystemPrompt.value,
    });
    renderAdminAiSettingsForm();
    renderAiSettingsForm();
    showAdminAiSettingsMessage("IA salva. As agências já usarão esta configuração.", "success");
  } catch (error) {
    showAdminAiSettingsMessage(readableError(error));
  } finally {
    setFormBusy(adminAiSettingsForm, false);
  }
}

async function handleAdminAiValidate() {
  if (currentProfile?.role !== "admin") return;

  adminAiValidateButton.disabled = true;
  showAdminAiSettingsMessage("Salvando e validando a API...");

  try {
    await saveCentralAiSettings({
      provider: adminAiProvider.value,
      model: adminAiModel.value,
      apiKey: adminAiApiKey.value,
      systemPrompt: adminAiSystemPrompt.value,
    });
    await validateCentralAiConfiguration();
    renderAdminAiSettingsForm();
    renderAiSettingsForm();
    showAdminAiSettingsMessage("API validada. A IA está pronta para o admin e para os B2B.", "success");
  } catch (error) {
    showAdminAiSettingsMessage(readableError(error));
  } finally {
    adminAiValidateButton.disabled = false;
  }
}

async function refreshCentralAiSettings({ silent = false } = {}) {
  try {
    const row = firstRow(await authenticatedRpc("lc_get_ai_settings"));
    aiSettings = normalizeAiSettings(row);
    renderAiSettingsForm();
    renderAdminAiSettingsForm();
    return aiSettings;
  } catch (error) {
    aiSettings = createDefaultAiSettings();
    aiSettings.centralAvailable = false;
    if (!silent) throw error;
    console.warn("Configuração central de IA indisponível:", error);
    return aiSettings;
  }
}

async function saveCentralAiSettings({ provider, model, apiKey, systemPrompt }) {
  if (currentProfile?.role !== "admin") {
    throw new Error("Apenas o administrador pode alterar a IA central.");
  }

  const normalizedProvider = aiProviderOptions[provider] ? provider : "deepseek";
  const normalizedModel = String(model || "").trim() || aiProviderOptions[normalizedProvider].models[0];
  const row = firstRow(await authenticatedRpc("lc_save_ai_settings", {
    p_provider: normalizedProvider,
    p_model: normalizedModel,
    p_api_key: String(apiKey || "").trim() || null,
    p_system_prompt: String(systemPrompt || "").trim() || DEFAULT_AI_SYSTEM_PROMPT,
  }));
  aiSettings = normalizeAiSettings(row);
  return aiSettings;
}

async function validateCentralAiConfiguration() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);

  try {
    if (!aiSettings.hasApiKey) throw new Error("Informe a chave da API antes de validar.");
    const response = await fetch(`${SUPABASE_URL}/functions/v1/ai-analysis`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        "x-app-session": currentProfile.sessionToken,
      },
      body: JSON.stringify({ action: "validate" }),
    });
    await readAiValidationResponse(response);
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
    const message = (typeof payload?.error === "string" ? payload.error : payload?.error?.message) || payload?.message || "Chave inválida ou sem permissão.";
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

  if (!aiSettings.hasApiKey) {
    if (currentProfile?.role === "admin") {
      showAppNotification("Configure e valide a API nas configurações do admin.", "error");
    } else {
      showAppNotification("A IA ainda não foi configurada pelo administrador.", "error");
    }
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
  const context = buildAiLeadContext(getAnalyticsLeads());
  const conversationMessages = aiMessages.filter((message) => !message.isThinking && !message.isStreaming);
  if (!aiSettings.hasApiKey) throw new Error("A IA ainda não foi configurada pelo administrador.");

  const response = await fetch(`${SUPABASE_URL}/functions/v1/ai-analysis`, {
    method: "POST",
    signal,
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      "x-app-session": currentProfile.sessionToken,
    },
    body: JSON.stringify({
      action: "chat",
      store_id: selectedAnalyticsStoreId,
      context,
      messages: conversationMessages.map((message) => ({
        role: message.role === "assistant" ? "assistant" : "user",
        content: message.content,
      })),
    }),
  });

  const text = await readAiStream(response, (data) => {
    const chunk = provider === "gemini"
      ? data?.candidates?.[0]?.content?.parts?.map((part) => part.text || "").join("") || ""
      : data?.choices?.[0]?.delta?.content || "";
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
    const message = (typeof data?.error === "string" ? data.error : data?.error?.message) || data?.message || text || "Erro ao chamar a IA.";
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

  const revenue = filteredLeads.reduce((sum, lead) => sum + (lead.bought === "Sim" ? Number(lead.purchaseAmount || 0) : 0), 0);
  const qualified = filteredLeads.filter((lead) => lead.qualified || lead.lifecycleStatus === "qualified").length;
  const mediaRows = getFilteredAdMetrics();
  const spend = mediaRows.reduce((sum, row) => sum + row.spend, 0);
  const quality = calculateLeadDataQuality(filteredLeads);

  return {
    gerado_em: new Date().toISOString(),
    filtros: buildAnalyticsFilterSnapshot(),
    resumo: {
      leads: total,
      qualificados: qualified,
      agendaram: scheduled,
      visitaram: visited,
      compraram: bought,
      conversao: formatPercent(bought, total),
      taxa_agendamento: formatPercent(scheduled, total),
      taxa_comparecimento: formatPercent(visited, scheduled),
      fechamento_visita_compra: formatPercent(bought, visited),
      receita: revenue,
      ticket_medio: bought ? revenue / bought : 0,
      investimento: spend,
      cpl: spend > 0 && total ? spend / total : null,
      custo_por_qualificado: spend > 0 && qualified ? spend / qualified : null,
      custo_por_agendamento: spend > 0 && scheduled ? spend / scheduled : null,
      custo_por_visita: spend > 0 && visited ? spend / visited : null,
      cac: spend > 0 && bought ? spend / bought : null,
      roas: spend > 0 ? revenue / spend : null,
      qualidade_dos_dados: quality.percent,
      tamanho_da_amostra: total < 30 ? "baixa" : total < 100 ? "moderada" : "robusta",
    },
    rankings: {
      canais: buildAiBreakdown(filteredLeads, "channel"),
      campanhas: buildAiBreakdown(filteredLeads, "campaign"),
      conclusoes: buildAiBreakdown(filteredLeads, "conclusion"),
      motivos_de_perda: buildAiBreakdown(filteredLeads.filter((lead) => lead.lifecycleStatus === "lost"), "lossReason"),
    },
    serie_diaria: buildAiDailySeries(filteredLeads),
    midia: {
      linhas_importadas: mediaRows.length,
      impressoes: mediaRows.reduce((sum, row) => sum + row.impressions, 0),
      alcance: mediaRows.reduce((sum, row) => sum + row.reach, 0),
      cliques: mediaRows.reduce((sum, row) => sum + row.clicks, 0),
      ctr: calculateRate(
        mediaRows.reduce((sum, row) => sum + row.clicks, 0),
        mediaRows.reduce((sum, row) => sum + row.impressions, 0),
      ),
      cpc: calculateRatio(spend, mediaRows.reduce((sum, row) => sum + row.clicks, 0)),
      cpm: calculateRatio(spend * 1000, mediaRows.reduce((sum, row) => sum + row.impressions, 0)),
      frequencia: calculateRatio(
        mediaRows.reduce((sum, row) => sum + row.impressions, 0),
        mediaRows.reduce((sum, row) => sum + row.reach, 0),
      ),
    },
  };
}

function calculateRatio(value, denominator) {
  return denominator ? Number((value / denominator).toFixed(4)) : null;
}

function calculateRate(value, denominator) {
  return denominator ? Number(((value / denominator) * 100).toFixed(2)) : null;
}

function buildAiBreakdown(rows, key) {
  const grouped = new Map();
  rows.forEach((lead) => {
    const label = String(lead[key] || "Sem resposta");
    const current = grouped.get(label) || { item: label, leads: 0, agendamentos: 0, visitas: 0, compras: 0, receita: 0 };
    current.leads += 1;
    if (lead.scheduled === "Sim") current.agendamentos += 1;
    if (lead.visited === "Sim") current.visitas += 1;
    if (lead.bought === "Sim") {
      current.compras += 1;
      current.receita += Number(lead.purchaseAmount || 0);
    }
    grouped.set(label, current);
  });
  return Array.from(grouped.values())
    .sort((a, b) => b.leads - a.leads)
    .slice(0, 20)
    .map((item) => ({ ...item, conversao: formatPercent(item.compras, item.leads) }));
}

function buildAiDailySeries(rows) {
  const grouped = new Map();
  rows.forEach((lead) => {
    const date = getLeadDateValue(lead);
    if (!date) return;
    const current = grouped.get(date) || { data: date, leads: 0, visitas: 0, compras: 0, receita: 0 };
    current.leads += 1;
    if (lead.visited === "Sim") current.visitas += 1;
    if (lead.bought === "Sim") {
      current.compras += 1;
      current.receita += Number(lead.purchaseAmount || 0);
    }
    grouped.set(date, current);
  });
  return Array.from(grouped.values()).sort((a, b) => a.data.localeCompare(b.data)).slice(-120);
}

function buildAnalyticsFilterSnapshot() {
  const mode = $(".segment-button.is-active")?.dataset.analyticsDateMode || "single";
  return {
    loja: getSelectedOptionText(analyticsStoreFilter),
    canal: getSelectedOptionText(analyticsChannelFilter),
    campanha: getSelectedOptionText(analyticsCampaignFilter),
    resultado: getSelectedOptionText(analyticsConclusionFilter),
    etapa_comercial: getSelectedOptionText(analyticsLifecycleFilter),
    qualificacao: getSelectedOptionText(analyticsQualifiedFilter),
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

function renderAiMessages() {
  if (!aiChatMessages) return;

  if (!aiMessages.length) {
    aiChatMessages.innerHTML = `
      <div class="ai-empty-state">
        <strong>Como posso ajudar?</strong>
        <span>Use o recorte atual de métricas para pedir padrões, gargalos, ranking de oportunidades ou ações para melhorar conversão.</span>
        <div class="ai-suggestion-grid">
          <button type="button" data-ai-suggestion="Gere um diagnóstico executivo deste período. Estruture em: resumo, evidências, gargalos, oportunidades priorizadas, ações para 7 dias e nível de confiança.">Diagnóstico executivo</button>
          <button type="button" data-ai-suggestion="Compare as campanhas por qualidade, vendas, receita e eficiência. Mostre onde aumentar, manter ou reduzir investimento e explique a evidência.">Otimizar campanhas</button>
          <button type="button" data-ai-suggestion="Analise o funil e identifique o maior vazamento entre captação, qualificação, agendamento, visita e compra. Sugira três testes mensuráveis.">Encontrar gargalos</button>
        </div>
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
  const suggestionButton = event.target.closest("[data-ai-suggestion]");
  if (suggestionButton) {
    aiChatInput.value = suggestionButton.dataset.aiSuggestion || "";
    autoResizeAiInput();
    aiChatForm.requestSubmit();
    return;
  }

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
  aiSettings = createDefaultAiSettings();
}

function normalizeAiSettings(saved) {
  const defaults = createDefaultAiSettings();
  if (!saved || typeof saved !== "object") return defaults;

  const provider = aiProviderOptions[saved.provider] ? saved.provider : defaults.provider;
  const model = String(saved.model || "").trim() || aiProviderOptions[provider].models[0];
  const savedPrompt = typeof saved.system_prompt === "string" ? saved.system_prompt.trim() : "";
  const apiKey = typeof saved.api_key === "string" ? saved.api_key.trim() : "";
  return {
    provider,
    models: {
      ...defaults.models,
      [provider]: model,
    },
    systemPrompt: savedPrompt && ![LEGACY_AI_SYSTEM_PROMPT, LEGACY_MULTI_STORE_AI_SYSTEM_PROMPT].includes(savedPrompt)
      ? savedPrompt
      : defaults.systemPrompt,
    apiKey,
    hasApiKey: Boolean(apiKey || saved.has_api_key),
    updatedAt: saved.updated_at || null,
    centralAvailable: true,
  };
}

function createDefaultAiSettings() {
  return {
    provider: "deepseek",
    models: {
      gemini: aiProviderOptions.gemini.models[0],
      deepseek: "deepseek-chat",
    },
    systemPrompt: DEFAULT_AI_SYSTEM_PROMPT,
    apiKey: "",
    hasApiKey: false,
    updatedAt: null,
    centralAvailable: true,
  };
}

function canConfigureAiSettings() {
  // A configuração central existe somente na tela de Configurações do Admin.
  // O modal de IA é exclusivo para chat e histórico em todos os contextos.
  return false;
}

function renderAiSettingsForm() {
  if (!aiSettingsForm) return;
  const canConfigure = canConfigureAiSettings();
  aiSettingsToggle.hidden = !canConfigure;
  aiSettingsToggle.disabled = !canConfigure;
  aiSettingsPanel.hidden = canConfigure ? aiSettingsPanel.hidden : true;
  aiSettingsPanel.toggleAttribute("inert", !canConfigure);
  aiSettingsPanel.setAttribute("aria-hidden", String(!canConfigure || aiSettingsPanel.hidden));
  aiSettingsForm.hidden = !canConfigure;
  aiSettingsForm.toggleAttribute("inert", !canConfigure);
  [aiProvider, aiModel, aiApiKey, aiSystemPrompt, aiValidateKeyButton].forEach((element) => {
    element.disabled = !canConfigure;
  });

  if (!canConfigure) {
    aiProvider.value = "";
    aiModel.innerHTML = "";
    aiApiKey.value = "";
    aiApiKey.placeholder = "";
    aiSystemPrompt.value = "";
    clearAiKeyStatus();
    clearAiSettingsMessage();
    aiChatDialogSettingsState();
    return;
  }

  aiSettingsPanel.removeAttribute("aria-hidden");
  aiProvider.value = aiSettings.provider;
  renderAiModelOptions(aiSettings.provider);
  aiModel.value = aiSettings.models[aiSettings.provider] || aiProviderOptions[aiSettings.provider].models[0];
  aiApiKey.value = "";
  aiApiKey.placeholder = aiSettings.hasApiKey
    ? "Chave já salva — deixe vazio para manter"
    : "Cole a chave da API";
  aiSystemPrompt.value = aiSettings.systemPrompt || DEFAULT_AI_SYSTEM_PROMPT;
  clearAiKeyStatus();
}

function renderAiModelOptions(provider) {
  renderAiModelOptionsFor(aiModel, provider, aiSettings.models[provider]);
}

function renderAiModelOptionsFor(select, provider, selectedModel = "") {
  const models = aiProviderOptions[provider]?.models || [];
  const current = selectedModel || models[0] || "";
  const entries = models.includes(current) ? models : [...models, current].filter(Boolean);
  select.innerHTML = entries
    .map((model) => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`)
    .join("");
  select.value = current;
}

function renderAdminAiSettingsForm() {
  if (!adminAiSettingsForm) return;
  const provider = aiSettings.provider || "deepseek";
  adminAiProvider.value = provider;
  renderAiModelOptionsFor(adminAiModel, provider, aiSettings.models[provider]);
  adminAiApiKey.value = "";
  adminAiApiKey.placeholder = aiSettings.hasApiKey
    ? "Chave já salva — deixe vazio para manter"
    : "Cole a chave da API";
  adminAiSystemPrompt.value = aiSettings.systemPrompt || DEFAULT_AI_SYSTEM_PROMPT;
  adminAiSavedStatus.textContent = aiSettings.hasApiKey
    ? `Chave protegida e salva${aiSettings.updatedAt ? ` · atualizada em ${formatDateTime(aiSettings.updatedAt)}` : ""}.`
    : "Nenhuma chave salva.";
  adminAiSavedStatus.classList.toggle("is-ready", aiSettings.hasApiKey);
}

function showAdminAiSettingsMessage(message, type = "error") {
  if (!adminAiSettingsMessage) return;
  adminAiSettingsMessage.textContent = message;
  adminAiSettingsMessage.classList.toggle("success", type === "success");
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
  if (!selectedAnalyticsStoreId) return [];
  let result = getDashboardLeads().filter((lead) => lead.storeId === selectedAnalyticsStoreId);
  if (analyticsChannelFilter.value) {
    result = result.filter((lead) => lead.channel === analyticsChannelFilter.value);
  }
  if (analyticsCampaignFilter.value) {
    result = result.filter((lead) => lead.campaign === analyticsCampaignFilter.value);
  }
  if (analyticsConclusionFilter.value) {
    result = result.filter((lead) => lead.conclusion === analyticsConclusionFilter.value);
  }
  if (analyticsLifecycleFilter.value) {
    result = result.filter((lead) => (lead.lifecycleStatus || inferLeadLifecycleStatus(lead)) === analyticsLifecycleFilter.value);
  }
  if (analyticsQualifiedFilter.value) {
    result = result.filter((lead) => Boolean(lead.qualified) === (analyticsQualifiedFilter.value === "yes"));
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

function clearAnalyticsFilters() {
  [
    analyticsChannelFilter,
    analyticsCampaignFilter,
    analyticsConclusionFilter,
    analyticsLifecycleFilter,
    analyticsQualifiedFilter,
    analyticsVisitedFilter,
    analyticsScheduledFilter,
    analyticsBoughtFilter,
    analyticsSingleDate,
    analyticsStartDate,
    analyticsEndDate,
  ].forEach((element) => {
    element.value = "";
  });
  analyticsCustomFilters.querySelectorAll("[data-custom-filter]").forEach((element) => {
    element.value = "";
  });
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
    technicianId: row.technician_id || null,
    technicianName: row.technician_name || "",
    technicianWhatsapp: "",
    prospectionEnabled: true,
    whatsappEnabled: false,
    avatarUrl: "",
  };
}

function mapTechnicianRow(row) {
  return {
    id: row.id,
    username: row.nick,
    fullName: row.full_name,
    createdAt: row.created_at,
    isActive: row.is_active !== false,
    storeLimit: Number(row.store_limit || 0),
    storeCount: Number(row.store_count || 0),
    prospectionStoreLimit: 0,
    prospectionStoreCount: 0,
    whatsappStoreLimit: 0,
    whatsappStoreCount: 0,
    whatsappPhone: "",
    avatarUrl: "",
  };
}

function applyAgencyWhatsappContext(data) {
  const context = firstRow(data);
  agencyWhatsappContext = context && typeof context === "object" && !Array.isArray(context) ? context : null;
  if (!agencyWhatsappContext) return;

  const contactByAgency = new Map(
    (agencyWhatsappContext.agencies || []).map((row) => [row.technician_id, String(row.whatsapp || "")]),
  );
  technicians.forEach((technician) => {
    technician.whatsappPhone = contactByAgency.get(technician.id) || "";
  });

  const profileContact = agencyWhatsappContext.profile || {};
  if (currentProfile.role === "technician") {
    currentProfile.agencyWhatsapp = String(profileContact.agency_whatsapp || "");
  }
  if (currentProfile.role === "store") {
    currentProfile.agencyWhatsapp = String(profileContact.agency_whatsapp || "");
    currentProfile.agencyName = String(profileContact.agency_name || "");
    const store = stores.find((item) => item.id === currentProfile.storeId);
    if (store) {
      store.technicianWhatsapp = currentProfile.agencyWhatsapp;
      if (currentProfile.agencyName) store.technicianName = currentProfile.agencyName;
    }
  }

  stores.forEach((store) => {
    store.technicianWhatsapp = store.technicianWhatsapp || contactByAgency.get(store.technicianId) || "";
  });
}

function normalizeProspectionEntitlements(data) {
  const value = firstRow(data);
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value;
}

function applyProspectionEntitlements(data) {
  const entitlements = normalizeProspectionEntitlements(data);
  if (!entitlements) {
    stores.forEach((store) => { store.prospectionEnabled = false; });
    technicians.forEach((technician) => {
      technician.prospectionStoreLimit = 0;
      technician.prospectionStoreCount = 0;
    });
    return;
  }

  const storeAccess = new Map((entitlements.stores || []).map((row) => [row.store_id, row.prospection_enabled === true]));
  stores.forEach((store) => {
    store.prospectionEnabled = storeAccess.get(store.id) === true;
  });

  const agencyAccess = new Map((entitlements.technicians || []).map((row) => [row.technician_id, row]));
  technicians.forEach((technician) => {
    const access = agencyAccess.get(technician.id) || {};
    technician.prospectionStoreLimit = Number(access.prospection_store_limit || 0);
    technician.prospectionStoreCount = Number(access.prospection_store_count || 0);
  });
}

function normalizeWhatsappEntitlements(data) {
  const value = firstRow(data);
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value;
}

function applyWhatsappEntitlements(data) {
  const entitlements = normalizeWhatsappEntitlements(data);
  if (!entitlements) {
    stores.forEach((store) => { store.whatsappEnabled = false; });
    technicians.forEach((technician) => {
      technician.whatsappStoreLimit = 0;
      technician.whatsappStoreCount = 0;
    });
    return;
  }

  const storeAccess = new Map((entitlements.stores || []).map((row) => [row.store_id, row.whatsapp_enabled === true]));
  stores.forEach((store) => {
    store.whatsappEnabled = storeAccess.get(store.id) === true;
  });

  const agencyAccess = new Map((entitlements.technicians || []).map((row) => [row.technician_id, row]));
  technicians.forEach((technician) => {
    const access = agencyAccess.get(technician.id) || {};
    technician.whatsappStoreLimit = Number(access.whatsapp_store_limit || 0);
    technician.whatsappStoreCount = Number(access.whatsapp_store_count || 0);
  });
}

function applyProfileAvatars() {
  const avatarByAccount = new Map(
    profileAvatars.map((row) => [`${row.account_type}:${row.account_id}`, row.avatar_url || ""]),
  );
  stores.forEach((store) => {
    store.avatarUrl = avatarByAccount.get(`store:${store.id}`) || "";
  });
  technicians.forEach((technician) => {
    technician.avatarUrl = avatarByAccount.get(`technician:${technician.id}`) || "";
  });
}

function getProfileAvatar(accountType, accountId) {
  return profileAvatars.find((row) => row.account_type === accountType && row.account_id === accountId)?.avatar_url || "";
}

function renderCurrentSessionAvatar() {
  if (!sessionAvatar) return;
  if (!storeView.hidden && activeStoreContext) {
    setAvatarPreview(sessionAvatar, activeStoreContext.avatarUrl || "", "store");
    return;
  }
  if (activeTechnicianContext) {
    setAvatarPreview(sessionAvatar, activeTechnicianContext.avatarUrl || "", "building");
    return;
  }
  if (currentProfile?.role === "technician") {
    setAvatarPreview(sessionAvatar, getProfileAvatar("technician", currentProfile.id), "building");
    return;
  }
  if (currentProfile?.role === "store") {
    setAvatarPreview(sessionAvatar, getProfileAvatar("store", currentProfile.storeId), "store");
    return;
  }
  setAvatarPreview(sessionAvatar, "", "user-shield");
}

function renderProfileAvatar(avatarUrl, name, fallbackIcon) {
  const label = escapeHtml(name || "Perfil");
  return avatarUrl
    ? `<span class="profile-avatar management-avatar"><img src="${escapeHtml(avatarUrl)}" alt="${label}" /></span>`
    : `<span class="profile-avatar management-avatar" aria-hidden="true"><i class="fa-solid fa-${fallbackIcon}"></i></span>`;
}

function setAvatarPreview(target, avatarUrl, fallbackIcon) {
  if (!target) return;
  target.innerHTML = avatarUrl
    ? `<img src="${escapeHtml(avatarUrl)}" alt="Imagem de perfil" />`
    : `<i class="fa-solid fa-${fallbackIcon}"></i>`;
}

function previewAvatarFile(input, preview, fallbackIcon) {
  const file = input.files?.[0];
  setAvatarFileName(input, file);
  if (!file) {
    setAvatarPreview(preview, preview === managedAccountAvatarPreview ? managedAccountCurrentAvatar : "", fallbackIcon);
    return;
  }
  const reader = new FileReader();
  reader.onload = () => setAvatarPreview(preview, String(reader.result || ""), fallbackIcon);
  reader.readAsDataURL(file);
}

function setAvatarFileName(input, file = null) {
  const target = document.getElementById(`${input.id}Name`);
  if (!target) return;
  const emptyLabel = input === managedAccountAvatar ? "Nenhuma nova imagem" : "Nenhuma imagem selecionada";
  target.textContent = file?.name || emptyLabel;
  target.title = file?.name || "";
  target.classList.toggle("has-file", Boolean(file));
}

async function avatarFileToDataUrl(file) {
  if (!file) return null;
  if (!file.type.startsWith("image/")) throw new Error("Selecione um arquivo de imagem válido.");
  if (file.size > 8 * 1024 * 1024) throw new Error("A imagem deve ter no máximo 8 MB.");

  const source = await readFileAsDataUrl(file);
  const image = await loadAvatarImage(source);
  const maxSide = 512;
  const scale = Math.min(maxSide / image.width, maxSide / image.height, 1);
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(image.width * scale));
  canvas.height = Math.max(1, Math.round(image.height * scale));
  const context = canvas.getContext("2d");
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  const optimized = canvas.toDataURL("image/webp", 0.82);
  if (optimized.length > 750000) throw new Error("Não foi possível reduzir a imagem. Escolha um arquivo menor.");
  return optimized;
}

function readFileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(new Error("Não foi possível ler a imagem."));
    reader.readAsDataURL(file);
  });
}

function loadAvatarImage(source) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("Não foi possível processar a imagem."));
    image.src = source;
  });
}

function mapAccountUsage(row) {
  if (!row) return null;
  return {
    technicianId: row.technician_id,
    storeLimit: Number(row.store_limit || 0),
    storeCount: Number(row.store_count || 0),
    prospectionStoreLimit: 0,
    prospectionStoreCount: 0,
    whatsappStoreLimit: 0,
    whatsappStoreCount: 0,
    whatsappPhone: "",
  };
}

function mapLeadRow(row, intelligence = null) {
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
    lifecycleStatus: intelligence?.lifecycle_status || "",
    qualified: Boolean(intelligence?.qualified),
    lossReason: intelligence?.loss_reason || "",
    ownerName: intelligence?.owner_name || "",
    email: intelligence?.email || "",
    firstResponseAt: intelligence?.first_response_at || null,
    qualifiedAt: intelligence?.qualified_at || null,
    lostAt: intelligence?.lost_at || null,
    purchasedAt: intelligence?.purchased_at || null,
    utmSource: intelligence?.utm_source || "",
    utmMedium: intelligence?.utm_medium || "",
    utmCampaign: intelligence?.utm_campaign || "",
    utmContent: intelligence?.utm_content || "",
    utmTerm: intelligence?.utm_term || "",
    campaignExternalId: intelligence?.campaign_external_id || "",
    adsetExternalId: intelligence?.adset_external_id || "",
    adExternalId: intelligence?.ad_external_id || "",
    creativeExternalId: intelligence?.creative_external_id || "",
    gclid: intelligence?.gclid || "",
    gbraid: intelligence?.gbraid || "",
    wbraid: intelligence?.wbraid || "",
    fbclid: intelligence?.fbclid || "",
    fbc: intelligence?.fbc || "",
    fbp: intelligence?.fbp || "",
    landingPageUrl: intelligence?.landing_page_url || "",
    externalLeadId: intelligence?.external_lead_id || "",
    marketingConsent: Boolean(intelligence?.marketing_consent),
    returningCustomer: Boolean(intelligence?.returning_customer),
    customValueRows,
    customValues: Object.fromEntries(customValueRows.map((item) => [item.categoryId, item.value])),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function mapAdDailyMetricRow(row) {
  return {
    id: row.id,
    storeId: row.store_id,
    date: row.metric_date,
    platform: row.platform,
    campaignName: row.campaign_name || "",
    campaignExternalId: row.campaign_external_id || "",
    spend: Number(row.spend || 0),
    impressions: Number(row.impressions || 0),
    reach: Number(row.reach || 0),
    clicks: Number(row.clicks || 0),
    platformLeads: Number(row.platform_leads || 0),
    platformConversions: Number(row.platform_conversions || 0),
    source: row.source || "manual",
  };
}

function mapMarketingTargetRow(row) {
  return {
    storeId: row.store_id,
    monthlyBudget: toOptionalNumber(row.monthly_budget),
    leadGoal: toOptionalNumber(row.lead_goal),
    qualifiedGoal: toOptionalNumber(row.qualified_goal),
    salesGoal: toOptionalNumber(row.sales_goal),
    revenueGoal: toOptionalNumber(row.revenue_goal),
    targetCpl: toOptionalNumber(row.target_cpl),
    targetCac: toOptionalNumber(row.target_cac),
    targetRoas: toOptionalNumber(row.target_roas),
  };
}

function toOptionalNumber(value) {
  return value === null || value === undefined || value === "" ? null : Number(value);
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
        fixed: fixedOptionGroups.has(group),
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

function applyCategoryLabelRows(rows) {
  Object.assign(labels, defaultLabels);
  (rows || []).forEach((row) => {
    const group = row.group_key;
    const label = String(row.label || "").trim();
    if (optionGroups.includes(group) && label) labels[group] = label;
  });
  analyticsSections.forEach((section) => {
    section.label = labels[section.optionGroup] || section.label;
  });
  dirtyGroupLabels.clear();
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

function buildLeadIntelligencePayload() {
  const existingLead = leads.find((lead) => lead.id === editingIdInput.value) || {};
  let status = leadLifecycleStatus?.value || "new";
  if (selectedValues.bought === "Sim") status = "won";
  const qualifiedStatuses = new Set(["qualified", "scheduled", "visited", "won"]);
  return {
    lifecycle_status: status,
    qualified: qualifiedStatuses.has(status),
    loss_reason: status === "lost" ? existingLead.lossReason || null : null,
    owner_name: leadOwnerName?.value.trim() || null,
    email: existingLead.email || null,
    returning_customer: Boolean(existingLead.returningCustomer),
    marketing_consent: Boolean(existingLead.marketingConsent),
    utm_source: existingLead.utmSource || null,
    utm_medium: existingLead.utmMedium || null,
    utm_campaign: existingLead.utmCampaign || null,
    utm_content: existingLead.utmContent || null,
    campaign_external_id: existingLead.campaignExternalId || null,
    adset_external_id: existingLead.adsetExternalId || null,
    ad_external_id: existingLead.adExternalId || null,
    gclid: existingLead.gclid || existingLead.gbraid || existingLead.wbraid || null,
    fbclid: existingLead.fbclid || existingLead.fbc || null,
    landing_page_url: existingLead.landingPageUrl || null,
  };
}

function syncLeadIntelligenceVisibility() {
  if (!leadLifecycleStatus) return;
}

function inferLeadLifecycleStatus(lead) {
  if (lead?.bought === "Sim") return "won";
  if (lead?.visited === "Sim") return "visited";
  if (lead?.scheduled === "Sim") return "scheduled";
  return "new";
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
        fixed: fixedOptionGroups.has(group),
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

function normalizeWhatsAppNumber(value) {
  const digits = onlyDigits(value);
  if (digits.length === 10 || digits.length === 11) return `55${digits}`;
  return digits;
}

function isValidWhatsAppNumber(value) {
  const normalized = normalizeWhatsAppNumber(value);
  return /^[1-9]\d{11,14}$/.test(normalized);
}

function formatWhatsAppInput(value) {
  const digits = onlyDigits(value);
  const local = digits.startsWith("55") && (digits.length === 12 || digits.length === 13)
    ? digits.slice(2)
    : digits;
  if (local.length <= 11) return formatPhone(local);
  return `+${digits.slice(0, 15)}`;
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

function getCurrentWeekDateRange() {
  const today = new Date();
  const start = new Date(today);
  const day = today.getDay();
  const distanceToMonday = day === 0 ? -6 : 1 - day;
  start.setDate(today.getDate() + distanceToMonday);

  const end = new Date(start);
  end.setDate(start.getDate() + 6);

  return {
    start: toLocalDateInput(start),
    end: toLocalDateInput(end),
  };
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

function getLeadCreatedDateValue(lead) {
  const value = lead?.createdAt;
  if (!value) return "";
  if (/^\d{4}-\d{2}-\d{2}$/.test(String(value))) return String(value);
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 10);
  return toLocalDateInput(date);
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

function bindFocusModality() {
  document.addEventListener("keydown", (event) => {
    if (event.key === "Tab" || event.key.startsWith("Arrow") || ["Home", "End"].includes(event.key)) {
      document.body.classList.add("is-keyboard-navigation");
    }
  }, true);
  document.addEventListener("pointerdown", () => {
    document.body.classList.remove("is-keyboard-navigation");
  }, true);
}

function toggleTheme() {
  setTheme(document.body.classList.contains("is-dark") ? "light" : "dark");
}

function setTheme(theme) {
  const isDark = theme === "dark";
  document.body.classList.toggle("is-dark", isDark);
  document.body.classList.toggle("is-dark-mode", isDark);
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
  if (!target) {
    if (message) showAppNotification(message, type);
    return;
  }
  target.textContent = message;
  target.classList.toggle("success", type === "success");
  if (type === "success") showAppNotification(message, "success");
}
