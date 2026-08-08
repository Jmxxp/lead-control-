(() => {
  "use strict";

  const root = document.querySelector("#whatsappView");
  if (!root) return;

  const SECTIONS = [
    ["conversations", "fa-comments", "Conversas"],
    ["contacts", "fa-address-book", "Contatos"],
    ["campaigns", "fa-paper-plane", "Disparos"],
    ["templates", "fa-layer-group", "Templates"],
    ["settings", "fa-sliders", "Configurações"],
    ["webhooks", "fa-code-branch", "Webhooks"],
    ["logs", "fa-list-check", "Logs"],
  ];
  const EMOJIS = ["😀", "😊", "👍", "🙏", "❤️", "🎉", "✅", "📍", "📅", "👋", "🔥", "💚"];
  const POLL_INTERVAL = 15000;
  const MAX_MEDIA_OBJECT_URLS = 12;
  const STYLE_TOKENS = new Set([
    "approved", "cancelled", "canceled", "completed", "connected", "critical",
    "debug", "delivered", "disabled", "disconnected", "draft", "error", "expiring",
    "failed", "ignored", "info", "paused", "pending", "played", "processed",
    "processing", "queued", "read", "received", "rejected", "running", "scheduled",
    "sent", "success", "token_expiring", "warning",
  ]);
  const CONFIG_MUTATIONS = new Set([
    "disconnect", "duplicate-template", "edit-template", "new-connection", "new-template",
    "reconnect", "reprocess-webhook", "start-wizard", "sync-templates", "test-connection",
    "update-token", "validate-connection", "wizard-back", "wizard-finish",
    "wizard-register-webhook", "wizard-validate",
  ]);
  const SEND_MUTATIONS = new Set([
    "delete-contact", "edit-contact", "edit-current-contact", "import-contacts", "new-contact",
    "new-conversation", "open-template-picker", "pick-attachment", "send-template-test",
    "start-contact-conversation", "toggle-conversation-status", "toggle-emoji", "toggle-favorite",
  ]);

  let bridge = null;
  let active = false;
  let loading = false;
  let upgradePreview = false;
  let backendReady = true;
  let pollTimer = null;
  let activeSection = "conversations";
  let selectedStoreId = "";
  let selectedConnectionId = "";
  let templatesConnectionId = "";
  let selectedConversationId = "";
  let messages = [];
  let messagesHasMore = false;
  let detailRecord = null;
  let emojiOpen = false;
  let wizard = null;
  let busy = false;
  let pendingConfirmation = null;
  let dialogReturnFocus = null;
  let searchTimer = null;
  const mediaObjectUrls = new Map();
  let searches = { conversations: "", contacts: "", campaigns: "", templates: "", webhooks: "", logs: "" };
  let filters = { conversations: "all", contactTag: "all", campaignStatus: "all", templateStatus: "all", webhookStatus: "all", logLevel: "all", logType: "all" };
  let data = emptyData();
  let pagination = emptyPagination();
  let contextGeneration = 0;
  let requestVersions = Object.create(null);

  function emptyData() {
    return {
      connections: [],
      contacts: [],
      conversations: [],
      campaigns: [],
      templates: [],
      webhooks: [],
      logs: [],
      stats: {},
      counts: {},
      permissions: {},
      tags: [],
      store: null,
    };
  }

  function emptyPagination() {
    return {
      conversations: { limit: 80, total: 0, hasMore: false },
      contacts: { limit: 200, total: 0, hasMore: false },
      campaigns: { limit: 100, total: 0, hasMore: false },
      webhooks: { limit: 100, total: 0, hasMore: false },
      logs: { limit: 150, total: 0, hasMore: false },
    };
  }

  function beginRequest(key) {
    requestVersions[key] = (requestVersions[key] || 0) + 1;
    return { key, version: requestVersions[key], generation: contextGeneration, storeId: selectedStoreId };
  }

  function requestIsCurrent(request, extraCheck = true) {
    return Boolean(
      extraCheck
      && active
      && request.generation === contextGeneration
      && request.storeId === selectedStoreId
      && request.version === requestVersions[request.key],
    );
  }

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

  const formatDateTime = (value) => value
    ? new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short" }).format(new Date(value))
    : "—";

  const formatTime = (value) => value
    ? new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit" }).format(new Date(value))
    : "";

  const formatNumber = (value) => new Intl.NumberFormat("pt-BR").format(Number(value || 0));

  function styleToken(value, fallback = "pending") {
    const token = normalize(value).replace(/[^a-z0-9_-]/g, "-");
    return STYLE_TOKENS.has(token) ? token : fallback;
  }

  function safeMediaUrl(value) {
    if (!value) return "";
    try {
      const raw = String(value).trim();
      const parsed = new URL(raw, window.location.origin);
      if (parsed.protocol === "blob:" || parsed.protocol === "https:") return parsed.href;
      if (["http:", "https:"].includes(parsed.protocol) && parsed.origin === window.location.origin) return parsed.href;
    } catch (_) { /* URL inválida */ }
    return "";
  }

  function canConfigure() {
    return backendReady && data.permissions?.can_configure === true;
  }

  function canSend() {
    return backendReady && data.permissions?.can_send === true;
  }

  function canManageCampaigns() {
    return backendReady && data.permissions?.can_manage_campaigns === true;
  }

  function hasMarketingConsent(contact) {
    if (!contact || contact.is_active === false || contact.is_blocked === true || contact.opt_out_at || contact.revoked_at) return false;
    if (typeof contact.marketing_consent_active === "boolean") return contact.marketing_consent_active;
    return contact.opt_in === true || contact.marketing_opt_in === true;
  }

  function permissionDenied(message = "Seu perfil não possui permissão para esta operação.") {
    bridge?.notify?.(message, "warning");
    return false;
  }

  function entitlementErrorParts(error) {
    const code = normalize(error?.code || error?.error?.code || "");
    const message = normalize([
      error?.message,
      error?.error_description,
      error?.details?.message,
      typeof error?.details === "string" ? error.details : "",
    ].filter(Boolean).join(" "));
    return { code, message };
  }

  function isDefinitiveEntitlementError(error) {
    const { code, message } = entitlementErrorParts(error);
    return code.includes("whatsapp_access")
      || code.includes("feature_access_disabled")
      || /(?:whatsapp.*sem acesso|sem acesso.*whatsapp|acesso.*whatsapp.*nao.*liberad|whatsapp.*desativad|sem licenca.*whatsapp|licenca.*whatsapp.*nao encontrada)/.test(message);
  }

  function isAmbiguousPermissionError(error) {
    const { message } = entitlementErrorParts(error);
    return /(?:cliente|conexao|conversa|campanha|contato|template|webhook|evento|mensagem|anexo|log).*sem permissao/.test(message);
  }

  async function confirmWhatsappAccessRevoked(storeId) {
    if (!storeId || !bridge?.rpc) return false;
    try {
      const response = await bridge.rpc("lc_get_whatsapp_entitlements");
      const payload = Array.isArray(response) ? response[0] : (response?.data || response);
      if (!payload || !Array.isArray(payload.stores)) return false;
      const entitlement = payload.stores.find((item) => String(item?.store_id || "") === String(storeId));
      return !entitlement || entitlement.whatsapp_enabled === false;
    } catch (_) {
      // Um erro de revalidacao nao prova perda de licenca. A operacao original
      // continua protegida pelo servidor e o frontend evita um bloqueio falso.
      return false;
    }
  }

  async function handleEntitlementLoss(error) {
    const definitive = isDefinitiveEntitlementError(error);
    const ambiguous = isAmbiguousPermissionError(error);
    if (!definitive && !ambiguous) return false;
    const revokedStoreId = selectedStoreId;
    const revokedGeneration = contextGeneration;
    if (!definitive && !(await confirmWhatsappAccessRevoked(revokedStoreId))) return false;
    if (!revokedStoreId || selectedStoreId !== revokedStoreId || contextGeneration !== revokedGeneration) return false;

    releaseMediaObjectUrls();
    closeDialog();
    clearTimeout(pollTimer);
    pollTimer = null;
    loading = false;
    data = emptyData();
    pagination = emptyPagination();
    messages = [];
    messagesHasMore = false;
    selectedConnectionId = "";
    selectedConversationId = "";

    const revokedStore = (bridge?.stores || []).find((store) => store.id === revokedStoreId);
    if (revokedStore) revokedStore.whatsappEnabled = false;
    bridge?.onAccessRevoked?.(revokedStoreId);
    upgradePreview = bridge?.profile?.role === "store";
    selectedStoreId = "";
    if (active) render();
    bridge?.notify?.(
      upgradePreview
        ? "O acesso ao WhatsApp foi desativado. Solicite a reativação à sua agência."
        : "O WhatsApp deste cliente foi desativado. Selecione outra empresa liberada.",
      "warning",
    );
    return true;
  }

  function readableError(error) {
    const message = String(error?.message || error || "Não foi possível concluir a operação.");
    if (/wa_|whatsapp-api|could not find the function|does not exist/i.test(message)) {
      backendReady = false;
      return "A estrutura do WhatsApp ainda não foi instalada ou publicada no Supabase.";
    }
    return message.replace(/^error:\s*/i, "");
  }

  function arrayFrom(value) {
    if (Array.isArray(value)) return value;
    if (Array.isArray(value?.items)) return value.items;
    if (Array.isArray(value?.data)) return value.data;
    return [];
  }

  function normalizeBootstrap(raw) {
    const payload = raw?.bootstrap || raw?.data || raw || {};
    return {
      connections: payload.connections ? arrayFrom(payload.connections) : data.connections,
      contacts: payload.contacts ? arrayFrom(payload.contacts) : data.contacts,
      conversations: payload.conversations ? arrayFrom(payload.conversations) : data.conversations,
      campaigns: payload.campaigns ? arrayFrom(payload.campaigns) : data.campaigns,
      templates: payload.templates ? arrayFrom(payload.templates) : data.templates,
      webhooks: payload.webhooks || payload.webhook_events ? arrayFrom(payload.webhooks || payload.webhook_events) : data.webhooks,
      logs: payload.logs ? arrayFrom(payload.logs) : data.logs,
      stats: payload.stats && typeof payload.stats === "object" ? payload.stats : {},
      counts: payload.counts && typeof payload.counts === "object" ? payload.counts : {},
      permissions: payload.permissions && typeof payload.permissions === "object" ? payload.permissions : {},
      tags: arrayFrom(payload.tags),
      store: payload.store || null,
    };
  }

  function scopedStores() {
    const stores = (bridge?.stores || []).filter((store) => store.whatsappEnabled === true);
    if (bridge?.profile?.role === "store") return stores.filter((store) => store.id === bridge.profile.storeId);
    if (bridge?.profile?.role === "technician") return stores.filter((store) => store.technicianId === bridge.profile.id);
    if (bridge?.initialAgencyId) return stores.filter((store) => store.technicianId === bridge.initialAgencyId);
    return stores;
  }

  function storeById(id) {
    return (bridge?.stores || []).find((store) => store.id === id) || null;
  }

  function currentConnection() {
    return data.connections.find((connection) => connection.id === selectedConnectionId)
      || data.connections.find((connection) => connection.status === "connected")
      || data.connections[0]
      || null;
  }

  function connectionStatus(connection = currentConnection()) {
    if (!connection || connection.status === "disconnected" || connection.is_active === false) {
      return { key: "disconnected", label: "Desconectado", icon: "fa-circle-xmark" };
    }
    const expiresAt = connection.token_expires_at || connection.tokenExpiresAt;
    if (connection.status === "error" || (expiresAt && new Date(expiresAt).getTime() <= Date.now())) {
      return { key: "disconnected", label: expiresAt && new Date(expiresAt).getTime() <= Date.now() ? "Token expirado" : "Conexão com erro", icon: "fa-circle-xmark" };
    }
    if (["expiring", "token_expiring"].includes(connection.status) || (expiresAt && new Date(expiresAt).getTime() - Date.now() < 7 * 86400000)) {
      return { key: "expiring", label: "Token expirando", icon: "fa-triangle-exclamation" };
    }
    if (["connected", "active", "valid"].includes(connection.status)) {
      return { key: "connected", label: "Conectado", icon: "fa-circle-check" };
    }
    return { key: "disconnected", label: "Desconectado", icon: "fa-circle-xmark" };
  }

  async function activate(nextBridge) {
    releaseMediaObjectUrls();
    contextGeneration += 1;
    requestVersions = Object.create(null);
    bridge = nextBridge;
    active = true;
    loading = true;
    upgradePreview = bridge?.profile?.role === "store" && bridge?.whatsappAccessGranted === false;
    backendReady = true;
    activeSection = "conversations";
    selectedStoreId = resolveInitialStoreId();
    selectedConnectionId = "";
    templatesConnectionId = "";
    selectedConversationId = "";
    messages = [];
    messagesHasMore = false;
    data = emptyData();
    pagination = emptyPagination();
    root.innerHTML = loadingMarkup();
    if (!upgradePreview) await loadBootstrap();
    loading = false;
    if (!active) return;
    render();
    if (!upgradePreview) schedulePoll();
  }

  function resolveInitialStoreId() {
    const allowed = scopedStores();
    const candidates = [bridge?.initialStoreId, bridge?.profile?.storeId].filter(Boolean);
    return candidates.find((id) => allowed.some((store) => store.id === id)) || allowed[0]?.id || "";
  }

  function deactivate() {
    contextGeneration += 1;
    active = false;
    upgradePreview = false;
    clearTimeout(pollTimer);
    pollTimer = null;
    releaseMediaObjectUrls();
    closeDialog();
  }

  async function refreshContext(nextContext = {}) {
    contextGeneration += 1;
    requestVersions = Object.create(null);
    bridge = { ...bridge, ...nextContext };
    if (!active) return;
    upgradePreview = bridge?.profile?.role === "store" && bridge?.whatsappAccessGranted === false;
    if (upgradePreview) {
      selectedStoreId = "";
      data = emptyData();
      clearTimeout(pollTimer);
      pollTimer = null;
      render();
      return;
    }
    if (!scopedStores().some((store) => store.id === selectedStoreId)) selectedStoreId = resolveInitialStoreId();
    await loadBootstrap({ silent: true });
    render();
    schedulePoll();
  }

  async function loadBootstrap({ silent = false } = {}) {
    if (!selectedStoreId) {
      data = emptyData();
      return;
    }
    const request = beginRequest("bootstrap");
    if (!silent) loading = true;
    try {
      let response;
      try {
        response = await bridge.edge("bootstrap", { store_id: selectedStoreId, compact: silent });
      } catch (edgeError) {
        if (!requestIsCurrent(request)) return;
        response = await bridge.rpc("wa_get_bootstrap", { p_store_id: selectedStoreId });
      }
      if (!requestIsCurrent(request)) return;
      data = normalizeBootstrap(Array.isArray(response) ? response[0] : response);
      backendReady = true;
      if (!selectedConnectionId || !data.connections.some((item) => item.id === selectedConnectionId)) {
        selectedConnectionId = data.connections.find((item) => ["connected", "token_expiring"].includes(item.status))?.id || data.connections[0]?.id || "";
      }
      if (!selectedConversationId || !data.conversations.some((item) => item.id === selectedConversationId)) {
        selectedConversationId = data.conversations[0]?.id || "";
        messages = [];
      }
      const selectedConversation = data.conversations.find((item) => item.id === selectedConversationId);
      if (selectedConversation?.connection_id) selectedConnectionId = selectedConversation.connection_id;
      await loadSectionData(activeSection, { silent: true });
    } catch (error) {
      if (!requestIsCurrent(request)) return;
      if (await handleEntitlementLoss(error)) return;
      backendReady = false;
      data = emptyData();
      if (!silent) bridge.notify(readableError(error), "error");
    } finally {
      if (requestIsCurrent(request)) loading = false;
    }
  }

  async function loadSectionData(section, { silent = false, append = false, refresh = false } = {}) {
    if (!selectedStoreId || !bridge?.rpc) return;
    const request = beginRequest(`section:${section}`);
    try {
      let response = null;
      const page = pagination[section];
      const offset = append ? (data[section]?.length || 0) : 0;
      if (section === "conversations") {
        const conversationStatus = ["open", "closed"].includes(filters.conversations)
          ? filters.conversations
          : null;
        response = await bridge.rpc("wa_list_conversations", {
          p_store_id: selectedStoreId,
          p_search: searches.conversations || null,
          p_status: conversationStatus,
          p_unread_only: filters.conversations === "unread",
          p_favorites_only: filters.conversations === "favorites",
          p_limit: page.limit,
          p_offset: offset,
        });
        if (!requestIsCurrent(request)) return;
        updatePagedCollection("conversations", response, append, refresh);
        if (!selectedConversationId || !data.conversations.some((item) => item.id === selectedConversationId)) selectedConversationId = data.conversations[0]?.id || "";
        const selectedConversation = data.conversations.find((item) => item.id === selectedConversationId);
        if (selectedConversation?.connection_id) selectedConnectionId = selectedConversation.connection_id;
        if (!append && selectedConversationId) await loadMessages(selectedConversationId, { silent: true });
      } else if (section === "contacts") {
        const selectedTag = data.tags.find((tag) => tag.name === filters.contactTag);
        response = await bridge.rpc("wa_list_contacts", {
          p_store_id: selectedStoreId,
          p_search: searches.contacts || null,
          p_tag_ids: selectedTag?.id ? [selectedTag.id] : null,
          p_limit: page.limit,
          p_offset: offset,
        });
        if (!requestIsCurrent(request)) return;
        updatePagedCollection("contacts", response, append, refresh);
      } else if (section === "campaigns") {
        response = await bridge.rpc("wa_list_campaigns", { p_store_id: selectedStoreId, p_status: filters.campaignStatus === "all" ? null : filters.campaignStatus, p_limit: page.limit, p_offset: offset, p_search: searches.campaigns || null });
        if (!requestIsCurrent(request)) return;
        updatePagedCollection("campaigns", response, append, refresh);
      } else if (section === "templates") {
        response = await bridge.rpc("wa_list_templates", { p_store_id: selectedStoreId, p_connection_id: selectedConnectionId || null });
        if (!requestIsCurrent(request)) return;
        data.templates = arrayFrom(response);
        templatesConnectionId = selectedConnectionId;
      } else if (section === "webhooks") {
        response = await bridge.rpc("wa_list_webhook_events", { p_store_id: selectedStoreId, p_search: searches.webhooks || null, p_status: filters.webhookStatus === "all" ? null : filters.webhookStatus, p_limit: page.limit, p_offset: offset });
        if (!requestIsCurrent(request)) return;
        updatePagedCollection("webhooks", response, append, refresh);
      } else if (section === "logs") {
        response = await bridge.rpc("wa_list_logs", { p_store_id: selectedStoreId, p_level: filters.logLevel === "all" ? null : filters.logLevel, p_category: filters.logType === "all" ? null : filters.logType, p_search: searches.logs || null, p_limit: page.limit, p_offset: offset });
        if (!requestIsCurrent(request)) return;
        updatePagedCollection("logs", response, append, refresh);
      }
    } catch (error) {
      if (!requestIsCurrent(request)) return;
      if (await handleEntitlementLoss(error)) return;
      if (!silent) bridge.notify(readableError(error), "error");
    }
  }

  function updatePagedCollection(section, response, append, refresh = false) {
    const items = arrayFrom(response);
    const existing = append || refresh ? data[section] || [] : [];
    const seen = new Set(existing.map((item) => String(item.id)));
    data[section] = refresh
      ? [...items, ...existing.filter((item) => !items.some((fresh) => String(fresh.id) === String(item.id)))]
      : [...existing, ...items.filter((item) => !seen.has(String(item.id)))];
    const explicitTotal = Number(response?.total);
    const total = Number.isFinite(explicitTotal) && explicitTotal >= 0 ? explicitTotal : data[section].length;
    pagination[section].total = total;
    pagination[section].hasMore = data[section].length < total || (!Number.isFinite(explicitTotal) && items.length === pagination[section].limit);
  }

  function schedulePoll() {
    clearTimeout(pollTimer);
    if (!active || upgradePreview) return;
    pollTimer = setTimeout(async () => {
      const activeElement = document.activeElement;
      const userIsEditing = Boolean(
        root.querySelector(".wa-dialog")
        || (root.contains(activeElement) && activeElement?.matches?.("input, textarea, select"))
        || root.querySelector("#waComposerForm textarea")?.value.trim(),
      );
      if (active && !document.hidden && !userIsEditing && ["conversations", "campaigns"].includes(activeSection)) {
        await loadSectionData(activeSection, { silent: true, refresh: true });
        if (active) renderContent();
      }
      schedulePoll();
    }, POLL_INTERVAL);
  }

  function loadingMarkup() {
    return `<div class="whatsapp-loading-card" role="status"><span class="whatsapp-loading-icon"><i class="fa-solid fa-circle-notch fa-spin"></i></span><div><p class="eyebrow">WhatsApp Business</p><h2>Sincronizando a central</h2><span>Carregando conexões, conversas e filas com segurança.</span></div></div>`;
  }

  function renderFatalError(message) {
    root.innerHTML = `<div class="whatsapp-error-card" role="alert"><span class="whatsapp-loading-icon"><i class="fa-solid fa-triangle-exclamation"></i></span><div><p class="eyebrow">WhatsApp indisponível</p><h2>Não foi possível carregar o módulo</h2><span>${escapeHtml(message)}</span></div></div>`;
  }

  function render() {
    if (!active || loading) return;
    if (upgradePreview) {
      renderUpgradeExperience();
      return;
    }
    const store = storeById(selectedStoreId);
    const status = connectionStatus();
    root.innerHTML = `<section class="wa-shell">
      <header class="wa-header">
        <div class="wa-header-identity"><span class="wa-brand-icon"><i class="fa-brands fa-whatsapp"></i></span><div><p class="eyebrow">Central oficial</p><h2>WhatsApp Business</h2><span>${escapeHtml(store?.name || "Selecione uma empresa")} · comunicação organizada em um único núcleo</span></div></div>
        <div class="wa-header-actions">
          ${storeSelectorMarkup()}
          ${connectionSelectorMarkup()}
          <span class="wa-connection-status is-${status.key}"><i class="fa-solid ${status.icon}"></i>${status.label}</span>
          <button class="wa-icon-button" type="button" data-wa-action="refresh" aria-label="Atualizar dados" title="Atualizar dados"><i class="fa-solid fa-rotate"></i></button>
          <button class="wa-button is-secondary" type="button" data-wa-action="open-leads"><i class="fa-solid fa-arrow-left"></i>Leads</button>
        </div>
      </header>
      ${!backendReady ? installNoticeMarkup() : ""}
      <div class="wa-layout">
        ${navigationMarkup()}
        <main class="wa-content" data-wa-content>${sectionMarkup()}</main>
      </div>
    </section>`;
  }

  function renderUpgradeExperience() {
    const profile = bridge?.profile || {};
    const store = storeById(profile.storeId) || { id: profile.storeId, name: profile.storeName || profile.username || "Sua empresa" };
    const agencyName = store.technicianName || profile.agencyName || "sua agência";
    const agencyPhone = onlyDigits(store.technicianWhatsapp || profile.agencyWhatsapp || "");
    const whatsappPhone = agencyPhone.length === 10 || agencyPhone.length === 11 ? `55${agencyPhone}` : agencyPhone;
    const requesterName = profile.fullName || profile.username || "responsável pela conta";
    const requesterLogin = profile.username ? `@${profile.username}` : "usuário da empresa";
    const message = `Olá, ${agencyName}! Sou ${requesterName}, responsável pela empresa ${store.name} (${requesterLogin}). Gostaria de solicitar a liberação do WhatsApp Business Oficial no sistema para organizar conversas, contatos, templates e campanhas. Poderia me passar as condições do upgrade?`;
    const upgradeUrl = whatsappPhone ? `https://wa.me/${whatsappPhone}?text=${encodeURIComponent(message)}` : "";

    root.innerHTML = `<section class="wa-upgrade-shell" aria-labelledby="wa-upgrade-title">
      <div class="wa-upgrade-orb is-green" aria-hidden="true"></div><div class="wa-upgrade-orb is-blue" aria-hidden="true"></div>
      <article class="wa-upgrade-hero">
        <span class="wa-upgrade-icon"><i class="fa-brands fa-whatsapp" aria-hidden="true"></i><b><i class="fa-solid fa-sparkles" aria-hidden="true"></i></b></span>
        <p class="eyebrow">Recurso premium</p>
        <h2 id="wa-upgrade-title">Toda a comunicação oficial da sua empresa em um só lugar.</h2>
        <p>Conecte a API Oficial do WhatsApp para organizar conversas, contatos, templates e campanhas com histórico protegido e operação profissional.</p>
        <div class="wa-upgrade-actions">
          ${upgradeUrl ? `<a class="wa-upgrade-button is-primary" href="${escapeHtml(upgradeUrl)}" target="_blank" rel="noopener noreferrer"><i class="fa-brands fa-whatsapp" aria-hidden="true"></i>Solicitar upgrade</a>` : `<span class="wa-upgrade-button is-disabled"><i class="fa-solid fa-circle-exclamation" aria-hidden="true"></i>Contato da agência indisponível</span>`}
          <button class="wa-upgrade-button is-secondary" type="button" data-wa-action="open-leads"><i class="fa-solid fa-arrow-left" aria-hidden="true"></i>Voltar para Leads</button>
        </div>
        <small>Peça a liberação para <strong>${escapeHtml(agencyName)}</strong>. O módulo permanece protegido até a agência ativar uma licença para ${escapeHtml(store.name)}.</small>
      </article>
      <div class="wa-upgrade-features" aria-label="Benefícios do WhatsApp Business Oficial">
        <article><i class="fa-solid fa-comments" aria-hidden="true"></i><div><strong>Conversas organizadas</strong><span>Centralize mensagens, mídias, status e histórico por contato.</span></div></article>
        <article><i class="fa-solid fa-address-book" aria-hidden="true"></i><div><strong>Contatos completos</strong><span>Etiquetas, observações e consentimentos dentro da empresa certa.</span></div></article>
        <article><i class="fa-solid fa-paper-plane" aria-hidden="true"></i><div><strong>Campanhas oficiais</strong><span>Use templates aprovados e acompanhe entregas, leituras e falhas.</span></div></article>
        <article><i class="fa-solid fa-shield-halved" aria-hidden="true"></i><div><strong>Operação rastreável</strong><span>Webhooks, logs e filas preparados para crescer com segurança.</span></div></article>
      </div>
    </section>`;
  }

  function storeSelectorMarkup() {
    const stores = scopedStores();
    if (bridge.profile.role === "store") return `<span class="wa-store-fixed"><i class="fa-solid fa-store"></i>${escapeHtml(stores[0]?.name || bridge.profile.storeName || "Empresa")}</span>`;
    return `<label class="wa-store-selector"><span>Empresa</span><select data-wa-store><option value=""${selectedStoreId ? "" : " selected"}>${stores.length ? "Selecione um cliente" : "Nenhum cliente liberado"}</option>${stores.map((store) => `<option value="${escapeHtml(store.id)}"${store.id === selectedStoreId ? " selected" : ""}>${escapeHtml(store.name)}</option>`).join("")}</select></label>`;
  }

  function connectionSelectorMarkup() {
    if (!data.connections.length) return `<span class="wa-store-fixed wa-number-fixed"><i class="fa-brands fa-whatsapp"></i>Sem número</span>`;
    if (data.connections.length === 1) {
      const connection = data.connections[0];
      return `<span class="wa-store-fixed wa-number-fixed" title="${escapeHtml(connection.name || connection.connection_name || "Conexão WhatsApp")}"><i class="fa-brands fa-whatsapp"></i>${escapeHtml(formatPhone(connection.display_phone_number || connection.phone_number))}</span>`;
    }
    return `<label class="wa-store-selector wa-number-selector"><span>Número</span><select data-wa-connection>${data.connections.map((connection) => `<option value="${escapeHtml(connection.id)}"${connection.id === selectedConnectionId ? " selected" : ""}>${escapeHtml(connection.name || connection.connection_name || formatPhone(connection.display_phone_number || connection.phone_number))}</option>`).join("")}</select></label>`;
  }

  function navigationMarkup() {
    const status = connectionStatus();
    return `<aside class="wa-navigation" aria-label="Navegação do WhatsApp"><nav>${SECTIONS.map(([key, icon, label]) => `<button class="wa-nav-button${activeSection === key ? " is-active" : ""}" type="button" data-wa-section="${key}"><i class="fa-solid ${icon}"></i><span>${label}</span>${navCounter(key)}</button>`).join("")}</nav><div class="wa-nav-connection"><span class="wa-status-dot is-${status.key}"></span><div><strong>${escapeHtml(currentConnection()?.name || currentConnection()?.connection_name || "Sem conexão")}</strong><small>${status.label}</small></div><button type="button" data-wa-section="settings" aria-label="Abrir configurações"><i class="fa-solid fa-gear"></i></button></div></aside>`;
  }

  function navCounter(section) {
    const counters = {
      conversations: data.counts.unread_conversations ?? data.conversations.reduce((sum, item) => sum + Number(item.unread_count || 0), 0),
      contacts: data.counts.active_contacts ?? data.contacts.length,
      campaigns: data.counts.running_campaigns ?? data.campaigns.filter((item) => ["scheduled", "running", "paused"].includes(item.status)).length,
      templates: data.counts.approved_templates ?? data.templates.filter((item) => item.status === "approved").length,
      webhooks: data.webhooks.filter((item) => ["pending", "failed"].includes(item.status)).length,
      logs: data.logs.filter((item) => ["error", "critical"].includes(item.level)).length,
    };
    const value = counters[section] || 0;
    return value ? `<b>${value > 999 ? "999+" : value}</b>` : "";
  }

  function installNoticeMarkup() {
    return `<div class="wa-install-notice" role="status"><i class="fa-solid fa-shield-halved"></i><div><strong>Backend do WhatsApp aguardando instalação</strong><span>A interface está pronta. Execute <code>whatsapp_module.sql</code> e publique as Edge Functions para conectar a API Oficial.</span></div><button class="wa-button is-secondary" type="button" data-wa-section="settings">Abrir configuração</button></div>`;
  }

  function sectionMarkup() {
    if (!selectedStoreId) {
      const hasLicensedStores = scopedStores().length > 0;
      return emptyState(
        hasLicensedStores ? "Selecione uma empresa" : "Nenhum cliente com WhatsApp liberado",
        hasLicensedStores
          ? "Escolha a empresa que terá a conexão oficial do WhatsApp."
          : "Ative uma licença WhatsApp em Editar acesso. Se a cota estiver cheia, desative outro cliente ou solicite ampliação ao administrador.",
        hasLicensedStores ? "fa-store" : "fa-lock",
      );
    }
    if (activeSection === "contacts") return contactsMarkup();
    if (activeSection === "campaigns") return campaignsMarkup();
    if (activeSection === "templates") return templatesMarkup();
    if (activeSection === "settings") return settingsMarkup();
    if (activeSection === "webhooks") return webhooksMarkup();
    if (activeSection === "logs") return logsMarkup();
    return conversationsMarkup();
  }

  function emptyState(title, subtitle, icon = "fa-comments") {
    return `<div class="wa-empty"><i class="fa-solid ${icon}"></i><strong>${escapeHtml(title)}</strong><span>${escapeHtml(subtitle)}</span></div>`;
  }

  function loadMoreMarkup(section, label = "Carregar mais") {
    const page = pagination[section];
    if (!page?.hasMore) return "";
    return `<div class="wa-load-more"><button class="wa-button is-secondary" type="button" data-wa-action="load-more" data-section="${escapeHtml(section)}"><i class="fa-solid fa-chevron-down"></i>${escapeHtml(label)}</button><span>${formatNumber(data[section]?.length || 0)} de ${formatNumber(page.total)} carregados</span></div>`;
  }

  function statusBadge(status, label = "") {
    const normalized = styleToken(status);
    const labels = { sent: "Enviado", delivered: "Entregue", read: "Lido", played: "Reproduzido", failed: "Falha", pending: "Pendente", queued: "Na fila", processing: "Processando", running: "Em andamento", paused: "Pausado", cancelled: "Cancelado", canceled: "Cancelado", completed: "Concluído", approved: "Aprovado", rejected: "Rejeitado", connected: "Conectado", processed: "Processado", received: "Recebido", ignored: "Ignorado", warning: "Atenção", error: "Erro", info: "Informação", success: "Sucesso" };
    return `<span class="wa-status-badge is-${normalized}">${escapeHtml(label || labels[normalized] || status || "Pendente")}</span>`;
  }

  function conversationsMarkup() {
    const rows = filteredConversations();
    const selected = rows.find((item) => item.id === selectedConversationId)
      || data.conversations.find((item) => item.id === selectedConversationId)
      || rows[0]
      || null;
    if (selected && selected.id !== selectedConversationId) selectedConversationId = selected.id;
    const unread = data.conversations.reduce((sum, item) => sum + Number(item.unread_count || 0), 0);
    const total = pagination.conversations.total || data.conversations.length;
    return `<section class="wa-section wa-conversations-section">
      <div class="wa-section-heading"><div><p class="eyebrow">Atendimento</p><h3>Conversas</h3><span>${formatNumber(total)} conversas · ${formatNumber(unread)} mensagens não lidas</span></div><div class="wa-heading-actions">${canSend() ? '<button class="wa-button is-secondary" type="button" data-wa-action="new-conversation"><i class="fa-solid fa-plus"></i>Nova conversa</button>' : ""}</div></div>
      <div class="wa-conversation-workspace">
        <aside class="wa-inbox">
          <div class="wa-inbox-tools"><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-search="conversations" value="${escapeHtml(searches.conversations)}" placeholder="Nome, número ou mensagem" /></label><select data-wa-filter="conversations" aria-label="Filtrar conversas"><option value="all"${filters.conversations === "all" ? " selected" : ""}>Todas</option><option value="unread"${filters.conversations === "unread" ? " selected" : ""}>Não lidas</option><option value="favorites"${filters.conversations === "favorites" ? " selected" : ""}>Favoritas</option><option value="open"${filters.conversations === "open" ? " selected" : ""}>Em atendimento</option><option value="closed"${filters.conversations === "closed" ? " selected" : ""}>Encerradas</option></select></div>
          <div class="wa-conversation-list">${rows.length ? rows.map(conversationRowMarkup).join("") : emptyState("Nenhuma conversa encontrada", "Ajuste os filtros ou inicie uma nova conversa.", "fa-message")}${loadMoreMarkup("conversations", "Mais conversas")}</div>
        </aside>
        ${chatMarkup(selected)}
      </div>
    </section>`;
  }

  function filteredConversations() {
    const search = normalize(searches.conversations);
    return data.conversations.filter((item) => {
      if (filters.conversations === "unread" && !Number(item.unread_count || 0)) return false;
      if (filters.conversations === "favorites" && !(item.is_favorite || item.favorite)) return false;
      if (filters.conversations === "open" && !["open", "pending"].includes(item.status)) return false;
      if (filters.conversations === "closed" && !isConversationClosed(item)) return false;
      if (!search) return true;
      return [item.contact_name, item.name, item.phone, item.phone_e164, item.wa_id, item.last_message_preview, item.last_message].some((value) => normalize(value).includes(search));
    }).sort((a, b) => new Date(b.last_message_at || b.updated_at || 0) - new Date(a.last_message_at || a.updated_at || 0));
  }

  function conversationRowMarkup(item) {
    const name = item.contact_name || item.name || item.profile_name || formatPhone(item.phone || item.phone_e164 || item.wa_id);
    const preview = item.last_message_preview || item.last_message || "Conversa iniciada";
    const avatar = safeMediaUrl(item.avatar_url || item.profile_picture_url);
    return `<button class="wa-conversation-row${item.id === selectedConversationId ? " is-active" : ""}" type="button" data-wa-conversation="${escapeHtml(item.id)}"><span class="wa-contact-avatar${avatar ? " has-image" : ""}">${avatar ? `<img src="${escapeHtml(avatar)}" alt="" />` : escapeHtml(initials(name))}</span><span class="wa-conversation-copy"><span><strong>${escapeHtml(name)}</strong><time>${escapeHtml(formatTime(item.last_message_at || item.updated_at))}</time></span><small>${escapeHtml(preview)}</small><em>${(item.labels || item.tags || []).slice(0, 2).map((label) => `<i>${escapeHtml(typeof label === "string" ? label : label.name)}</i>`).join("")}</em></span>${Number(item.unread_count || 0) ? `<b class="wa-unread-count">${item.unread_count}</b>` : ""}${item.is_favorite || item.favorite ? `<i class="fa-solid fa-star wa-favorite"></i>` : ""}</button>`;
  }

  function chatMarkup(conversation) {
    if (!conversation) return `<article class="wa-chat is-empty">${emptyState("Selecione uma conversa", "O histórico completo aparecerá aqui.", "fa-comments")}</article>`;
    const name = conversation.contact_name || conversation.name || conversation.profile_name || formatPhone(conversation.phone || conversation.phone_e164 || conversation.wa_id);
    const phone = formatPhone(conversation.phone || conversation.phone_e164 || conversation.wa_id);
    const avatar = safeMediaUrl(conversation.avatar_url || conversation.profile_picture_url);
    const windowExpires = conversation.service_window_expires_at || conversation.customer_service_window_expires_at;
    const windowOpen = Boolean(windowExpires && new Date(windowExpires) > new Date());
    const sendAllowed = canSend();
    return `<article class="wa-chat">
      <header class="wa-chat-header"><div class="wa-chat-person"><span class="wa-contact-avatar${avatar ? " has-image" : ""}">${avatar ? `<img src="${escapeHtml(avatar)}" alt="" />` : escapeHtml(initials(name))}</span><div><strong>${escapeHtml(name)}</strong><span>${escapeHtml(phone)} · ${escapeHtml(isConversationClosed(conversation) ? "Conversa encerrada" : "Em atendimento")}</span></div></div><div class="wa-chat-actions">${sendAllowed ? `<button class="wa-icon-button${conversation.is_favorite ? " is-favorite" : ""}" type="button" data-wa-action="toggle-favorite" aria-label="Favoritar"><i class="fa-${conversation.is_favorite ? "solid" : "regular"} fa-star"></i></button><button class="wa-icon-button" type="button" data-wa-action="edit-current-contact" aria-label="Editar contato"><i class="fa-solid fa-user-pen"></i></button><button class="wa-icon-button" type="button" data-wa-action="toggle-conversation-status" aria-label="${isConversationClosed(conversation) ? "Reabrir" : "Encerrar"} conversa"><i class="fa-solid ${isConversationClosed(conversation) ? "fa-lock-open" : "fa-check"}"></i></button>` : ""}</div></header>
      <div class="wa-service-window is-${windowOpen ? "open" : "closed"}"><i class="fa-solid ${windowOpen ? "fa-clock" : "fa-shield-halved"}"></i><span>${windowOpen ? `Janela de atendimento aberta${windowExpires ? ` até ${formatDateTime(windowExpires)}` : ""}.` : "Fora da janela de 24 horas: utilize um template aprovado."}</span></div>
      <div class="wa-message-list" data-wa-message-list>${messagesHasMore ? '<div class="wa-load-more is-messages"><button class="wa-button is-secondary" type="button" data-wa-action="load-more-messages"><i class="fa-solid fa-clock-rotate-left"></i>Mensagens anteriores</button></div>' : ""}${messages.length ? messages.map(messageMarkup).join("") : emptyState("Histórico ainda não carregado", "Selecione a conversa ou atualize para buscar as mensagens.", "fa-comment-dots")}</div>
      <form id="waComposerForm" class="wa-composer" data-conversation-id="${escapeHtml(conversation.id)}">
        <div class="wa-composer-tools"><button class="wa-icon-button" type="button" data-wa-action="toggle-emoji" aria-label="Emoji"${windowOpen && sendAllowed ? "" : " disabled"}><i class="fa-regular fa-face-smile"></i></button><button class="wa-icon-button" type="button" data-wa-action="pick-attachment" data-accept="image/*,video/*,audio/*,.pdf,.doc,.docx,.xls,.xlsx" aria-label="Anexar arquivo"${windowOpen && sendAllowed ? "" : " disabled"}><i class="fa-solid fa-paperclip"></i></button><button class="wa-icon-button" type="button" data-wa-action="open-template-picker" aria-label="Enviar template"${sendAllowed ? "" : " disabled"}><i class="fa-solid fa-layer-group"></i></button><input type="file" data-wa-attachment hidden /></div>
        ${emojiOpen ? `<div class="wa-emoji-picker">${EMOJIS.map((emoji) => `<button type="button" data-wa-emoji="${emoji}">${emoji}</button>`).join("")}</div>` : ""}
        <textarea name="message" rows="1" maxlength="4096" placeholder="${!sendAllowed ? "Sem permissão para enviar" : windowOpen ? "Digite uma mensagem" : "Escolha um template aprovado"}"${windowOpen && sendAllowed ? "" : " disabled"}></textarea>
        <button class="wa-send-button" type="submit"${windowOpen && sendAllowed ? "" : " disabled"} aria-label="Enviar mensagem"><i class="fa-solid fa-paper-plane"></i></button>
      </form>
    </article>`;
  }

  function messageMarkup(item) {
    const outgoing = item.direction === "outbound" || item.from_me === true;
    const type = item.message_type || item.type || "text";
    const text = item.text_body || item.body || item.text || mediaLabel(type);
    const attachment = Array.isArray(item.attachments) ? item.attachments[0] : null;
    return `<article class="wa-message is-${outgoing ? "outgoing" : "incoming"}${item.status === "failed" ? " is-failed" : ""}"><div>${item.media_url || item.attachment_url || attachment ? mediaPreviewMarkup({ ...item, ...(attachment || {}) }, type) : ""}<p>${escapeHtml(text)}</p>${item.caption ? `<small>${escapeHtml(item.caption)}</small>` : ""}<footer><time>${escapeHtml(formatTime(item.sent_at || item.received_at || item.created_at))}</time>${outgoing ? messageStatusIcon(item.status) : ""}</footer></div></article>`;
  }

  function mediaPreviewMarkup(item, type) {
    const attachmentId = String(item.id || item.attachment_id || "");
    const url = safeMediaUrl(item.media_url || item.attachment_url || item.storage_url || item.download_url || mediaObjectUrls.get(attachmentId));
    if (!url) return `<button class="wa-file-attachment" type="button" data-wa-action="open-media" data-id="${escapeHtml(attachmentId)}"><i class="fa-solid fa-file-shield"></i><span>${escapeHtml(item.original_filename || item.file_name || "Carregar mídia protegida")}</span></button>`;
    if (type === "image") return `<a href="${escapeHtml(url)}" target="_blank" rel="noopener"><img src="${escapeHtml(url)}" alt="Imagem enviada" loading="lazy" /></a>`;
    if (type === "audio") return `<audio controls preload="none" src="${escapeHtml(url)}"></audio>`;
    if (type === "video") return `<video controls preload="metadata" src="${escapeHtml(url)}"></video>`;
    return `<a class="wa-file-attachment" href="${escapeHtml(url)}" target="_blank" rel="noopener"><i class="fa-solid fa-file-arrow-down"></i><span>${escapeHtml(item.file_name || "Abrir documento")}</span></a>`;
  }

  function messageStatusIcon(status) {
    const icons = { sent: "fa-check", delivered: "fa-check-double", read: "fa-check-double", played: "fa-circle-play", failed: "fa-circle-exclamation", pending: "fa-clock", queued: "fa-clock" };
    const token = styleToken(status);
    return `<i class="fa-solid ${icons[token] || "fa-clock"} wa-message-status is-${token}" title="${escapeHtml(status || "Pendente")}"></i>`;
  }

  function mediaLabel(type) {
    return { image: "Imagem", audio: "Áudio", video: "Vídeo", document: "Documento", sticker: "Figurinha", template: "Template enviado" }[type] || "Mensagem";
  }

  function initials(value) {
    return String(value || "WA").split(/\s+/).filter(Boolean).slice(0, 2).map((item) => item[0]).join("").toUpperCase();
  }

  function formatPhone(value) {
    const digits = onlyDigits(value);
    if (digits.length === 13 && digits.startsWith("55")) return `+55 (${digits.slice(2, 4)}) ${digits.slice(4, 9)}-${digits.slice(9)}`;
    if (digits.length === 11) return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7)}`;
    return value || "Número não informado";
  }

  function contactsMarkup() {
    const contacts = filteredContacts();
    const tags = [...new Set([
      ...data.tags.map((tag) => tag.name),
      ...data.contacts.flatMap((item) => (item.labels || item.tags || []).map((tag) => typeof tag === "string" ? tag : tag.name)),
    ].filter(Boolean))].sort((a, b) => a.localeCompare(b, "pt-BR"));
    const loadedOptedIn = data.contacts.filter(hasMarketingConsent).length;
    const total = data.counts.active_contacts ?? pagination.contacts.total ?? data.contacts.length;
    const optedIn = data.counts.marketing_opt_in_contacts ?? loadedOptedIn;
    return `<section class="wa-section">
      <div class="wa-section-heading"><div><p class="eyebrow">Base de relacionamento</p><h3>Contatos</h3><span>${formatNumber(total)} contatos · ${formatNumber(optedIn)} autorizados para campanhas</span></div><div class="wa-heading-actions">${canSend() ? '<button class="wa-button is-secondary" type="button" data-wa-action="import-contacts"><i class="fa-solid fa-file-import"></i>Importar lista</button><button class="wa-button is-primary" type="button" data-wa-action="new-contact"><i class="fa-solid fa-user-plus"></i>Novo contato</button><input type="file" data-wa-contact-import accept=".csv,text/csv" hidden />' : ""}</div></div>
      <div class="wa-toolbar"><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-search="contacts" value="${escapeHtml(searches.contacts)}" placeholder="Buscar nome, número, e-mail ou etiqueta" /></label><label class="wa-filter-control"><span>Etiqueta</span><select data-wa-filter="contactTag"><option value="all">Todas</option>${tags.map((tag) => `<option value="${escapeHtml(tag)}"${filters.contactTag === tag ? " selected" : ""}>${escapeHtml(tag)}</option>`).join("")}</select></label></div>
      <div class="wa-table-wrap"><table class="wa-table"><thead><tr><th>Contato</th><th>Etiquetas</th><th>Consentimento</th><th>Última interação</th><th class="is-actions">Ações</th></tr></thead><tbody>${contacts.map(contactRowMarkup).join("")}</tbody></table>${contacts.length ? "" : emptyState("Nenhum contato encontrado", "Ajuste a busca ou cadastre um novo contato.", "fa-address-book")}${loadMoreMarkup("contacts", "Mais contatos")}</div>
    </section>`;
  }

  function filteredContacts() {
    const search = normalize(searches.contacts);
    return data.contacts.filter((item) => {
      const labels = (item.labels || item.tags || []).map((tag) => typeof tag === "string" ? tag : tag.name);
      if (filters.contactTag !== "all" && !labels.includes(filters.contactTag)) return false;
      if (!search) return true;
      return [item.name, item.profile_name, item.phone, item.phone_e164, item.wa_id, item.email, item.notes, ...labels].some((value) => normalize(value).includes(search));
    }).sort((a, b) => String(a.name || a.profile_name || a.phone_e164 || a.phone).localeCompare(String(b.name || b.profile_name || b.phone_e164 || b.phone), "pt-BR"));
  }

  function contactRowMarkup(item) {
    const name = item.name || item.profile_name || formatPhone(item.phone || item.phone_e164 || item.wa_id);
    const labels = item.labels || item.tags || [];
    const optedIn = hasMarketingConsent(item);
    const actions = canSend() ? `<button class="wa-icon-button" type="button" data-wa-action="start-contact-conversation" data-id="${escapeHtml(item.id)}" title="Conversar"><i class="fa-brands fa-whatsapp"></i></button><button class="wa-icon-button" type="button" data-wa-action="edit-contact" data-id="${escapeHtml(item.id)}" title="Editar"><i class="fa-solid fa-pen"></i></button><button class="wa-icon-button is-danger" type="button" data-wa-action="delete-contact" data-id="${escapeHtml(item.id)}" title="Excluir"><i class="fa-solid fa-trash"></i></button>` : '<small>Somente leitura</small>';
    return `<tr><td data-label="Contato"><div class="wa-person-cell"><span class="wa-contact-avatar">${escapeHtml(initials(name))}</span><span><strong>${escapeHtml(name)}</strong><small>${escapeHtml(formatPhone(item.phone || item.phone_e164 || item.wa_id))}${item.email ? ` · ${escapeHtml(item.email)}` : ""}</small></span></div></td><td data-label="Etiquetas"><div class="wa-chip-list">${labels.length ? labels.map((label) => `<span>${escapeHtml(typeof label === "string" ? label : label.name)}</span>`).join("") : "<small>Sem etiquetas</small>"}</div></td><td data-label="Consentimento">${statusBadge(optedIn ? "success" : "warning", optedIn ? "Opt-in registrado" : "Sem opt-in")}</td><td data-label="Última interação"><span>${escapeHtml(formatDateTime(item.last_interaction_at || item.last_message_at || item.updated_at))}</span></td><td data-label="Ações" class="is-actions"><div class="wa-row-actions">${actions}</div></td></tr>`;
  }

  function campaignsMarkup() {
    const campaigns = filteredCampaigns();
    const totals = data.campaigns.reduce((sum, item) => ({ sent: sum.sent + Number(item.sent_count || item.sent || 0), delivered: sum.delivered + Number(item.delivered_count || item.delivered || 0), read: sum.read + Number(item.read_count || item.read || 0), failed: sum.failed + Number(item.failed_count || item.failed || 0) }), { sent: 0, delivered: 0, read: 0, failed: 0 });
    return `<section class="wa-section">
      <div class="wa-section-heading"><div><p class="eyebrow">Campanhas oficiais</p><h3>Disparos</h3><span>Envios exclusivamente com templates aprovados e contatos autorizados</span></div><div class="wa-heading-actions">${canManageCampaigns() ? '<button class="wa-button is-secondary" type="button" data-wa-action="import-contacts"><i class="fa-solid fa-file-import"></i>Importar lista</button><input type="file" accept=".csv,text/csv" data-wa-contact-import hidden /><button class="wa-button is-primary" type="button" data-wa-action="new-campaign"><i class="fa-solid fa-plus"></i>Nova campanha</button>' : ""}</div></div>
      <div class="wa-banner is-info"><i class="fa-solid fa-shield-heart"></i><div><strong>Proteção de qualidade e consentimento</strong><span>Somente contatos com opt-in entram na fila. O envio respeita velocidade, janela programada e regras da API Oficial.</span></div></div>
      <div class="wa-metrics">${metricCard("Enviadas", totals.sent, "fa-paper-plane", "blue")}${metricCard("Entregues", totals.delivered, "fa-circle-check", "green")}${metricCard("Lidas", totals.read, "fa-eye", "purple")}${metricCard("Falhas", totals.failed, "fa-triangle-exclamation", "red")}</div>
      <div class="wa-toolbar"><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-search="campaigns" value="${escapeHtml(searches.campaigns)}" placeholder="Buscar campanha ou template" /></label><label class="wa-filter-control"><span>Status</span><select data-wa-filter="campaignStatus"><option value="all">Todos</option>${["draft", "scheduled", "running", "paused", "completed", "cancelled", "failed"].map((status) => `<option value="${status}"${filters.campaignStatus === status ? " selected" : ""}>${campaignStatusLabel(status)}</option>`).join("")}</select></label></div>
      <div class="wa-campaign-list">${campaigns.length ? campaigns.map(campaignCardMarkup).join("") : emptyState("Nenhuma campanha encontrada", "Crie uma campanha segura com um template aprovado.", "fa-paper-plane")}${loadMoreMarkup("campaigns", "Mais campanhas")}</div>
    </section>`;
  }

  function metricCard(label, value, icon, tone) {
    return `<article class="wa-metric-card is-${tone}"><span><i class="fa-solid ${icon}"></i></span><div><strong>${formatNumber(value)}</strong><small>${escapeHtml(label)}</small></div></article>`;
  }

  function filteredCampaigns() {
    const search = normalize(searches.campaigns);
    return data.campaigns.filter((item) => {
      if (filters.campaignStatus !== "all" && item.status !== filters.campaignStatus) return false;
      if (!search) return true;
      return [item.name, item.template_name, item.template?.name].some((value) => normalize(value).includes(search));
    }).sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
  }

  function campaignStatusLabel(status) {
    return { draft: "Rascunho", scheduled: "Programada", running: "Em andamento", paused: "Pausada", completed: "Concluída", cancelled: "Cancelada", canceled: "Cancelada", failed: "Com falha" }[status] || status;
  }

  function campaignCardMarkup(item) {
    const total = Number(item.total_recipients || item.recipient_count || 0);
    const sent = Number(item.sent_count || item.sent || 0);
    const delivered = Number(item.delivered_count || item.delivered || 0);
    const read = Number(item.read_count || item.read || 0);
    const failed = Number(item.failed_count || item.failed || 0);
    const pending = Math.max(0, Number(item.pending_count ?? total - sent - failed));
    const progress = total ? Math.min(100, Math.round(((sent + failed) / total) * 100)) : 0;
    const permitted = canManageCampaigns();
    const actions = !permitted ? "" : item.status === "running" ? `<button data-wa-action="campaign-pause" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-pause"></i>Pausar</button>` : item.status === "paused" ? `<button data-wa-action="campaign-resume" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-play"></i>Retomar</button>` : ["scheduled", "draft"].includes(item.status) ? `<button data-wa-action="campaign-start" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-play"></i>Iniciar${item.status === "scheduled" ? " agora" : ""}</button>` : "";
    const cancel = permitted && ["draft", "scheduled", "running", "paused", "failed"].includes(item.status) ? `<button class="is-danger" data-wa-action="campaign-cancel" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-ban"></i>Cancelar</button>` : "";
    const perMinute = Number(item.messages_per_second) > 0 ? Number(item.messages_per_second) * 60 : Number(item.rate_per_minute || item.send_rate || 30);
    return `<article class="wa-campaign-card"><header><div><span class="wa-campaign-icon"><i class="fa-solid fa-bullhorn"></i></span><span><strong>${escapeHtml(item.name || "Campanha sem nome")}</strong><small>Template: ${escapeHtml(item.template_name || item.template?.name || "—")} · ${formatNumber(total)} contatos</small></span></div>${statusBadge(item.status, campaignStatusLabel(item.status))}</header><div class="wa-progress"><span style="width:${progress}%"></span></div><div class="wa-stat-grid"><span><strong>${formatNumber(sent)}</strong><small>Enviadas</small></span><span><strong>${formatNumber(delivered)}</strong><small>Entregues</small></span><span><strong>${formatNumber(read)}</strong><small>Lidas</small></span><span><strong>${formatNumber(failed)}</strong><small>Falhas</small></span><span><strong>${formatNumber(pending)}</strong><small>Pendentes</small></span></div><footer><div><span><i class="fa-regular fa-calendar"></i>${escapeHtml(item.scheduled_at ? formatDateTime(item.scheduled_at) : item.started_at ? `Iniciada ${formatDateTime(item.started_at)}` : "Sem agendamento")}</span><span><i class="fa-solid fa-gauge-high"></i>${formatNumber(perMinute)}/min</span></div><div class="wa-row-actions">${actions}${cancel}<button data-wa-action="campaign-report" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-chart-column"></i>Relatório</button></div></footer></article>`;
  }

  function templatesMarkup() {
    const templates = filteredTemplates();
    const approved = data.templates.filter((item) => normalize(item.status) === "approved").length;
    return `<section class="wa-section">
      <div class="wa-section-heading"><div><p class="eyebrow">Conteúdo aprovado</p><h3>Templates</h3><span>${formatNumber(approved)} aprovados de ${formatNumber(data.templates.length)} sincronizados com a Meta</span></div><div class="wa-heading-actions">${canConfigure() ? '<button class="wa-button is-secondary" type="button" data-wa-action="sync-templates"><i class="fa-solid fa-arrows-rotate"></i>Sincronizar</button><button class="wa-button is-primary" type="button" data-wa-action="new-template"><i class="fa-solid fa-plus"></i>Novo template</button>' : ""}</div></div>
      <div class="wa-toolbar"><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-search="templates" value="${escapeHtml(searches.templates)}" placeholder="Buscar nome, categoria ou idioma" /></label><label class="wa-filter-control"><span>Status</span><select data-wa-filter="templateStatus"><option value="all">Todos</option>${["approved", "pending", "rejected", "paused", "disabled"].map((status) => `<option value="${status}"${filters.templateStatus === status ? " selected" : ""}>${templateStatusLabel(status)}</option>`).join("")}</select></label></div>
      <div class="wa-template-list">${templates.length ? templates.map(templateCardMarkup).join("") : emptyState("Nenhum template sincronizado", "Sincronize a conta ou envie o primeiro modelo para análise.", "fa-layer-group")}</div>
    </section>`;
  }

  function filteredTemplates() {
    const search = normalize(searches.templates);
    return data.templates.filter((item) => {
      const status = normalize(item.status);
      if (filters.templateStatus !== "all" && status !== filters.templateStatus) return false;
      if (!search) return true;
      return [item.name, item.category, item.language, item.language_code, item.body_text, item.body].some((value) => normalize(value).includes(search));
    }).sort((a, b) => String(a.name).localeCompare(String(b.name), "pt-BR"));
  }

  function templateStatusLabel(status) {
    return { approved: "Aprovado", pending: "Em análise", rejected: "Rejeitado", paused: "Pausado", disabled: "Desativado" }[normalize(status)] || status;
  }

  function templateCardMarkup(item) {
    const components = Array.isArray(item.components) ? item.components : [];
    const body = item.body_text || item.body || components.find((component) => component.type === "BODY")?.text || "Sem prévia de conteúdo.";
    const status = normalize(item.status);
    const configureActions = canConfigure() ? `<button type="button" data-wa-action="edit-template" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-pen"></i>Editar</button><button type="button" data-wa-action="duplicate-template" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-copy"></i>Duplicar</button>` : "";
    const testAction = status === "approved" && canSend() ? `<button type="button" data-wa-action="send-template-test" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-paper-plane"></i>Testar</button>` : "";
    return `<article class="wa-template-card"><header><span class="wa-template-icon"><i class="fa-solid fa-layer-group"></i></span><div><strong>${escapeHtml(item.name || "Template")}</strong><span>${escapeHtml(item.language || item.language_code || "pt_BR")} · ${escapeHtml(item.category || "Utilidade")}</span></div>${statusBadge(status, templateStatusLabel(status))}</header><div class="wa-template-preview"><i class="fa-brands fa-whatsapp"></i><p>${escapeHtml(body)}</p></div>${item.rejection_reason ? `<div class="wa-banner is-error"><i class="fa-solid fa-circle-exclamation"></i><span>${escapeHtml(item.rejection_reason)}</span></div>` : ""}<footer><span>Atualizado ${escapeHtml(formatDateTime(item.synced_at || item.last_synced_at || item.updated_at))}</span><div class="wa-row-actions"><button type="button" data-wa-action="view-template" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-eye"></i>Detalhes</button>${configureActions}${testAction}</div></footer></article>`;
  }

  function settingsMarkup() {
    const connection = currentConnection();
    const status = connectionStatus(connection);
    const webhookUrl = connection?.webhook_url || `${String(bridge?.supabaseUrl || "").replace(/\/$/, "")}/functions/v1/whatsapp-webhook`;
    const canEdit = canConfigure();
    return `<section class="wa-section">
      <div class="wa-section-heading"><div><p class="eyebrow">API Oficial</p><h3>Configurações</h3><span>Credenciais protegidas, validação guiada e diagnóstico completo da conexão</span></div><div class="wa-heading-actions">${canEdit ? '<button class="wa-button is-secondary" type="button" data-wa-action="new-connection"><i class="fa-solid fa-plus"></i>Nova conexão</button><button class="wa-button is-primary" type="button" data-wa-action="start-wizard"><i class="fa-solid fa-wand-magic-sparkles"></i>Assistente de configuração</button>' : ""}</div></div>
      <div class="wa-settings-grid">
        <article class="wa-settings-card is-status"><div class="wa-connection-hero"><span class="wa-connection-orb is-${status.key}"><i class="fa-brands fa-whatsapp"></i></span><div><small>Status da conexão</small><h4>${escapeHtml(connection?.name || connection?.connection_name || "WhatsApp principal")}</h4><span class="wa-connection-status is-${status.key}"><i class="fa-solid ${status.icon}"></i>${status.label}</span></div></div><div class="wa-detail-list"><span><small>Número</small><strong>${escapeHtml(formatPhone(connection?.phone_number || connection?.display_phone_number))}</strong></span><span><small>Última validação</small><strong>${escapeHtml(formatDateTime(connection?.last_validated_at))}</strong></span><span><small>Token</small><strong>${connection?.has_access_token || connection?.token_configured ? "Protegido e configurado" : "Não configurado"}</strong></span><span><small>Versão</small><strong>${escapeHtml(connection?.api_version || connection?.graph_api_version || "Definida na conexão")}</strong></span></div></article>
        <article class="wa-settings-card"><header><div><h4>Conexão ativa</h4><span>As credenciais secretas nunca são devolvidas ao navegador.</span></div>${data.connections.length > 1 ? `<select data-wa-connection>${data.connections.map((item) => `<option value="${escapeHtml(item.id)}"${item.id === selectedConnectionId ? " selected" : ""}>${escapeHtml(item.name || item.connection_name)}</option>`).join("")}</select>` : ""}</header>${connectionFormMarkup(connection, webhookUrl, canEdit)}</article>
      </div>${connectionDiagnosticsMarkup(connection)}
      <article class="wa-settings-card wa-security-card"><span><i class="fa-solid fa-lock"></i></span><div><h4>Segurança por arquitetura</h4><p>Access Token, App Secret e Verify Token ficam cifrados no backend e são usados somente pelas Edge Functions. Logs ocultam credenciais e cada consulta é isolada pela empresa autenticada.</p></div><ul><li><i class="fa-solid fa-check"></i>Assinatura SHA-256 dos webhooks</li><li><i class="fa-solid fa-check"></i>Idempotência e tentativas controladas</li><li><i class="fa-solid fa-check"></i>Fila com limites por conexão</li></ul></article>
    </section>`;
  }

  function connectionDiagnosticsMarkup(connection) {
    if (!connection) return "";
    const errorMessage = connection.last_error_message || connection.error_message;
    const errorCode = connection.last_error_code || connection.error_code;
    const expiresAt = connection.token_expires_at || connection.tokenExpiresAt;
    const rows = [];
    if (expiresAt) rows.push(`<span><strong>Validade do token:</strong> ${escapeHtml(formatDateTime(expiresAt))}</span>`);
    if (errorMessage || errorCode) rows.push(`<span><strong>Diagnóstico${errorCode ? ` ${escapeHtml(errorCode)}` : ""}:</strong> ${escapeHtml(errorMessage || "Consulte os logs técnicos.")}</span>`);
    return rows.length ? `<div class="wa-banner ${errorMessage || errorCode ? "is-error" : "is-info"}"><i class="fa-solid ${errorMessage || errorCode ? "fa-triangle-exclamation" : "fa-clock"}"></i><div>${rows.join("")}</div></div>` : "";
  }

  function connectionFormMarkup(connection, webhookUrl, canEdit = true) {
    const disabled = canEdit ? "" : " disabled";
    return `<form id="waConnectionForm" class="wa-form" autocomplete="off"><input type="hidden" name="connection_id" value="${escapeHtml(connection?.id || "")}" /><div class="wa-form-grid">
      ${fieldMarkup("Nome da conexão", "name", connection?.name || connection?.connection_name, "WhatsApp principal", "text", true, disabled)}
      ${fieldMarkup("Número do WhatsApp", "phone_number", connection?.phone_number || connection?.display_phone_number, "+55 (00) 00000-0000", "tel", true, disabled)}
      ${fieldMarkup("Phone Number ID", "phone_number_id", connection?.phone_number_id, "ID fornecido pela Meta", "text", true, disabled)}
      ${fieldMarkup("Business Account ID", "business_account_id", connection?.business_account_id || connection?.waba_id, "WhatsApp Business Account ID", "text", true, disabled)}
      ${fieldMarkup("Access Token", "access_token", "", connection?.has_access_token || connection?.token_configured ? "Token já protegido · informe apenas para substituir" : "Token permanente ou de sistema", "password", !connection, disabled, "off")}
      ${fieldMarkup("App ID", "app_id", connection?.app_id, "ID do aplicativo Meta", "text", !connection, disabled)}
      ${fieldMarkup("App Secret", "app_secret", "", connection?.has_app_secret || connection?.app_secret_configured ? "Secret já protegido · informe apenas para substituir" : "Segredo do aplicativo", "password", !connection, disabled, "new-password")}
      ${fieldMarkup("Verify Token", "verify_token", "", connection?.has_verify_token || connection?.verify_token_configured ? "Token já protegido · informe apenas para substituir" : "Crie um token forte para o webhook", "password", !connection, disabled, "new-password")}
      ${fieldMarkup("Webhook URL", "webhook_url", webhookUrl, "URL gerada automaticamente", "url", false, " readonly")}
      <label class="wa-field"><span>Versão da API <b>*</b></span>${apiVersionSelect("api_version", connection?.api_version || connection?.graph_api_version || "v26.0").replace("<select", `<select${disabled}`)}</label>
    </div><div class="wa-form-actions"><button class="wa-button is-primary" type="submit"${disabled}><i class="fa-solid fa-floppy-disk"></i>Salvar</button><button class="wa-button is-secondary" type="button" data-wa-action="validate-connection"${disabled}><i class="fa-solid fa-shield-check"></i>Validar credenciais</button><button class="wa-button is-secondary" type="button" data-wa-action="test-connection"${disabled}><i class="fa-solid fa-plug-circle-check"></i>Testar conexão</button><button class="wa-button is-secondary" type="button" data-wa-action="update-token"${disabled}><i class="fa-solid fa-key"></i>Atualizar token</button><button class="wa-button is-secondary" type="button" data-wa-action="reconnect"${disabled}><i class="fa-solid fa-rotate"></i>Reconectar</button><button class="wa-button is-danger" type="button" data-wa-action="disconnect"${disabled}><i class="fa-solid fa-link-slash"></i>Desconectar</button></div></form>`;
  }

  function fieldMarkup(label, name, value, placeholder, type = "text", required = false, attributes = "", autocomplete = "") {
    return `<label class="wa-field"><span>${escapeHtml(label)}${required ? " <b>*</b>" : ""}</span><input type="${type}" name="${name}" value="${escapeHtml(value || "")}" placeholder="${escapeHtml(placeholder || "")}"${required ? " required" : ""}${autocomplete ? ` autocomplete="${escapeHtml(autocomplete)}"` : ""}${attributes} /></label>`;
  }

  function webhooksMarkup() {
    const events = filteredWebhooks();
    const failed = data.webhooks.filter((item) => ["failed", "error"].includes(normalize(item.status || item.processing_status))).length;
    return `<section class="wa-section">
      <div class="wa-section-heading"><div><p class="eyebrow">Eventos da Meta</p><h3>Webhooks</h3><span>Histórico imutável, deduplicado e pronto para reprocessamento seguro</span></div><div class="wa-heading-actions"><span class="wa-summary-pill${failed ? " is-danger" : ""}"><i class="fa-solid ${failed ? "fa-triangle-exclamation" : "fa-circle-check"}"></i>${failed ? `${failed} com falha` : "Processamento saudável"}</span></div></div>
      <div class="wa-toolbar"><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-search="webhooks" value="${escapeHtml(searches.webhooks)}" placeholder="Buscar evento, objeto ou ID da Meta" /></label><label class="wa-filter-control"><span>Status</span><select data-wa-filter="webhookStatus"><option value="all">Todos</option>${["received", "processed", "pending", "failed", "ignored"].map((status) => `<option value="${status}"${filters.webhookStatus === status ? " selected" : ""}>${webhookStatusLabel(status)}</option>`).join("")}</select></label></div>
      <div class="wa-webhook-list">${events.length ? events.map(webhookRowMarkup).join("") : emptyState("Nenhum evento encontrado", "Os eventos recebidos da Meta aparecerão aqui.", "fa-code-branch")}${loadMoreMarkup("webhooks", "Mais eventos")}</div>
    </section>`;
  }

  function filteredWebhooks() {
    const search = normalize(searches.webhooks);
    return data.webhooks.filter((item) => {
      const status = normalize(item.status || item.processing_status || "received");
      if (filters.webhookStatus !== "all" && status !== filters.webhookStatus) return false;
      if (!search) return true;
      return [item.event_type, item.object_type, item.provider_object, item.meta_event_id, item.external_id, item.event_key, item.error_message, item.last_error].some((value) => normalize(value).includes(search));
    }).sort((a, b) => new Date(b.received_at || b.first_received_at || b.created_at || 0) - new Date(a.received_at || a.first_received_at || a.created_at || 0));
  }

  function webhookStatusLabel(status) {
    return { received: "Recebido", processed: "Processado", pending: "Pendente", failed: "Falhou", ignored: "Ignorado" }[status] || status;
  }

  function webhookRowMarkup(item) {
    const status = styleToken(item.status || item.processing_status || "received", "received");
    const attempts = Number(item.processing_attempts || item.attempts || 0);
    const lastError = item.error_message || item.last_error;
    return `<article class="wa-webhook-row"><span class="wa-event-icon is-${status}"><i class="fa-solid ${status === "failed" ? "fa-triangle-exclamation" : status === "processed" ? "fa-check" : "fa-code"}"></i></span><div class="wa-event-main"><header><strong>${escapeHtml(item.event_type || item.field || "Evento WhatsApp")}</strong>${statusBadge(status, webhookStatusLabel(status))}</header><span>${escapeHtml(item.object_type || item.provider_object || "whatsapp_business_account")} · ID ${escapeHtml(item.meta_event_id || item.external_id || item.event_key || item.id)}</span>${lastError ? `<small class="is-error">${escapeHtml(lastError)}</small>` : ""}</div><div class="wa-event-meta"><span>${escapeHtml(formatDateTime(item.received_at || item.first_received_at || item.created_at))}</span><small>${attempts} tentativa${attempts === 1 ? "" : "s"}</small></div><div class="wa-row-actions"><button type="button" data-wa-action="view-webhook" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-code"></i>Ver JSON</button>${canConfigure() && (status === "failed" || status === "pending") ? `<button type="button" data-wa-action="reprocess-webhook" data-id="${escapeHtml(item.id)}"><i class="fa-solid fa-rotate"></i>Reprocessar</button>` : ""}</div></article>`;
  }

  function logsMarkup() {
    const logs = filteredLogs();
    return `<section class="wa-section">
      <div class="wa-section-heading"><div><p class="eyebrow">Observabilidade</p><h3>Logs</h3><span>Conexões, chamadas, mensagens, filas e falhas com dados sensíveis ocultos</span></div><div class="wa-heading-actions"><button class="wa-button is-secondary" type="button" data-wa-action="export-logs"><i class="fa-solid fa-download"></i>Exportar</button></div></div>
      <div class="wa-toolbar"><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-search="logs" value="${escapeHtml(searches.logs)}" placeholder="Buscar ação, erro, endpoint ou ID" /></label><div class="wa-filter-group"><label class="wa-filter-control"><span>Nível</span><select data-wa-filter="logLevel"><option value="all">Todos</option>${["debug", "info", "warning", "error", "critical"].map((level) => `<option value="${level}"${filters.logLevel === level ? " selected" : ""}>${logLevelLabel(level)}</option>`).join("")}</select></label><label class="wa-filter-control"><span>Origem</span><select data-wa-filter="logType"><option value="all">Todas</option>${logTypes().map((type) => `<option value="${escapeHtml(type)}"${filters.logType === type ? " selected" : ""}>${escapeHtml(type)}</option>`).join("")}</select></label></div></div>
      <div class="wa-log-list">${logs.length ? logs.map(logRowMarkup).join("") : emptyState("Nenhum log encontrado", "Ajuste os filtros para consultar o histórico técnico.", "fa-list-check")}${loadMoreMarkup("logs", "Mais registros")}</div>
    </section>`;
  }

  function logTypes() {
    return [...new Set(data.logs.map((item) => item.category || item.event_type || item.source).filter(Boolean))].sort((a, b) => String(a).localeCompare(String(b), "pt-BR"));
  }

  function logLevelLabel(level) {
    return { debug: "Depuração", info: "Informação", warning: "Atenção", error: "Erro", critical: "Crítico" }[level] || level;
  }

  function filteredLogs() {
    const search = normalize(searches.logs);
    return data.logs.filter((item) => {
      const level = normalize(item.level || "info");
      const type = item.category || item.event_type || item.source || "Sistema";
      if (filters.logLevel !== "all" && level !== filters.logLevel) return false;
      if (filters.logType !== "all" && type !== filters.logType) return false;
      if (!search) return true;
      return [item.action, item.message, item.endpoint, item.request_id, item.meta_message_id, item.error_code, type].some((value) => normalize(value).includes(search));
    }).sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
  }

  function logRowMarkup(item) {
    const level = styleToken(item.level || "info", "info");
    const duration = item.latency_ms ?? item.duration_ms ?? item.response_time_ms;
    return `<button class="wa-log-row" type="button" data-wa-action="view-log" data-id="${escapeHtml(item.id)}"><span class="wa-log-level is-${level}"><i class="fa-solid ${level === "error" || level === "critical" ? "fa-circle-exclamation" : level === "warning" ? "fa-triangle-exclamation" : "fa-circle-info"}"></i></span><span class="wa-log-main"><strong>${escapeHtml(item.action || item.message || "Evento do sistema")}</strong><small>${escapeHtml(item.category || item.event_type || item.source || "WhatsApp")} ${item.endpoint ? `· ${escapeHtml(item.endpoint)}` : ""}</small></span><span class="wa-log-result">${statusBadge(level, logLevelLabel(level))}${duration != null ? `<small>${formatNumber(duration)} ms</small>` : ""}</span><time>${escapeHtml(formatDateTime(item.created_at))}</time><i class="fa-solid fa-chevron-right"></i></button>`;
  }

  function baseContactFormMarkup(contact = null) {
    const labels = (contact?.labels || contact?.tags || []).map((item) => typeof item === "string" ? item : item.name).join(", ");
    const customFields = contact?.custom_fields && Object.keys(contact.custom_fields).length ? JSON.stringify(contact.custom_fields, null, 2) : "";
    return `<form id="waContactForm" class="wa-form"><input type="hidden" name="contact_id" value="${escapeHtml(contact?.id || "")}" /><div class="wa-form-grid">${fieldMarkup("Nome", "name", contact?.name || contact?.profile_name, "Nome do contato", "text", true)}${fieldMarkup("Telefone", "phone", contact?.phone || contact?.phone_e164 || contact?.wa_id, "+55 (00) 00000-0000", "tel", true)}${fieldMarkup("E-mail", "email", contact?.email, "contato@empresa.com", "email")}${fieldMarkup("Etiquetas", "labels", labels, "Cliente, VIP, Orçamento", "text")}</div><label class="wa-field is-full"><span>Observações</span><textarea name="notes" rows="3" placeholder="Informações relevantes sobre o contato">${escapeHtml(contact?.notes || "")}</textarea></label><label class="wa-field is-full"><span>Notas internas</span><textarea name="internal_notes" rows="3" placeholder="Visível apenas para sua equipe">${escapeHtml(contact?.internal_notes || "")}</textarea></label><label class="wa-field is-full"><span>Campos personalizados em JSON <small>(opcional)</small></span><textarea name="custom_fields" rows="4" class="is-code" placeholder='{"cidade":"Campinas","origem":"Instagram"}'>${escapeHtml(customFields)}</textarea></label><label class="wa-checkbox"><input type="checkbox" name="opt_in"${contact?.opt_in || contact?.marketing_opt_in ? " checked" : ""} /><span><strong>Consentimento para comunicações registrado</strong><small>Confirme somente quando houver autorização válida do contato.</small></span></label><div class="wa-form-grid is-optin">${fieldMarkup("Origem do consentimento", "opt_in_source", contact?.opt_in_source, "Formulário, atendimento, loja...")}${fieldMarkup("Data do consentimento", "opt_in_at", toDateTimeLocal(contact?.opt_in_at), "", "datetime-local")}${fieldMarkup("Finalidade", "opt_in_purpose", contact?.opt_in_purpose || "Comunicações comerciais via WhatsApp", "Finalidade informada ao contato")}${fieldMarkup("Categorias autorizadas", "opt_in_categories", Array.isArray(contact?.opt_in_categories) ? contact.opt_in_categories.join(", ") : "Atendimento, campanhas", "Atendimento, campanhas")}${fieldMarkup("Versão do texto", "opt_in_text_version", contact?.opt_in_text_version || "consentimento-whatsapp-v1", "Identificador da versão")}</div></form>`;
  }

  function contactFormMarkup(contact = null) {
    const evidence = contact?.opt_in_evidence && typeof contact.opt_in_evidence === "object"
      ? contact.opt_in_evidence.note || contact.opt_in_evidence.reference || ""
      : "";
    return baseContactFormMarkup(contact).replace(
      "</form>",
      `${fieldMarkup("Evidência ou referência do consentimento", "opt_in_evidence_note", evidence, "Ex.: formulário #123, gravação, atendimento presencial")}</form>`,
    );
  }

  function campaignFormMarkup() {
    const approved = data.templates.filter((item) => normalize(item.status) === "approved");
    const optedContacts = data.contacts.filter(hasMarketingConsent);
    const authorizedTotal = data.counts.marketing_opt_in_contacts ?? optedContacts.length;
    return `<form id="waCampaignForm" class="wa-form"><div class="wa-form-grid">${fieldMarkup("Nome da campanha", "name", "", "Ex.: Retorno de clientes - agosto", "text", true)}<label class="wa-field"><span>Template aprovado <b>*</b></span><select name="template_id" required><option value="">Selecione</option>${approved.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.name)} · ${escapeHtml(item.language || item.language_code || "pt_BR")}</option>`).join("")}</select></label>${fieldMarkup("Programar envio", "scheduled_at", "", "", "datetime-local")}${fieldMarkup("Velocidade por minuto", "rate_per_minute", "30", "30", "number", true, " min=\"1\" max=\"4800\"")}<label class="wa-field"><span>Depois de criar</span><select name="launch_mode"><option value="draft">Salvar para revisar</option><option value="schedule">Programar na data informada</option><option value="start">Iniciar agora</option></select></label></div><label class="wa-field is-full"><span>Variáveis do template <small>(uma por linha, aplicadas a todos)</small></span><textarea name="template_values" rows="3" placeholder="João\n10/08 às 14h"></textarea></label><fieldset class="wa-audience-picker"><legend>Público autorizado</legend><div class="wa-audience-summary"><span><strong>${formatNumber(authorizedTotal)}</strong><small>contatos com opt-in disponíveis</small></span><label class="wa-checkbox is-compact"><input type="checkbox" name="all_opted_in" data-wa-select-all-contacts /><span>Usar todos os autorizados</span></label></div><label class="wa-search"><i class="fa-solid fa-magnifying-glass"></i><input type="search" data-wa-audience-search placeholder="Ou busque contatos específicos" /></label><div class="wa-contact-picker">${optedContacts.length ? optedContacts.map((item) => { const phone = item.phone || item.phone_e164 || item.wa_id; const tagText = (item.labels || item.tags || []).map((tag) => typeof tag === "string" ? tag : tag.name).join(" "); return `<label data-wa-contact-option data-search="${escapeHtml(normalize(`${item.name} ${phone} ${tagText}`))}"><input type="checkbox" name="contact_ids" value="${escapeHtml(item.id)}" /><span class="wa-contact-avatar">${escapeHtml(initials(item.name || phone))}</span><span><strong>${escapeHtml(item.name || formatPhone(phone))}</strong><small>${escapeHtml(formatPhone(phone))}</small></span></label>`; }).join("") : emptyState("Nenhum contato autorizado carregado", "Use todos os autorizados ou registre o opt-in antes de criar a campanha.", "fa-user-shield")}</div></fieldset><div class="wa-banner is-info"><i class="fa-solid fa-circle-info"></i><span>Ao escolher todos, a audiência é resolvida no servidor, inclusive para bases grandes. A fila revalidará consentimento, qualidade e limites antes de cada envio.</span></div></form>`;
  }

  function templateFormMarkup(source = null, mode = "create") {
    const components = Array.isArray(source?.components) ? source.components : [];
    const body = source?.body_text || source?.body || components.find((item) => item.type === "BODY")?.text || "";
    const footer = source?.footer_text || components.find((item) => item.type === "FOOTER")?.text || "";
    const header = components.find((item) => item.type === "HEADER");
    const buttons = components.find((item) => item.type === "BUTTONS")?.buttons || [];
    const bodyExamples = components.find((item) => item.type === "BODY")?.example?.body_text?.[0] || [];
    const language = source?.language || source?.language_code || "pt_BR";
    const category = String(source?.category || "UTILITY").toUpperCase();
    const technicalName = source ? mode === "duplicate" ? `${source.name}_copia` : source.name : "";
    const immutable = mode === "edit";
    const languageField = immutable
      ? `<input type="hidden" name="language" value="${escapeHtml(language)}" /><label class="wa-field"><span>Idioma</span><input value="${escapeHtml(language)}" readonly aria-readonly="true" /></label>`
      : `<label class="wa-field"><span>Idioma <b>*</b></span><select name="language" required><option value="pt_BR"${language === "pt_BR" ? " selected" : ""}>Português (Brasil)</option><option value="en_US"${language === "en_US" ? " selected" : ""}>English (US)</option><option value="es"${language === "es" ? " selected" : ""}>Español</option></select></label>`;
    return `<form id="waTemplateForm" class="wa-form"><input type="hidden" name="template_id" value="${mode === "edit" ? escapeHtml(source?.id || "") : ""}" /><input type="hidden" name="provider_template_id" value="${mode === "edit" ? escapeHtml(source?.provider_template_id || "") : ""}" /><div class="wa-form-grid">${fieldMarkup("Nome técnico", "name", technicalName, "retorno_cliente_agosto", "text", true, ` pattern="[a-z0-9_]+"${immutable ? " readonly aria-readonly=\"true\"" : ""}`)}<label class="wa-field"><span>Categoria <b>*</b></span><select name="category" required>${["UTILITY", "MARKETING", "AUTHENTICATION"].map((value) => `<option value="${value}"${category === value ? " selected" : ""}>${{ UTILITY: "Utilidade", MARKETING: "Marketing", AUTHENTICATION: "Autenticação" }[value]}</option>`).join("")}</select></label>${languageField}<label class="wa-field"><span>Cabeçalho</span><select name="header_type"><option value="NONE"${!header ? " selected" : ""}>Sem cabeçalho</option><option value="TEXT"${header?.format === "TEXT" ? " selected" : ""}>Texto</option></select></label>${fieldMarkup("Texto do cabeçalho", "header_text", header?.text, "Opcional · até 60 caracteres", "text", false, " maxlength=\"60\"")}</div><label class="wa-field is-full"><span>Texto da mensagem <b>*</b></span><textarea name="body_text" rows="6" required maxlength="1024" placeholder="Olá {{1}}, temos uma novidade para você.">${escapeHtml(body)}</textarea><small>Use variáveis sequenciais como {{1}}, {{2}}. A aprovação é realizada pela Meta.</small></label><label class="wa-field is-full"><span>Exemplos das variáveis <small>(uma linha para cada variável)</small></span><textarea name="body_examples" rows="3" placeholder="João\n10/08 às 14h">${escapeHtml(bodyExamples.join("\n"))}</textarea></label>${fieldMarkup("Rodapé", "footer_text", footer, "Responda SAIR para não receber mensagens", "text")}<label class="wa-field is-full"><span>Botões em JSON <small>(opcional)</small></span><textarea name="buttons_json" rows="4" class="is-code" placeholder='[{"type":"QUICK_REPLY","text":"Quero saber mais"}]'>${escapeHtml(buttons.length ? JSON.stringify(buttons, null, 2) : "")}</textarea></label></form>`;
  }

  function newConversationMarkup(contact = null) {
    const approved = data.templates.filter((item) => normalize(item.status) === "approved");
    const authorized = data.contacts.filter(hasMarketingConsent);
    const contactField = contact
      ? `<input type="hidden" name="contact_id" value="${escapeHtml(contact.id)}" /><div class="wa-selected-contact"><span class="wa-contact-avatar">${escapeHtml(initials(contact.name || contact.phone_e164))}</span><span><strong>${escapeHtml(contact.name || formatPhone(contact.phone_e164))}</strong><small>${escapeHtml(formatPhone(contact.phone || contact.phone_e164 || contact.wa_id))} · opt-in registrado</small></span></div>`
      : `<label class="wa-field"><span>Contato autorizado <b>*</b></span><select name="contact_id" required><option value="">Selecione um contato com opt-in</option>${authorized.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.name || formatPhone(item.phone_e164))} · ${escapeHtml(formatPhone(item.phone || item.phone_e164 || item.wa_id))}</option>`).join("")}</select></label>`;
    if (contactField) return `<form id="waNewConversationForm" class="wa-form"><div class="wa-banner is-info"><i class="fa-solid fa-clock"></i><span>Para iniciar uma nova conversa, selecione um contato autorizado e um template aprovado.</span></div>${contactField}<label class="wa-field"><span>Template <b>*</b></span><select name="template_id" required><option value="">Selecione um template aprovado</option>${approved.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.name)} · ${escapeHtml(item.language || item.language_code || "pt_BR")}</option>`).join("")}</select></label><label class="wa-field"><span>Variáveis <small>(uma por linha, na ordem)</small></span><textarea name="parameters" rows="4" placeholder="João\n10/08 às 14h"></textarea></label></form>`;
  }

  function templatePickerMarkup() {
    const approved = data.templates.filter((item) => normalize(item.status) === "approved");
    return `<form id="waTemplateSendForm" class="wa-form"><label class="wa-field"><span>Template aprovado <b>*</b></span><select name="template_id" required><option value="">Selecione</option>${approved.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.name)} · ${escapeHtml(item.language || item.language_code || "pt_BR")}</option>`).join("")}</select></label><label class="wa-field"><span>Variáveis <small>(uma por linha, na ordem)</small></span><textarea name="parameters" rows="4" placeholder="João\n10/08 às 14h"></textarea></label></form>`;
  }

  function toDateTimeLocal(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    const offset = date.getTimezoneOffset();
    return new Date(date.getTime() - offset * 60000).toISOString().slice(0, 16);
  }

  function openDialog({ title, subtitle = "", content = "", icon = "fa-circle-info", confirmLabel = "", confirmForm = "", confirmAction = "", danger = false, size = "medium" }) {
    const existing = root.querySelector(".wa-dialog");
    if (!existing) dialogReturnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (existing) {
      try { existing.close(); } catch (_) { /* dialog fallback */ }
      existing.remove();
    }
    root.insertAdjacentHTML("beforeend", `<dialog class="wa-dialog is-${escapeHtml(size)}"><div class="wa-dialog-panel"><header class="wa-dialog-header"><span><i class="fa-solid ${icon}"></i></span><div><h3>${escapeHtml(title)}</h3>${subtitle ? `<p>${escapeHtml(subtitle)}</p>` : ""}</div><button class="wa-icon-button" type="button" data-wa-action="close-dialog" aria-label="Fechar"><i class="fa-solid fa-xmark"></i></button></header><div class="wa-dialog-body">${content}</div><footer class="wa-dialog-footer"><button class="wa-button is-secondary" type="button" data-wa-action="close-dialog">Cancelar</button>${confirmLabel ? `<button class="wa-button ${danger ? "is-danger" : "is-primary"}" type="${confirmForm ? "submit" : "button"}"${confirmForm ? ` form="${escapeHtml(confirmForm)}"` : ""}${confirmAction ? ` data-wa-action="${escapeHtml(confirmAction)}"` : ""}>${escapeHtml(confirmLabel)}</button>` : ""}</footer></div></dialog>`);
    const dialog = root.querySelector(".wa-dialog");
    if (typeof dialog?.showModal === "function") dialog.showModal();
    else dialog?.setAttribute("open", "");
    dialog?.addEventListener("cancel", (event) => { event.preventDefault(); closeDialog(); });
    requestAnimationFrame(() => dialog?.querySelector("input:not([type='hidden']), select, textarea, button")?.focus());
  }

  function closeDialog() {
    const dialog = root.querySelector(".wa-dialog");
    if (!dialog) return;
    try { dialog.close(); } catch (_) { /* dialog fallback */ }
    dialog.remove();
    pendingConfirmation = null;
    wizard = null;
    const returnFocus = dialogReturnFocus;
    dialogReturnFocus = null;
    if (active && returnFocus?.isConnected) requestAnimationFrame(() => returnFocus.focus());
  }

  function confirmAction(title, message, callback, confirmLabel = "Confirmar") {
    openDialog({ title, subtitle: message, content: `<div class="wa-confirm-visual"><i class="fa-solid fa-triangle-exclamation"></i><p>${escapeHtml(message)}</p></div>`, icon: "fa-shield-halved", confirmLabel, confirmAction: "confirm-operation", danger: true, size: "small" });
    pendingConfirmation = callback;
  }

  function openDetails(title, record, subtitle = "Dados técnicos com segredos protegidos.") {
    detailRecord = redactSecrets(record);
    openDialog({ title, subtitle, content: `<pre class="wa-json-view">${escapeHtml(JSON.stringify(detailRecord, null, 2))}</pre>`, icon: "fa-code", size: "large" });
  }

  function redactSecrets(value) {
    if (Array.isArray(value)) return value.map(redactSecrets);
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(Object.entries(value).map(([key, item]) => {
      if (/(access.?token|app.?secret|verify.?token|authorization|signature|signed.?url)/i.test(key)) return [key, "[PROTEGIDO]"];
      return [key, redactSecrets(item)];
    }));
  }

  function wizardMarkup() {
    const step = wizard?.step || 1;
    const draft = wizard?.draft || {};
    const titles = ["Credenciais", "Validar", "Webhook", "Envio de teste", "Finalizar"];
    let content = "";
    if (step === 1) {
      content = `<form id="waWizardCredentials" class="wa-form"><div class="wa-form-grid">${fieldMarkup("Nome da conexão", "name", draft.name, "WhatsApp principal", "text", true)}${fieldMarkup("Número do WhatsApp", "phone_number", draft.phone_number, "+55 (00) 00000-0000", "tel", true)}${fieldMarkup("Phone Number ID", "phone_number_id", draft.phone_number_id, "ID do número", "text", true)}${fieldMarkup("Business Account ID", "business_account_id", draft.business_account_id, "ID da WABA", "text", true)}${fieldMarkup("Access Token", "access_token", draft.access_token, "Token de usuário de sistema", "password", true, " autocomplete=\"off\"")}${fieldMarkup("App ID", "app_id", draft.app_id, "ID do aplicativo", "text", true)}${fieldMarkup("App Secret", "app_secret", draft.app_secret, "Segredo do aplicativo", "password", true, " autocomplete=\"new-password\"")}${fieldMarkup("Verify Token", "verify_token", draft.verify_token, "Token forte criado por você", "password", true, " autocomplete=\"new-password\"")}<label class="wa-field"><span>Versão da API <b>*</b></span>${apiVersionSelect("api_version", draft.api_version || "v26.0")}</label></div></form>`;
    } else if (step === 2) {
      content = `<div class="wa-wizard-check"><span><i class="fa-solid ${wizard.validated ? "fa-circle-check" : "fa-shield-halved"}"></i></span><h4>${wizard.validated ? "Credenciais validadas" : "Vamos conferir a conexão"}</h4><p>${wizard.validated ? "Token, aplicativo, WABA e número pertencem ao mesmo ambiente e possuem os escopos necessários." : "Validaremos o token, os escopos, o vínculo do número e o status da conta sem expor nenhum segredo."}</p>${wizard.validationDetails ? `<pre class="wa-json-view">${escapeHtml(JSON.stringify(redactSecrets(wizard.validationDetails), null, 2))}</pre>` : ""}</div>`;
    } else if (step === 3) {
      const url = `${String(bridge?.supabaseUrl || "").replace(/\/$/, "")}/functions/v1/whatsapp-webhook`;
      content = `<div class="wa-wizard-check"><span><i class="fa-solid ${wizard.webhookRegistered ? "fa-circle-check" : "fa-code-branch"}"></i></span><h4>${wizard.webhookRegistered ? "Webhook registrado" : "Registrar eventos oficiais"}</h4><p>O assistente cadastrará a URL, assinará a WABA e validará o recebimento de mensagens e status.</p><label class="wa-copy-field"><input value="${escapeHtml(url)}" readonly /><button type="button" data-wa-action="copy-webhook"><i class="fa-solid fa-copy"></i>Copiar</button></label><ul class="wa-check-list"><li><i class="fa-solid fa-lock"></i>Verificação HMAC SHA-256</li><li><i class="fa-solid fa-clone"></i>Deduplicação automática</li><li><i class="fa-solid fa-bolt"></i>Resposta rápida e fila assíncrona</li></ul></div>`;
    } else if (step === 4) {
      const approved = data.templates.filter((item) => normalize(item.status) === "approved");
      const authorized = data.contacts.filter(hasMarketingConsent);
      content = `<form id="waWizardTest" class="wa-form"><div class="wa-wizard-check"><span><i class="fa-solid ${wizard.testSent ? "fa-circle-check" : "fa-paper-plane"}"></i></span><h4>${wizard.testSent ? "Teste persistido na fila" : "Realizar envio de teste"}</h4><p>${wizard.testSent ? "A mensagem foi registrada e será acompanhada pelos mesmos webhooks de status usados nas conversas." : "Escolha um contato com consentimento válido e um template aprovado. O teste será registrado antes do envio para permitir rastreamento de entrega, leitura ou falha."}</p></div><label class="wa-field"><span>Contato autorizado <b>*</b></span><select name="contact_id" required><option value="">Selecione um contato com consentimento</option>${authorized.map((item) => `<option value="${escapeHtml(item.id)}"${draft.test_contact_id === item.id ? " selected" : ""}>${escapeHtml(item.name || item.profile_name || formatPhone(item.phone_e164 || item.phone || item.wa_id))} · ${escapeHtml(formatPhone(item.phone_e164 || item.phone || item.wa_id))}</option>`).join("")}</select><small>${authorized.length ? "O consentimento será revalidado no servidor antes de entrar na fila." : "Nenhum contato autorizado foi encontrado. Cadastre o contato e a evidência do consentimento na área Contatos."}</small></label><label class="wa-field"><span>Template aprovado <b>*</b></span><select name="template_id" required><option value="">Selecione</option>${approved.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.name)}</option>`).join("")}</select></label><label class="wa-field"><span>Variáveis do template <small>(uma por linha)</small></span><textarea name="parameters" rows="3"></textarea></label></form>`;
    } else {
      content = `<div class="wa-wizard-finish"><span><i class="fa-brands fa-whatsapp"></i></span><p class="eyebrow">Configuração concluída</p><h4>Seu núcleo de comunicação está pronto</h4><p>Conexão validada, webhook registrado e teste persistido na fila. Conversas, status e campanhas usarão esta mesma estrutura segura e rastreável.</p><div class="wa-check-list"><span><i class="fa-solid fa-check"></i>Credenciais protegidas</span><span><i class="fa-solid fa-check"></i>Eventos monitorados</span><span><i class="fa-solid fa-check"></i>Fila pronta para escala</span></div></div>`;
    }
    return `<div class="wa-wizard"><ol class="wa-wizard-progress">${titles.map((title, index) => `<li class="${step === index + 1 ? "is-active" : step > index + 1 ? "is-complete" : ""}"><span>${step > index + 1 ? '<i class="fa-solid fa-check"></i>' : index + 1}</span><small>${title}</small></li>`).join("")}</ol><div class="wa-wizard-step">${content}</div><div class="wa-wizard-actions">${step > 1 && step < 5 ? `<button class="wa-button is-secondary" type="button" data-wa-action="wizard-back"><i class="fa-solid fa-arrow-left"></i>Voltar</button>` : "<span></span>"}${wizardPrimaryButton(step)}</div></div>`;
  }

  function wizardPrimaryButton(step) {
    if (step === 1) return `<button class="wa-button is-primary" type="submit" form="waWizardCredentials">Continuar<i class="fa-solid fa-arrow-right"></i></button>`;
    if (step === 2) return `<button class="wa-button is-primary" type="button" data-wa-action="wizard-validate">${wizard?.validated ? "Continuar" : "Validar credenciais"}<i class="fa-solid fa-arrow-right"></i></button>`;
    if (step === 3) return `<button class="wa-button is-primary" type="button" data-wa-action="wizard-register-webhook">${wizard?.webhookRegistered ? "Continuar" : "Registrar webhook"}<i class="fa-solid fa-arrow-right"></i></button>`;
    if (step === 4) return `<button class="wa-button is-primary" type="submit" form="waWizardTest">${wizard?.testSent ? "Continuar" : "Enviar teste"}<i class="fa-solid fa-arrow-right"></i></button>`;
    return `<button class="wa-button is-primary" type="button" data-wa-action="wizard-finish"><i class="fa-solid fa-check"></i>Abrir conversas</button>`;
  }

  function apiVersionSelect(name, selected = "v26.0") {
    return `<select name="${escapeHtml(name)}" required>${["v26.0", "v25.0", "v24.0", "v23.0"].map((version) => `<option value="${version}"${selected === version ? " selected" : ""}>${version}${version === "v26.0" ? " · atual" : ""}</option>`).join("")}</select>`;
  }

  function renderWizardDialog() {
    const dialog = root.querySelector(".wa-dialog");
    if (!dialog) {
      openDialog({ title: "Assistente de configuração", subtitle: "Conecte a API Oficial sem editar código.", content: wizardMarkup(), icon: "fa-wand-magic-sparkles", size: "large" });
      const footer = root.querySelector(".wa-dialog-footer");
      if (footer) footer.hidden = true;
      return;
    }
    const body = dialog.querySelector(".wa-dialog-body");
    if (body) body.innerHTML = wizardMarkup();
    dialog.querySelector(".wa-dialog-footer")?.setAttribute("hidden", "");
  }

  root.addEventListener("click", async (event) => {
    try {
    const sectionButton = event.target.closest("[data-wa-section]");
    if (sectionButton) {
      activeSection = sectionButton.dataset.waSection;
      await loadSectionData(activeSection);
      render();
      return;
    }

    const conversationButton = event.target.closest("[data-wa-conversation]");
    if (conversationButton) {
      releaseMediaObjectUrls();
      selectedConversationId = conversationButton.dataset.waConversation;
      const conversation = data.conversations.find((item) => item.id === selectedConversationId);
      if (conversation?.connection_id) selectedConnectionId = conversation.connection_id;
      messages = [];
      renderContent();
      await loadMessages(selectedConversationId);
      renderContent();
      return;
    }

    const button = event.target.closest("[data-wa-action]");
    if (!button || busy) return;
    const action = button.dataset.waAction;
    const id = button.dataset.id;

    if (CONFIG_MUTATIONS.has(action) && !canConfigure()) return permissionDenied("Somente o administrador ou a agência responsável pode alterar a integração oficial.");
    if ((action === "new-campaign" || action.startsWith("campaign-")) && action !== "campaign-report" && !canManageCampaigns()) return permissionDenied("Seu perfil não possui permissão para administrar disparos.");
    if (SEND_MUTATIONS.has(action) && !canSend()) return permissionDenied();

    if (action === "close-dialog") return closeDialog();
    if (action === "confirm-operation") {
      const callback = pendingConfirmation;
      if (callback) await callback();
      return;
    }
    if (action === "refresh") {
      await withButtonBusy(button, async () => { await loadBootstrap(); render(); bridge.notify("Dados do WhatsApp atualizados.", "success"); });
      return;
    }
    if (action === "load-more") {
      const section = button.dataset.section;
      if (!pagination[section]) return;
      await withButtonBusy(button, async () => {
        await loadSectionData(section, { append: true });
        renderContent();
      });
      return;
    }
    if (action === "load-more-messages") {
      await withButtonBusy(button, () => loadOlderMessages());
      return;
    }
    if (action === "open-leads") return await bridge.openLeadsForStore?.(selectedStoreId);
    if (action === "new-contact") return openDialog({ title: "Novo contato", subtitle: "Cadastre dados, etiquetas, notas e a prova de consentimento.", content: contactFormMarkup(), icon: "fa-user-plus", confirmLabel: "Salvar contato", confirmForm: "waContactForm", size: "large" });
    if (action === "edit-contact") return openContactDialog(data.contacts.find((item) => item.id === id));
    if (action === "edit-current-contact") {
      const conversation = data.conversations.find((item) => item.id === selectedConversationId);
      if (!data.contacts.length) await loadSectionData("contacts", { silent: true });
      const contact = data.contacts.find((item) => item.id === conversation?.contact_id) || data.contacts.find((item) => onlyDigits(item.phone || item.phone_e164 || item.wa_id) === onlyDigits(conversation?.phone || conversation?.phone_e164 || conversation?.wa_id));
      return contact ? openContactDialog(contact) : openDialog({ title: "Completar contato", subtitle: "Salve este número na base da empresa.", content: contactFormMarkup({ phone: conversation?.phone || conversation?.phone_e164 || conversation?.wa_id, name: conversation?.contact_name || conversation?.name }), icon: "fa-user-plus", confirmLabel: "Salvar contato", confirmForm: "waContactForm", size: "large" });
    }
    if (action === "delete-contact") {
      const contact = data.contacts.find((item) => item.id === id);
      return confirmAction("Excluir contato?", `O contato ${contact?.name || formatPhone(contact?.phone || contact?.phone_e164)} será removido da base. O histórico técnico de mensagens será preservado.`, async () => {
        await runRpc("wa_delete_contact", { p_contact_id: id }, "Contato excluído.");
        closeDialog();
        await loadSectionData("contacts");
        renderContent();
      }, "Excluir contato");
    }
    if (action === "start-contact-conversation") {
      const contact = data.contacts.find((item) => item.id === id);
      const existing = data.conversations.find((item) => onlyDigits(item.phone || item.phone_e164 || item.wa_id) === onlyDigits(contact?.phone || contact?.phone_e164 || contact?.wa_id));
      if (existing) {
        activeSection = "conversations";
        selectedConversationId = existing.id;
        if (existing.connection_id) selectedConnectionId = existing.connection_id;
        await loadMessages(existing.id);
        render();
      } else {
        if (!(contact?.opt_in === true || contact?.marketing_opt_in === true)) {
          bridge.notify("Registre a autorização deste contato antes de iniciar uma conversa pela empresa.", "warning");
          return openContactDialog(contact);
        }
        await ensureSectionData(["templates"]);
        openDialog({ title: "Iniciar conversa", subtitle: "Use um template aprovado para o primeiro contato.", content: newConversationMarkup(contact), icon: "fa-comment-medical", confirmLabel: "Enviar template", confirmForm: "waNewConversationForm", size: "medium" });
      }
      return;
    }
    if (action === "new-conversation") {
      await ensureSectionData(["contacts", "templates"]);
      return openDialog({ title: "Nova conversa", subtitle: "A primeira mensagem deve usar um template aprovado.", content: newConversationMarkup(), icon: "fa-comment-medical", confirmLabel: "Enviar template", confirmForm: "waNewConversationForm", size: "medium" });
    }
    if (action === "toggle-favorite") return await updateCurrentConversation({ is_favorite: !currentConversation()?.is_favorite });
    if (action === "toggle-conversation-status") return await updateCurrentConversation({ status: isConversationClosed(currentConversation()) ? "open" : "resolved" });
    if (action === "toggle-emoji") { emojiOpen = !emojiOpen; renderContent(); return; }
    if (action === "pick-attachment") {
      const input = root.querySelector("[data-wa-attachment]");
      if (input) { input.accept = button.dataset.accept || input.accept; input.click(); }
      return;
    }
    if (action === "open-media") {
      if (!id || !bridge?.download) return bridge.notify("O download seguro desta mídia não está disponível.", "error");
      await withButtonBusy(button, async () => {
        const downloaded = await bridge.download({ attachmentId: id });
        if (!(downloaded?.blob instanceof Blob)) throw new Error("A mídia recebida é inválida.");
        const objectUrl = URL.createObjectURL(downloaded.blob);
        rememberMediaObjectUrl(id, objectUrl);
        const attachment = messages.flatMap((message) => Array.isArray(message.attachments) ? message.attachments : []).find((item) => String(item.id) === id);
        const mediaType = String(attachment?.mime_type || downloaded.mimeType || "");
        if (!mediaType.startsWith("image/") && !mediaType.startsWith("audio/") && !mediaType.startsWith("video/")) {
          const link = document.createElement("a");
          link.href = objectUrl;
          link.download = downloaded.filename || attachment?.original_filename || "midia-whatsapp";
          link.click();
        }
        renderContent();
      });
      return;
    }
    if (action === "open-template-picker") {
      await ensureSectionData(["templates"]);
      return openDialog({ title: "Enviar template", subtitle: "Templates aprovados funcionam dentro e fora da janela de atendimento.", content: templatePickerMarkup(), icon: "fa-layer-group", confirmLabel: "Enviar", confirmForm: "waTemplateSendForm" });
    }
    if (action === "import-contacts") return root.querySelector("[data-wa-contact-import]")?.click();
    if (action === "new-campaign") {
      await ensureSectionData(["contacts", "templates"]);
      return openDialog({ title: "Nova campanha", subtitle: "Selecione somente contatos autorizados e um template aprovado.", content: campaignFormMarkup(), icon: "fa-bullhorn", confirmLabel: "Criar rascunho", confirmForm: "waCampaignForm", size: "large" });
    }
    if (action.startsWith("campaign-") && action !== "campaign-report") {
      const operation = action.replace("campaign-", "");
      const command = operation === "start" ? "start_now" : operation;
      const labels = { pause: "pausada", resume: "retomada", start_now: "iniciada", cancel: "cancelada" };
      const execute = async () => {
        await runEdge("action-campaign", { campaign_id: id, command }, `Campanha ${labels[command] || "atualizada"}.`);
        closeDialog();
        await loadSectionData("campaigns");
        renderContent();
      };
      if (operation === "cancel") return confirmAction("Cancelar campanha?", "Os itens que ainda não foram enviados serão cancelados. Mensagens já aceitas pela Meta não podem ser recolhidas.", execute, "Cancelar campanha");
      return await execute();
    }
    if (action === "campaign-report") return openCampaignReport(id);
    if (action === "download-campaign-report") {
      return await withButtonBusy(button, () => downloadFullCampaignReport(id || detailRecord?.campaign?.id));
    }
    if (action === "sync-templates") {
      await withButtonBusy(button, async () => { await runEdge("sync-templates", {}, "Templates sincronizados com a Meta."); await loadSectionData("templates"); renderContent(); });
      return;
    }
    if (action === "new-template") return openDialog({ title: "Novo template", subtitle: "O modelo será enviado à Meta para análise e aprovação.", content: templateFormMarkup(), icon: "fa-layer-group", confirmLabel: "Enviar para análise", confirmForm: "waTemplateForm", size: "large" });
    if (action === "edit-template") {
      const template = data.templates.find((item) => item.id === id);
      return openDialog({ title: "Editar template", subtitle: "Nome e idioma são imutáveis na Meta; alterações de conteúdo voltarão para análise.", content: templateFormMarkup(template, "edit"), icon: "fa-pen", confirmLabel: "Salvar na Meta", confirmForm: "waTemplateForm", size: "large" });
    }
    if (action === "duplicate-template") {
      const template = data.templates.find((item) => item.id === id);
      return openDialog({ title: "Duplicar template", subtitle: "Crie uma nova versão sem alterar o modelo já aprovado.", content: templateFormMarkup(template, "duplicate"), icon: "fa-copy", confirmLabel: "Enviar nova versão", confirmForm: "waTemplateForm", size: "large" });
    }
    if (action === "view-template") return openDetails("Detalhes do template", data.templates.find((item) => item.id === id));
    if (action === "send-template-test") {
      const template = data.templates.find((item) => item.id === id);
      return openDialog({ title: "Testar template", subtitle: `Envie ${template?.name || "este template"} para um número autorizado.`, content: `<form id="waTemplateTestForm" class="wa-form"><input type="hidden" name="template_id" value="${escapeHtml(id)}" />${fieldMarkup("Número para teste", "phone", "", "+55 (00) 00000-0000", "tel", true)}<label class="wa-field"><span>Variáveis <small>(uma por linha)</small></span><textarea name="parameters" rows="4"></textarea></label></form>`, icon: "fa-paper-plane", confirmLabel: "Enviar teste", confirmForm: "waTemplateTestForm" });
    }
    if (action === "new-connection" || action === "start-wizard") {
      wizard = { step: 1, draft: action === "new-connection" ? { connection_id: null, api_version: "v26.0" } : connectionDraftFromCurrentForm() };
      return renderWizardDialog();
    }
    if (action === "validate-connection" || action === "test-connection") {
      const payload = normalizeConnectionPayload(connectionDraftFromCurrentForm());
      await withButtonBusy(button, () => runEdge(action === "validate-connection" ? "validate" : "test", payload, action === "validate-connection" ? "Credenciais validadas com sucesso." : "Conexão testada com sucesso."));
      await loadBootstrap({ silent: true }); renderContent(); return;
    }
    if (action === "update-token") return openDialog({ title: "Atualizar Access Token", subtitle: "O token anterior será substituído somente após a nova credencial ser validada.", content: `<form id="waTokenForm" class="wa-form">${fieldMarkup("Novo Access Token", "access_token", "", "Cole o token de usuário de sistema", "password", true, " autocomplete=\"off\"")}</form>`, icon: "fa-key", confirmLabel: "Validar e atualizar", confirmForm: "waTokenForm" });
    if (action === "reconnect") { await withButtonBusy(button, () => runEdge("reconnect", {}, "Conexão reativada e validada.")); await loadBootstrap({ silent: true }); renderContent(); return; }
    if (action === "disconnect") return confirmAction("Desconectar o WhatsApp?", "Novos envios e a fila serão pausados localmente. O número não será removido da Meta e o histórico continuará preservado.", async () => { await runEdge("disconnect", {}, "Conexão desconectada."); closeDialog(); await loadBootstrap({ silent: true }); render(); }, "Desconectar");
    if (action === "view-webhook") {
      const eventDetails = await withButtonBusy(button, () => bridge.rpc("wa_get_webhook_event", { p_event_id: id }));
      return openDetails("JSON recebido", eventDetails, "Payload preservado para auditoria e reprocessamento.");
    }
    if (action === "reprocess-webhook") { await withButtonBusy(button, async () => { await runEdge("reprocess-webhook", { event_id: id }, "Evento colocado novamente na fila."); await loadSectionData("webhooks"); renderContent(); }); return; }
    if (action === "view-log") {
      const logDetails = await withButtonBusy(button, () => bridge.rpc("wa_get_log", { p_log_id: id }));
      return openDetails("Detalhes do log", logDetails);
    }
    if (action === "export-logs") return downloadCsv("whatsapp-logs.csv", data.logs.map((item) => ({ data: item.created_at, nivel: item.level, categoria: item.category || item.event_type, acao: item.action, mensagem: item.message, duracao_ms: item.latency_ms ?? item.duration_ms ?? item.response_time_ms, request_id: item.request_id })));
    if (action === "copy-webhook") {
      const input = button.closest(".wa-copy-field")?.querySelector("input");
      if (input) await navigator.clipboard.writeText(input.value);
      bridge.notify("URL do webhook copiada.", "success"); return;
    }
    if (action === "wizard-back") { wizard.step = Math.max(1, wizard.step - 1); renderWizardDialog(); return; }
    if (action === "wizard-validate") return await handleWizardValidation(button);
    if (action === "wizard-register-webhook") return await handleWizardWebhook(button);
    if (action === "wizard-finish") { closeDialog(); activeSection = "conversations"; await loadBootstrap(); render(); bridge.notify("WhatsApp configurado e pronto para uso.", "success"); return; }
    if (action === "wa-placeholder") bridge.notify("Este recurso será disponibilizado nesta conexão.", "info");
    } catch (error) {
      if (!error?.waHandled && !(await handleEntitlementLoss(error))) bridge?.notify?.(operationErrorMessage(error), "error");
    }
  });

  root.addEventListener("input", (event) => {
    const searchKey = event.target.dataset.waSearch;
    if (searchKey) {
      searches[searchKey] = event.target.value;
      clearTimeout(searchTimer);
      const position = event.target.selectionStart;
      searchTimer = setTimeout(async () => {
        if (["conversations", "contacts", "campaigns", "webhooks", "logs"].includes(searchKey)) await loadSectionData(searchKey, { silent: true });
        renderContent();
        const input = root.querySelector(`[data-wa-search="${searchKey}"]`);
        input?.focus();
        try { input?.setSelectionRange(position, position); } catch (_) { /* unsupported input type */ }
      }, 160);
      return;
    }
    if (event.target.matches("[data-wa-audience-search]")) {
      const query = normalize(event.target.value);
      root.querySelectorAll("[data-wa-contact-option]").forEach((option) => { option.hidden = query && !option.dataset.search.includes(query); });
    }
  });

  root.addEventListener("change", async (event) => {
    if (event.target.matches("[data-wa-store]")) {
      contextGeneration += 1;
      requestVersions = Object.create(null);
      selectedStoreId = event.target.value;
      selectedConnectionId = "";
      templatesConnectionId = "";
      selectedConversationId = "";
      messages = [];
      messagesHasMore = false;
      data = emptyData();
      pagination = emptyPagination();
      root.innerHTML = loadingMarkup();
      await loadBootstrap();
      render();
      return;
    }
    if (event.target.matches("[data-wa-connection]")) {
      selectedConnectionId = event.target.value;
      templatesConnectionId = "";
      data.templates = [];
      if (activeSection === "templates") await loadSectionData("templates", { silent: true });
      render();
      return;
    }
    const filter = event.target.dataset.waFilter;
    if (filter) {
      filters[filter] = event.target.value;
      const section = { conversations: "conversations", contactTag: "contacts", campaignStatus: "campaigns", webhookStatus: "webhooks", logLevel: "logs", logType: "logs" }[filter];
      if (section) await loadSectionData(section, { silent: true });
      renderContent();
      return;
    }
    if (event.target.matches("[data-wa-attachment]")) { const file = event.target.files?.[0]; if (file) await sendAttachment(file); event.target.value = ""; return; }
    if (event.target.matches("[data-wa-contact-import]")) { const file = event.target.files?.[0]; if (file) await importContacts(file); event.target.value = ""; return; }
    if (event.target.matches("[data-wa-select-all-contacts]")) {
      root.querySelectorAll('#waCampaignForm input[name="contact_ids"]').forEach((input) => {
        if (event.target.checked) input.checked = false;
        input.disabled = event.target.checked;
      });
      const search = root.querySelector("[data-wa-audience-search]");
      if (search) search.disabled = event.target.checked;
    }
    if (event.target.matches('#waCampaignForm select[name="launch_mode"]')) {
      const button = root.querySelector('.wa-dialog-footer button[form="waCampaignForm"]');
      if (button) button.textContent = { draft: "Criar rascunho", schedule: "Programar campanha", start: "Iniciar campanha" }[event.target.value] || "Criar campanha";
    }
  });

  root.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (busy) return;
    if (["waConnectionForm", "waTokenForm", "waTemplateForm", "waWizardCredentials", "waWizardTest"].includes(event.target.id) && !canConfigure()) return permissionDenied("Somente o administrador ou a agência responsável pode alterar a integração oficial.");
    if (event.target.id === "waCampaignForm" && !canManageCampaigns()) return permissionDenied("Seu perfil não possui permissão para administrar disparos.");
    if (["waComposerForm", "waContactForm", "waNewConversationForm", "waTemplateSendForm", "waTemplateTestForm"].includes(event.target.id) && !canSend()) return permissionDenied();
    try {
    if (event.target.id === "waComposerForm") return await sendComposer(event.target);
    if (event.target.id === "waContactForm") return await saveContact(event.target);
    if (event.target.id === "waCampaignForm") return await saveCampaign(event.target);
    if (event.target.id === "waTemplateForm") return await saveTemplate(event.target);
    if (event.target.id === "waConnectionForm") return await saveConnection(event.target);
    if (event.target.id === "waTokenForm") return await updateToken(event.target);
    if (event.target.id === "waNewConversationForm") return await sendNewConversation(event.target);
    if (["waTemplateSendForm", "waTemplateTestForm"].includes(event.target.id)) return await sendTemplate(event.target);
    if (event.target.id === "waWizardCredentials") return await saveWizardCredentials(event.target);
    if (event.target.id === "waWizardTest") return await sendWizardTest(event.target);
    } catch (error) {
      if (!error?.waHandled && !(await handleEntitlementLoss(error))) bridge?.notify?.(operationErrorMessage(error), "error");
    }
  });

  root.addEventListener("click", (event) => {
    const emoji = event.target.closest("[data-wa-emoji]");
    if (!emoji) return;
    const textarea = root.querySelector("#waComposerForm textarea[name='message']");
    if (!textarea) return;
    const start = textarea.selectionStart ?? textarea.value.length;
    textarea.value = `${textarea.value.slice(0, start)}${emoji.dataset.waEmoji}${textarea.value.slice(textarea.selectionEnd ?? start)}`;
    textarea.focus();
    textarea.setSelectionRange(start + emoji.dataset.waEmoji.length, start + emoji.dataset.waEmoji.length);
  });

  function renderContent() {
    if (!active) return;
    const content = root.querySelector("[data-wa-content]");
    if (content) content.innerHTML = sectionMarkup();
    else render();
  }

  function currentConversation() {
    return data.conversations.find((item) => item.id === selectedConversationId) || null;
  }

  function isConversationClosed(conversation) {
    return ["resolved", "archived", "closed"].includes(conversation?.status);
  }

  function openContactDialog(contact) {
    if (!contact) return bridge.notify("Contato não encontrado.", "error");
    openDialog({ title: "Editar contato", subtitle: "Atualize identificação, campos personalizados, notas e consentimento.", content: contactFormMarkup(contact), icon: "fa-user-pen", confirmLabel: "Salvar alterações", confirmForm: "waContactForm", size: "large" });
  }

  async function withButtonBusy(button, callback) {
    if (!button) return callback();
    const original = button.innerHTML;
    button.disabled = true;
    button.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin"></i><span>Processando</span>`;
    try { return await callback(); } finally { if (button.isConnected) { button.disabled = false; button.innerHTML = original; } }
  }

  function unwrapEdge(response) {
    if (response?.ok === false) {
      const detail = response.error || {};
      const error = new Error(detail.message || response.message || "A API do WhatsApp recusou a operação.");
      error.code = detail.code;
      error.details = detail.details;
      error.retryable = detail.retryable;
      error.correlationId = response.correlation_id;
      throw error;
    }
    return response?.data ?? response;
  }

  async function runEdge(action, payload = {}, successMessage = "") {
    if (!bridge?.edge) throw new Error("Serviço do WhatsApp indisponível.");
    busy = true;
    try {
      const response = await bridge.edge(action, {
        store_id: selectedStoreId,
        ...(selectedConnectionId ? { connection_id: selectedConnectionId } : {}),
        ...payload,
      });
      const result = unwrapEdge(response);
      if (successMessage) bridge.notify(successMessage, "success");
      return result;
    } catch (error) {
      if (await handleEntitlementLoss(error)) {
        if (error && typeof error === "object") error.waHandled = true;
        throw error;
      }
      const message = operationErrorMessage(error);
      bridge.notify(message, "error");
      if (error && typeof error === "object") error.waHandled = true;
      throw error;
    } finally {
      busy = false;
    }
  }

  async function runRpc(name, payload = {}, successMessage = "") {
    busy = true;
    try {
      const result = await bridge.rpc(name, payload);
      if (successMessage) bridge.notify(successMessage, "success");
      return result;
    } catch (error) {
      if (await handleEntitlementLoss(error)) {
        if (error && typeof error === "object") error.waHandled = true;
        throw error;
      }
      bridge.notify(operationErrorMessage(error), "error");
      if (error && typeof error === "object") error.waHandled = true;
      throw error;
    } finally {
      busy = false;
    }
  }

  function operationErrorMessage(error) {
    const base = readableError(error);
    const details = error?.details;
    const detailText = details && typeof details === "object"
      ? [details.message, details.field, details.hint, details.error_user_msg, details.error_subcode ? `subcódigo ${details.error_subcode}` : ""].filter(Boolean).join(" · ")
      : typeof details === "string" ? details : "";
    const correlation = error?.correlationId ? ` Código de diagnóstico: ${error.correlationId}.` : "";
    return `${base}${detailText ? ` ${detailText}` : ""}${correlation}`;
  }

  async function ensureSectionData(sections) {
    for (const section of sections) {
      if (section === "contacts" && data.contacts.length) continue;
      if (section === "templates" && data.templates.length && templatesConnectionId === selectedConnectionId) continue;
      await loadSectionData(section, { silent: true });
    }
  }

  async function loadMessages(conversationId, { silent = false } = {}) {
    if (!conversationId) { messages = []; messagesHasMore = false; return; }
    const request = beginRequest("messages");
    try {
      const response = await bridge.rpc("wa_get_messages", { p_conversation_id: conversationId, p_limit: 80 });
      if (!requestIsCurrent(request, selectedConversationId === conversationId)) return;
      messages = arrayFrom(response).sort((a, b) => new Date(a.created_at || a.sent_at || 0) - new Date(b.created_at || b.sent_at || 0));
      messagesHasMore = response?.has_more === true;
      const conversation = data.conversations.find((item) => item.id === conversationId);
      if (conversation) conversation.unread_count = 0;
      requestAnimationFrame(() => {
        const list = root.querySelector("[data-wa-message-list]");
        if (list) list.scrollTop = list.scrollHeight;
      });
    } catch (error) {
      if (!requestIsCurrent(request, selectedConversationId === conversationId)) return;
      if (await handleEntitlementLoss(error)) return;
      if (!silent) bridge.notify(operationErrorMessage(error), "error");
    }
  }

  async function loadOlderMessages() {
    if (!selectedConversationId || !messages.length) return;
    const conversationId = selectedConversationId;
    const request = beginRequest("messages");
    const list = root.querySelector("[data-wa-message-list]");
    const previousHeight = list?.scrollHeight || 0;
    const previousTop = list?.scrollTop || 0;
    try {
      const response = await bridge.rpc("wa_get_messages", {
        p_conversation_id: conversationId,
        p_before: messages[0]?.created_at || null,
        p_limit: 80,
      });
      if (!requestIsCurrent(request, selectedConversationId === conversationId)) return;
      const older = arrayFrom(response).sort((a, b) => new Date(a.created_at || a.sent_at || 0) - new Date(b.created_at || b.sent_at || 0));
      const known = new Set(messages.map((item) => String(item.id)));
      messages = [...older.filter((item) => !known.has(String(item.id))), ...messages];
      messagesHasMore = response?.has_more === true;
      renderContent();
      requestAnimationFrame(() => {
        const nextList = root.querySelector("[data-wa-message-list]");
        if (nextList) nextList.scrollTop = previousTop + Math.max(0, nextList.scrollHeight - previousHeight);
      });
    } catch (error) {
      if (!requestIsCurrent(request, selectedConversationId === conversationId)) return;
      if (await handleEntitlementLoss(error)) return;
      bridge.notify(operationErrorMessage(error), "error");
    }
  }

  async function updateCurrentConversation(payload) {
    const conversation = currentConversation();
    if (!conversation) return;
    await runRpc("wa_update_conversation", { p_conversation_id: conversation.id, p_payload: payload }, "Conversa atualizada.");
    Object.assign(conversation, payload);
    renderContent();
  }

  async function sendComposer(form) {
    const text = form.elements.message.value.trim();
    if (!text) return;
    const button = form.querySelector("button[type='submit']");
    await withButtonBusy(button, async () => {
      const result = await runEdge("send-message", { conversation_id: selectedConversationId, type: "text", text }, "Mensagem colocada na fila.");
      form.reset();
      emojiOpen = false;
      if (result?.message) messages.push(result.message);
      await loadMessages(selectedConversationId, { silent: true });
      renderContent();
    });
  }

  function formValues(form) {
    const values = {};
    new FormData(form).forEach((value, key) => {
      if (key in values) values[key] = Array.isArray(values[key]) ? [...values[key], value] : [values[key], value];
      else values[key] = value;
    });
    form.querySelectorAll('input[type="checkbox"][name]').forEach((input) => {
      if (!(input.name in values)) values[input.name] = false;
      else if (input.value === "on") values[input.name] = input.checked;
    });
    return values;
  }

  function connectionDraftFromCurrentForm() {
    const form = root.querySelector("#waConnectionForm");
    const connection = currentConnection() || {};
    const values = form ? formValues(form) : {};
    const draft = {
      connection_id: values.connection_id || connection.id || "",
      name: values.name || connection.name || connection.connection_name || "",
      phone_number: values.phone_number || connection.phone_number || connection.display_phone_number || "",
      phone_number_id: values.phone_number_id || connection.phone_number_id || "",
      business_account_id: values.business_account_id || connection.business_account_id || connection.waba_id || "",
      app_id: values.app_id || connection.app_id || "",
      webhook_url: values.webhook_url || connection.webhook_url || `${String(bridge?.supabaseUrl || "").replace(/\/$/, "")}/functions/v1/whatsapp-webhook`,
      api_version: values.api_version || connection.api_version || connection.graph_api_version || "v26.0",
    };
    ["access_token", "app_secret", "verify_token"].forEach((key) => { if (values[key]) draft[key] = values[key]; });
    return draft;
  }

  function normalizeConnectionPayload(draft = {}) {
    return {
      ...draft,
      display_phone_number: draft.display_phone_number || draft.phone_number || "",
      graph_api_version: draft.graph_api_version || draft.api_version || "v26.0",
    };
  }

  async function saveContact(form) {
    const values = formValues(form);
    let customFields = {};
    if (values.custom_fields?.trim()) {
      try { customFields = JSON.parse(values.custom_fields); } catch (_) { bridge.notify("Campos personalizados: informe um JSON válido.", "error"); form.elements.custom_fields.focus(); return; }
    }
    if (values.opt_in) {
      const requiredConsentFields = [
        ["opt_in_source", "Informe a origem do consentimento."],
        ["opt_in_at", "Informe a data do consentimento."],
        ["opt_in_purpose", "Informe a finalidade autorizada."],
        ["opt_in_text_version", "Informe a versão do texto aceito."],
        ["opt_in_evidence_note", "Informe uma evidência ou referência verificável do consentimento."],
      ];
      const missing = requiredConsentFields.find(([name]) => !String(values[name] || "").trim());
      if (missing) { bridge.notify(missing[1], "error"); form.elements[missing[0]]?.focus(); return; }
    }
    const payload = {
      name: values.name.trim(), phone: onlyDigits(values.phone), email: values.email?.trim() || null,
      labels: String(values.labels || "").split(",").map((item) => item.trim()).filter(Boolean), notes: values.notes?.trim() || null,
      internal_notes: values.internal_notes?.trim() || null, custom_fields: customFields, opt_in: Boolean(values.opt_in),
      opt_in_source: values.opt_in_source?.trim() || null, opt_in_at: values.opt_in_at ? new Date(values.opt_in_at).toISOString() : null,
      opt_in_purpose: values.opt_in_purpose?.trim() || null,
      opt_in_categories: String(values.opt_in_categories || "").split(",").map((item) => item.trim()).filter(Boolean),
      opt_in_text_version: values.opt_in_text_version?.trim() || null,
      opt_in_evidence: values.opt_in ? { capture_method: "manual_ui", note: values.opt_in_evidence_note.trim(), captured_at: new Date().toISOString() } : {},
    };
    await runRpc("wa_upsert_contact", { p_store_id: selectedStoreId, p_contact_id: values.contact_id || null, p_payload: payload }, values.contact_id ? "Contato atualizado." : "Contato criado.");
    closeDialog();
    await loadSectionData("contacts");
    renderContent();
  }

  async function saveCampaign(form) {
    const values = formValues(form);
    const contactIds = Array.isArray(values.contact_ids) ? values.contact_ids : values.contact_ids ? [values.contact_ids] : [];
    const allOptedIn = values.all_opted_in === true;
    if (!allOptedIn && !contactIds.length) { bridge.notify("Selecione pelo menos um contato com opt-in ou use toda a base autorizada.", "error"); return; }
    if (!selectedConnectionId) { bridge.notify("Configure e selecione uma conexão antes de criar a campanha.", "error"); return; }
    if (values.launch_mode === "schedule" && !values.scheduled_at) { bridge.notify("Informe a data e a hora para programar a campanha.", "error"); form.elements.scheduled_at.focus(); return; }
    const perMinute = Number(values.rate_per_minute || 30);
    const payload = {
      name: values.name.trim(),
      template_id: values.template_id,
      connection_id: selectedConnectionId,
      audience_mode: allOptedIn ? "all_opted_in" : "selected",
      audience_filter: { mode: allOptedIn ? "all_opted_in" : "selected" },
      resolve_audience: true,
      ...(allOptedIn ? {} : { contact_ids: contactIds }),
      scheduled_at: values.launch_mode === "start" ? null : values.scheduled_at ? new Date(values.scheduled_at).toISOString() : null,
      messages_per_second: Math.max(0.1, Math.min(80, perMinute / 60)),
      template_parameters: templateComponentsForValues(messageParameters(values.template_values)),
    };
    const created = await runEdge("create-campaign", payload, "Campanha criada.");
    const campaignId = typeof created === "string" ? created : created?.id || created?.campaign_id;
    if (values.launch_mode !== "draft" && campaignId) await runEdge("action-campaign", { campaign_id: campaignId, command: "start" }, values.launch_mode === "schedule" ? "Campanha programada." : "Campanha iniciada.");
    closeDialog();
    await loadSectionData("campaigns");
    renderContent();
  }

  async function saveTemplate(form) {
    const values = formValues(form);
    let buttons = [];
    if (values.buttons_json?.trim()) {
      try { buttons = JSON.parse(values.buttons_json); if (!Array.isArray(buttons)) throw new Error(); } catch (_) { bridge.notify("Botões: informe uma lista JSON válida.", "error"); form.elements.buttons_json.focus(); return; }
    }
    const bodyText = values.body_text.trim();
    const examples = messageParameters(values.body_examples);
    const variableIndexes = [...bodyText.matchAll(/\{\{(\d+)\}\}/g)].map((match) => Number(match[1]));
    const requiredExamples = variableIndexes.length ? Math.max(...variableIndexes) : 0;
    if (requiredExamples && examples.length < requiredExamples) { bridge.notify(`Informe ${requiredExamples} exemplo(s), um para cada variável do corpo.`, "error"); form.elements.body_examples.focus(); return; }
    if (values.header_type === "TEXT" && !values.header_text?.trim()) { bridge.notify("Digite o texto do cabeçalho.", "error"); form.elements.header_text.focus(); return; }
    const components = [];
    if (values.header_type === "TEXT") components.push({ type: "HEADER", format: "TEXT", text: values.header_text.trim() });
    components.push({ type: "BODY", text: bodyText, ...(requiredExamples ? { example: { body_text: [examples.slice(0, requiredExamples)] } } : {}) });
    if (values.footer_text?.trim()) components.push({ type: "FOOTER", text: values.footer_text.trim() });
    if (buttons.length) components.push({ type: "BUTTONS", buttons });
    const payload = { template_id: values.template_id || null, provider_template_id: values.provider_template_id || null, name: values.name.trim(), category: values.category, language: values.language, components };
    await runEdge("create-template", { template: payload }, values.template_id || values.provider_template_id ? "Template atualizado na Meta." : "Template enviado à Meta para análise.");
    closeDialog();
    await loadSectionData("templates");
    renderContent();
  }

  async function saveConnection(form) {
    const payload = normalizeConnectionPayload(connectionDraftFromCurrentForm());
    await runEdge("save-connection", payload, "Conexão salva com segurança.");
    await loadBootstrap({ silent: true });
    renderContent();
  }

  async function updateToken(form) {
    const token = form.elements.access_token.value.trim();
    await runEdge("update-token", { access_token: token }, "Token validado e atualizado.");
    form.reset();
    closeDialog();
    await loadBootstrap({ silent: true });
    renderContent();
  }

  function messageParameters(value) {
    return String(value || "").split(/\r?\n/).map((item) => item.trim()).filter(Boolean);
  }

  function templateComponentsForValues(values) {
    if (!values?.length) return [];
    return [{ type: "body", parameters: values.map((text) => ({ type: "text", text })) }];
  }

  async function sendNewConversation(form) {
    const values = formValues(form);
    const template = data.templates.find((item) => item.id === values.template_id);
    const contact = data.contacts.find((item) => item.id === values.contact_id);
    if (!template) { bridge.notify("Template aprovado não encontrado. Sincronize os templates e tente novamente.", "error"); return; }
    if (!hasMarketingConsent(contact)) { bridge.notify("Selecione um contato com autorização válida.", "error"); return; }
    await runEdge("send-message", { contact_id: contact.id, type: "template", template_name: template.name, template_language: template.language || template.language_code || "pt_BR", template_parameters: templateComponentsForValues(messageParameters(values.parameters)) }, "Template aceito para envio.");
    closeDialog();
    activeSection = "conversations";
    await loadSectionData("conversations");
    render();
  }

  async function sendTemplate(form) {
    const values = formValues(form);
    const template = data.templates.find((item) => item.id === values.template_id);
    if (!template) { bridge.notify("Template aprovado não encontrado. Sincronize os templates e tente novamente.", "error"); return; }
    await runEdge("send-message", { ...(form.id === "waTemplateSendForm" && selectedConversationId ? { conversation_id: selectedConversationId } : {}), ...(values.phone ? { to: onlyDigits(values.phone) } : {}), type: "template", template_name: template.name, template_language: template.language || template.language_code || "pt_BR", template_parameters: templateComponentsForValues(messageParameters(values.parameters)) }, "Template aceito para envio.");
    closeDialog();
    if (selectedConversationId) await loadMessages(selectedConversationId, { silent: true });
    renderContent();
  }

  function attachmentLimit(file) {
    if (file.type.startsWith("image/")) return 5 * 1024 * 1024;
    if (file.type.startsWith("audio/") || file.type.startsWith("video/")) return 16 * 1024 * 1024;
    return 100 * 1024 * 1024;
  }

  async function sendAttachment(file) {
    const limit = attachmentLimit(file);
    if (file.size > limit) {
      bridge.notify(`O arquivo excede o limite permitido para este tipo (${formatNumber(limit / 1024 / 1024)} MB).`, "error");
      return;
    }
    if (!bridge.upload) {
      bridge.notify("O serviço seguro de upload ainda não está disponível.", "error");
      return;
    }
    busy = true;
    try {
      bridge.notify(`Enviando ${file.name} com segurança...`, "info");
      const response = unwrapEdge(await bridge.upload({ connectionId: selectedConnectionId, file }));
      const mediaId = response?.id || response?.media_id;
      if (!mediaId) throw new Error("A Meta não retornou o identificador da mídia.");
      const kind = file.type.startsWith("image/") ? "image" : file.type.startsWith("audio/") ? "audio" : file.type.startsWith("video/") ? "video" : "document";
      const mediaContent = { id: mediaId, ...(kind === "document" ? { filename: file.name } : {}) };
      await runEdge("send-message", { conversation_id: selectedConversationId, type: kind, [kind]: mediaContent }, "Arquivo colocado na fila.");
      await loadMessages(selectedConversationId, { silent: true });
      renderContent();
    } catch (error) {
      if (error?.waHandled) return;
      if (await handleEntitlementLoss(error)) return;
      bridge.notify(operationErrorMessage(error), "error");
    } finally { busy = false; }
  }

  async function importContacts(file) {
    if (file.size > 10 * 1024 * 1024) { bridge.notify("A lista CSV deve ter no máximo 10 MB por importação.", "error"); return; }
    try {
      const csvText = await file.text();
      const csvLineCount = String(csvText || "").split(/\r?\n/).filter((line) => line.trim()).length - 1;
      const parsedRows = parseCsv(csvText);
      const incompleteConsent = parsedRows.filter((row) => row._consent_incomplete).length;
      const rows = parsedRows.map(({ _consent_incomplete: _, ...row }) => row);
      if (!rows.length) throw new Error("Nenhum contato válido foi encontrado no CSV.");
      if (csvLineCount > 5000) bridge.notify("O lote foi limitado aos primeiros 5.000 contatos. Importe o restante em outro arquivo.", "warning");
      if (incompleteConsent) bridge.notify(`${incompleteConsent} contato(s) foram importados sem opt-in porque a prova de consentimento estava incompleta.`, "warning");
      const result = await runEdge("import-contacts", { contacts: rows }, `${formatNumber(rows.length)} contatos enviados para importação.`);
      const failures = Number(result?.failed || result?.failures?.length || 0);
      if (failures) bridge.notify(`${failures} linha(s) não puderam ser importadas. Consulte os logs para detalhes.`, "warning");
      await loadSectionData("contacts");
      renderContent();
    } catch (error) {
      if (error?.waHandled) return;
      if (await handleEntitlementLoss(error)) return;
      bridge.notify(operationErrorMessage(error), "error");
    }
  }

  function parseCsv(text) {
    const lines = String(text || "").replace(/^\uFEFF/, "").split(/\r?\n/).filter((line) => line.trim());
    if (lines.length < 2) return [];
    const delimiter = (lines[0].match(/;/g) || []).length > (lines[0].match(/,/g) || []).length ? ";" : ",";
    const headers = parseCsvLine(lines.shift(), delimiter).map((item) => normalize(item).replace(/\s+/g, "_"));
    return lines.slice(0, 5000).map((line) => {
      const cells = parseCsvLine(line, delimiter);
      const raw = Object.fromEntries(headers.map((header, index) => [header, cells[index] || ""]));
      const phone = raw.telefone || raw.phone || raw.whatsapp || raw.numero;
      if (!onlyDigits(phone)) return null;
      const optIn = ["sim", "yes", "true", "1", "x"].includes(normalize(raw.opt_in || raw.consentimento));
      const consentSource = raw.origem_consentimento || raw.opt_in_source || "";
      const consentAt = raw.data_consentimento || raw.opt_in_at || "";
      const consentPurpose = raw.finalidade_consentimento || raw.opt_in_purpose || "";
      const consentVersion = raw.versao_consentimento || raw.opt_in_text_version || "";
      const consentEvidence = raw.evidencia_consentimento || raw.opt_in_evidence || "";
      const completeConsent = optIn && [consentSource, consentAt, consentPurpose, consentVersion, consentEvidence].every((value) => String(value).trim());
      return {
        name: raw.nome || raw.name || raw.contato || "",
        phone: onlyDigits(phone),
        email: raw.email || null,
        labels: String(raw.etiquetas || raw.labels || raw.tags || "").split(/[|,]/).map((item) => item.trim()).filter(Boolean),
        opt_in: completeConsent,
        opt_in_source: completeConsent ? consentSource : null,
        opt_in_at: completeConsent ? consentAt : null,
        opt_in_purpose: completeConsent ? consentPurpose : null,
        opt_in_text_version: completeConsent ? consentVersion : null,
        opt_in_evidence: completeConsent ? { capture_method: "csv_import", note: consentEvidence } : {},
        _consent_incomplete: optIn && !completeConsent,
      };
    }).filter(Boolean);
  }

  function parseCsvLine(line, delimiter) {
    const cells = [];
    let cell = "";
    let quoted = false;
    for (let index = 0; index < line.length; index += 1) {
      const char = line[index];
      if (char === '"' && quoted && line[index + 1] === '"') { cell += '"'; index += 1; }
      else if (char === '"') quoted = !quoted;
      else if (char === delimiter && !quoted) { cells.push(cell.trim()); cell = ""; }
      else cell += char;
    }
    cells.push(cell.trim());
    return cells;
  }

  async function openCampaignReport(campaignId) {
    try {
      const response = await bridge.rpc("wa_get_campaign_report", { p_campaign_id: campaignId });
      const report = response?.data || response || {};
      detailRecord = report;
      const campaign = report.campaign || data.campaigns.find((item) => item.id === campaignId) || {};
      const recipients = arrayFrom(report.recipients || report.items);
      openDialog({ title: campaign.name || "Relatório da campanha", subtitle: "Resultado consolidado e status individual de cada destinatário.", icon: "fa-chart-column", size: "large", content: `<div class="wa-metrics">${metricCard("Enviadas", campaign.sent_count, "fa-paper-plane", "blue")}${metricCard("Entregues", campaign.delivered_count, "fa-check-double", "green")}${metricCard("Lidas", campaign.read_count, "fa-eye", "purple")}${metricCard("Falhas", campaign.failed_count, "fa-triangle-exclamation", "red")}</div><div class="wa-report-toolbar"><span>${formatNumber(recipients.length)} de ${formatNumber(report.total ?? recipients.length)} destinatários carregados</span><button class="wa-button is-secondary" type="button" data-wa-action="download-campaign-report" data-id="${escapeHtml(campaignId)}"><i class="fa-solid fa-download"></i>Baixar relatório completo</button></div><div class="wa-table-wrap"><table class="wa-table"><thead><tr><th>Contato</th><th>Número</th><th>Status</th><th>Atualização</th><th>Erro</th></tr></thead><tbody>${recipients.map((item) => `<tr><td data-label="Contato">${escapeHtml(item.contact_name || item.name || "—")}</td><td data-label="Número">${escapeHtml(formatPhone(item.phone || item.phone_e164 || item.wa_id))}</td><td data-label="Status">${statusBadge(item.status)}</td><td data-label="Atualização">${escapeHtml(formatDateTime(item.updated_at || item.sent_at))}</td><td data-label="Erro">${escapeHtml(item.error_message || "—")}</td></tr>`).join("")}</tbody></table></div>` });
    } catch (error) {
      if (await handleEntitlementLoss(error)) return;
      bridge.notify(operationErrorMessage(error), "error");
    }
  }

  async function downloadFullCampaignReport(campaignId) {
    if (!campaignId) return bridge.notify("Campanha não encontrada.", "error");
    try {
      const recipients = [];
      let offset = 0;
      let total = Number.POSITIVE_INFINITY;
      while (offset < total) {
        const response = unwrapEdge(await bridge.edge("campaign-report", {
          store_id: selectedStoreId,
          ...(selectedConnectionId ? { connection_id: selectedConnectionId } : {}),
          campaign_id: campaignId,
          limit: 1000,
          offset,
        }));
        const page = arrayFrom(response?.recipients || response?.items);
        recipients.push(...page);
        total = Number.isFinite(Number(response?.total)) ? Number(response.total) : offset + page.length;
        offset += page.length;
        if (!page.length || page.length < 1000) break;
      }
      downloadCsv("relatorio-completo-campanha-whatsapp.csv", recipients.map((item) => ({
        contato: item.contact_name || item.name,
        telefone: item.phone || item.phone_e164 || item.wa_id,
        status: item.status,
        enfileirado_em: item.queued_at,
        enviado_em: item.sent_at,
        entregue_em: item.delivered_at,
        lido_em: item.read_at,
        falhou_em: item.failed_at,
        codigo_erro: item.error_code,
        erro: item.error_message,
      })));
    } catch (error) {
      if (await handleEntitlementLoss(error)) return;
      bridge.notify(operationErrorMessage(error), "error");
    }
  }

  function downloadCsv(filename, rows) {
    if (!rows?.length) { bridge.notify("Não há dados para exportar.", "warning"); return; }
    const headers = [...new Set(rows.flatMap((row) => Object.keys(row)))];
    const encode = (value) => {
      let safe = String(value ?? "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "");
      if (/^[=+\-@\t\r]/.test(safe)) safe = `'${safe}`;
      return `"${safe.replace(/"/g, '""')}"`;
    };
    const csv = `\uFEFF${headers.map(encode).join(";")}\n${rows.map((row) => headers.map((header) => encode(row[header])).join(";")).join("\n")}`;
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url; link.download = filename; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function releaseMediaObjectUrls() {
    mediaObjectUrls.forEach((url) => URL.revokeObjectURL(url));
    mediaObjectUrls.clear();
  }

  function rememberMediaObjectUrl(id, url) {
    const previous = mediaObjectUrls.get(id);
    if (previous) URL.revokeObjectURL(previous);
    mediaObjectUrls.delete(id);
    mediaObjectUrls.set(id, url);
    while (mediaObjectUrls.size > MAX_MEDIA_OBJECT_URLS) {
      const oldestId = mediaObjectUrls.keys().next().value;
      const oldestUrl = mediaObjectUrls.get(oldestId);
      if (oldestUrl) URL.revokeObjectURL(oldestUrl);
      mediaObjectUrls.delete(oldestId);
    }
  }

  async function handleWizardValidation(button) {
    if (wizard.validated) { wizard.step = 3; renderWizardDialog(); return; }
    await withButtonBusy(button, async () => {
      const result = await runEdge("validate", normalizeConnectionPayload(wizard.draft), "Credenciais validadas.");
      wizard.validationDetails = result?.diagnostics || result;
      wizard.validated = true;
      wizard.step = 3;
      renderWizardDialog();
    });
  }

  async function handleWizardWebhook(button) {
    if (wizard.webhookRegistered) { wizard.step = 4; await ensureSectionData(["contacts", "templates"]); renderWizardDialog(); return; }
    await withButtonBusy(button, async () => {
      const saved = await runEdge("save-connection", normalizeConnectionPayload(wizard.draft));
      selectedConnectionId = saved?.connection_id || saved?.id || selectedConnectionId;
      await runEdge("register-webhook", { connection_id: selectedConnectionId }, "Webhook registrado com sucesso.");
      wizard.webhookRegistered = true;
      wizard.step = 4;
      await loadBootstrap({ silent: true });
      await ensureSectionData(["contacts", "templates"]);
      renderWizardDialog();
    });
  }

  function saveWizardCredentials(form) {
    const values = formValues(form);
    wizard.draft = {
      ...wizard.draft,
      ...values,
      phone_number: values.phone_number,
      webhook_url: wizard.draft.webhook_url || `${String(bridge?.supabaseUrl || "").replace(/\/$/, "")}/functions/v1/whatsapp-webhook`,
      api_version: values.api_version || "v26.0",
    };
    wizard.validated = false;
    wizard.validationDetails = null;
    wizard.webhookRegistered = false;
    wizard.testSent = false;
    wizard.step = 2;
    renderWizardDialog();
  }

  async function sendWizardTest(form) {
    if (wizard.testSent) { wizard.step = 5; renderWizardDialog(); return; }
    const values = formValues(form);
    const template = data.templates.find((item) => item.id === values.template_id);
    const contact = data.contacts.find((item) => item.id === values.contact_id);
    if (!template) { bridge.notify("Escolha um template aprovado e sincronizado.", "error"); return; }
    if (!hasMarketingConsent(contact)) { bridge.notify("Escolha um contato com consentimento válido.", "error"); return; }
    const result = await runEdge("test-send", { contact_id: contact.id, type: "template", template_name: template.name, template_language: template.language || template.language_code || "pt_BR", template_parameters: templateComponentsForValues(messageParameters(values.parameters)) }, "Teste registrado e colocado na fila.");
    wizard.draft.test_contact_id = contact.id;
    wizard.testMessageId = result?.message_id || "";
    wizard.testSent = true;
    wizard.step = 5;
    renderWizardDialog();
  }

  window.WhatsAppModule = { activate, deactivate, refreshContext, renderFatalError };
})();
