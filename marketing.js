(function createMarketingAttributionModule(global) {
  "use strict";

  const PROVIDERS = Object.freeze({
    meta: {
      label: "Meta Ads",
      shortLabel: "Meta",
      icon: "fa-brands fa-meta",
      accent: "#1877f2",
    },
    google: {
      label: "Google Ads",
      shortLabel: "Google",
      icon: "fa-brands fa-google",
      accent: "#4285f4",
    },
  });

  const state = {
    initialized: false,
    loading: false,
    profile: null,
    storeId: "",
    storeName: "",
    dateStart: "",
    dateEnd: "",
    targets: null,
    rpc: null,
    edge: null,
    notify: null,
    supabaseUrl: "",
    dashboard: null,
    dashboardError: "",
    connections: [],
    syncRuns: [],
    journeys: [],
    tracker: null,
    activeProvider: "meta",
    lastContextKey: "",
    contextGeneration: 0,
    refreshGeneration: -1,
    refreshPromise: null,
    syncPollTimer: null,
    syncPollAttempts: 0,
    pendingOAuthNotice: null,
    modalTrigger: null,
  };

  const elements = {};

  function initialize(options = {}) {
    state.rpc = typeof options.rpc === "function" ? options.rpc : state.rpc;
    state.edge = typeof options.edge === "function" ? options.edge : state.edge;
    state.notify = typeof options.notify === "function" ? options.notify : state.notify;
    state.supabaseUrl = String(options.supabaseUrl || state.supabaseUrl || "").replace(/\/$/, "");
    if (state.initialized) return;
    cacheElements();
    bindEvents();
    state.initialized = true;
    renderEmptyState();
    handleOAuthReturn();
  }

  function cacheElements() {
    [
      "marketingApiPanel",
      "marketingApiMetrics",
      "marketingApiBreakdown",
      "marketingJourneyList",
      "marketingApiLastSync",
      "marketingAttributionCoverage",
      "marketingAttributionCoverageBar",
      "analyticsCpl",
      "analyticsCplHint",
      "analyticsCac",
      "analyticsRoas",
      "marketingDataBadge",
      "marketingGoalSummary",
      "marketingSourcePerformanceList",
      "marketingConnectButton",
      "marketingSyncButton",
      "marketingConnectionModal",
      "marketingConnectionClose",
      "marketingConnectionStoreName",
      "marketingConnectionForm",
      "marketingConnectionName",
      "marketingConnectionMessage",
      "marketingConnectionSave",
      "marketingConnectionTest",
      "marketingConnectionDisconnect",
      "marketingMetaFields",
      "marketingMetaAdAccountId",
      "marketingMetaPixelId",
      "marketingMetaAccessToken",
      "marketingMetaApiVersion",
      "marketingGoogleFields",
      "marketingGoogleCustomerId",
      "marketingGoogleLoginCustomerId",
      "marketingGoogleConversionActionId",
      "marketingGoogleDeveloperToken",
      "marketingGoogleClientId",
      "marketingGoogleClientSecret",
      "marketingGoogleRefreshToken",
      "marketingGoogleCallbackUrl",
      "marketingGoogleCallbackCopy",
      "marketingGoogleOAuth",
      "marketingTrackerSnippet",
      "marketingTrackerCopy",
      "marketingTrackerRotate",
      "marketingTrackerStatus",
      "marketingTrackerOrigin",
      "marketingSyncHistory",
      "metaConnectionStatus",
      "metaConnectionBadge",
      "googleConnectionStatus",
      "googleConnectionBadge",
    ].forEach((id) => {
      elements[id] = document.getElementById(id);
    });
    elements.providerTabs = Array.from(document.querySelectorAll("[data-marketing-provider-tab]"));
    elements.providerButtons = Array.from(document.querySelectorAll("[data-marketing-provider-configure]"));
  }

  function bindEvents() {
    elements.marketingConnectButton?.addEventListener("click", () => openConnectionModal(preferredProvider()));
    elements.marketingSyncButton?.addEventListener("click", handleSyncAll);
    elements.marketingConnectionClose?.addEventListener("click", closeConnectionModal);
    elements.marketingConnectionModal?.addEventListener("click", (event) => {
      if (event.target === elements.marketingConnectionModal) closeConnectionModal();
    });
    elements.marketingConnectionForm?.addEventListener("submit", handleSaveConnection);
    elements.marketingConnectionTest?.addEventListener("click", handleTestConnection);
    elements.marketingConnectionDisconnect?.addEventListener("click", handleDisconnectConnection);
    elements.marketingGoogleOAuth?.addEventListener("click", handleGoogleOAuth);
    elements.marketingGoogleCallbackCopy?.addEventListener("click", copyGoogleCallbackUrl);
    elements.marketingTrackerCopy?.addEventListener("click", copyTrackerSnippet);
    elements.marketingTrackerRotate?.addEventListener("click", rotateTrackerToken);
    elements.providerTabs.forEach((button) => {
      button.addEventListener("click", () => selectProvider(button.dataset.marketingProviderTab));
      button.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
        event.preventDefault();
        const direction = event.key === "ArrowRight" ? 1 : -1;
        const index = elements.providerTabs.indexOf(button);
        const next = elements.providerTabs[(index + direction + elements.providerTabs.length) % elements.providerTabs.length];
        next?.focus();
        next?.click();
      });
    });
    elements.providerButtons.forEach((button) => {
      button.addEventListener("click", () => openConnectionModal(button.dataset.marketingProviderConfigure));
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && elements.marketingConnectionModal && !elements.marketingConnectionModal.hidden) {
        closeConnectionModal();
      }
      if (event.key === "Tab" && elements.marketingConnectionModal && !elements.marketingConnectionModal.hidden) {
        trapModalFocus(event);
      }
    });
  }

  async function setContext(context = {}, options = {}) {
    if (!state.initialized) initialize(context);
    const nextStoreId = String(context.storeId || "");
    const storeChanged = nextStoreId !== state.storeId;
    if (Object.prototype.hasOwnProperty.call(context, "profile")) state.profile = context.profile || null;
    state.storeId = nextStoreId;
    state.storeName = String(context.storeName || "");
    const normalizedRange = normalizeDateRange(context.dateStart, context.dateEnd, 730);
    state.dateStart = normalizedRange.start;
    state.dateEnd = normalizedRange.end;
    state.targets = context.targets || null;
    state.rpc = typeof context.rpc === "function" ? context.rpc : state.rpc;
    state.edge = typeof context.edge === "function" ? context.edge : state.edge;
    state.notify = typeof context.notify === "function" ? context.notify : state.notify;
    state.supabaseUrl = String(context.supabaseUrl || state.supabaseUrl || "").replace(/\/$/, "");

    const contextKey = [state.profile?.id, state.storeId, state.dateStart, state.dateEnd].join(":");
    const contextChanged = contextKey !== state.lastContextKey;
    const shouldRefresh = Boolean(options.refresh) || contextChanged;
    if (contextChanged) state.contextGeneration += 1;
    if (storeChanged) {
      stopSyncPolling();
      state.dashboard = null;
      state.dashboardError = "";
      state.connections = [];
      state.syncRuns = [];
      state.journeys = [];
      state.tracker = null;
      clearTrackerUi();
      if (elements.marketingConnectionModal && !elements.marketingConnectionModal.hidden) closeConnectionModal();
    }
    state.lastContextKey = contextKey;

    flushOAuthNotice();

    syncPermissions();
    if (!state.storeId) {
      state.dashboard = null;
      state.dashboardError = "";
      state.connections = [];
      state.syncRuns = [];
      state.journeys = [];
      state.tracker = null;
      renderEmptyState();
      return;
    }

    if (shouldRefresh) await refresh();
    else renderAll();
  }

  async function refresh({ silent = false } = {}) {
    if (!state.storeId || typeof state.edge !== "function") {
      renderEmptyState();
      return;
    }
    const generation = state.contextGeneration;
    if (state.refreshPromise && state.refreshGeneration === generation) return state.refreshPromise;
    state.loading = true;
    state.refreshGeneration = generation;
    renderLoading();

    const activePromise = (async () => {
      const basePayload = {
        store_id: state.storeId,
        start_date: state.dateStart || null,
        end_date: state.dateEnd || null,
      };
      const [dashboardResult, connectionsResult, syncRunsResult, journeysResult] = await Promise.allSettled([
        request("get-dashboard", basePayload),
        request("list-connections", { store_id: state.storeId }),
        request("list-sync-runs", { store_id: state.storeId, limit: 8 }),
        request("list-journey", { ...basePayload, limit: 12 }),
      ]);

      if (generation !== state.contextGeneration) return;
      state.dashboard = dashboardResult.status === "fulfilled" ? unwrap(dashboardResult.value) : null;
      state.dashboardError = dashboardResult.status === "rejected" ? readableError(dashboardResult.reason) : "";
      state.connections = connectionsResult.status === "fulfilled"
        ? normalizeRows(unwrap(connectionsResult.value), ["connections", "items", "rows"])
        : [];
      state.syncRuns = syncRunsResult.status === "fulfilled"
        ? normalizeRows(unwrap(syncRunsResult.value), ["runs", "items", "rows"])
        : [];
      state.journeys = journeysResult.status === "fulfilled"
        ? normalizeRows(unwrap(journeysResult.value), ["journeys", "items", "rows", "leads"])
        : [];

      const firstFailure = [dashboardResult, connectionsResult, syncRunsResult, journeysResult]
        .find((result) => result.status === "rejected");
      if (firstFailure && !silent && !state.dashboard && !state.connections.length) {
        notify(readableError(firstFailure.reason), "error");
      }
      renderAll();
    })().finally(() => {
      if (state.refreshPromise === activePromise) {
        state.loading = false;
        state.refreshPromise = null;
        state.refreshGeneration = -1;
      }
    });
    state.refreshPromise = activePromise;
    return activePromise;
  }

  function unwrap(value) {
    if (value && typeof value === "object" && "data" in value && value.data !== undefined) return value.data;
    return value;
  }

  function normalizeRows(value, keys = []) {
    if (Array.isArray(value)) return value;
    for (const key of keys) {
      if (Array.isArray(value?.[key])) return value[key];
    }
    return [];
  }

  async function request(action, payload = {}) {
    if (typeof state.edge !== "function") throw new Error("O serviço de atribuição ainda não foi carregado.");
    const result = await state.edge(action, payload);
    if (result?.ok === false) {
      const error = result.error || {};
      throw new Error(error.message || "Não foi possível concluir a operação.");
    }
    return result;
  }

  function renderAll() {
    if (!state.storeId) return renderEmptyState();
    if (state.dashboardError) renderDashboardError();
    else renderDashboard();
    renderConnections();
    renderSyncRuns();
    renderJourneys();
    syncPermissions();
  }

  function renderLoading() {
    if (!elements.marketingApiMetrics) return;
    elements.marketingApiPanel?.setAttribute("aria-busy", "true");
    elements.marketingApiMetrics.innerHTML = Array.from({ length: 6 }, () => (
      '<span class="marketing-api-skeleton" aria-hidden="true"></span>'
    )).join("");
  }

  function renderEmptyState() {
    elements.marketingApiPanel?.removeAttribute("aria-busy");
    if (elements.marketingApiMetrics) {
      elements.marketingApiMetrics.innerHTML = `
        <div class="marketing-api-empty">
          <i class="fa-solid fa-link" aria-hidden="true"></i>
          <div><strong>Selecione um cliente</strong><span>As contas de anúncio e métricas ficam isoladas por loja.</span></div>
        </div>`;
    }
    if (elements.marketingApiBreakdown) elements.marketingApiBreakdown.innerHTML = "";
    if (elements.marketingJourneyList) elements.marketingJourneyList.innerHTML = "";
    if (elements.marketingApiLastSync) elements.marketingApiLastSync.textContent = "Sem sincronização";
    if (elements.marketingAttributionCoverage) elements.marketingAttributionCoverage.textContent = "0%";
    if (elements.marketingAttributionCoverageBar) elements.marketingAttributionCoverageBar.style.width = "0%";
  }

  function renderDashboardError() {
    elements.marketingApiPanel?.removeAttribute("aria-busy");
    if (elements.marketingApiMetrics) {
      elements.marketingApiMetrics.innerHTML = `
        <div class="marketing-api-empty is-error">
          <i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>
          <div><strong>Não foi possível carregar as métricas</strong><span>${escapeHtml(state.dashboardError)}</span></div>
        </div>`;
    }
    if (elements.marketingApiBreakdown) elements.marketingApiBreakdown.innerHTML = "";
    if (elements.marketingApiLastSync) elements.marketingApiLastSync.textContent = "Falha ao consultar o período";
    if (elements.marketingAttributionCoverage) elements.marketingAttributionCoverage.textContent = "—";
    if (elements.marketingAttributionCoverageBar) elements.marketingAttributionCoverageBar.style.width = "0%";
  }

  function renderDashboard() {
    elements.marketingApiPanel?.removeAttribute("aria-busy");
    const dashboard = state.dashboard || {};
    const summary = dashboard.summary || dashboard.metrics || dashboard.overview || {};
    const spend = numberFrom(summary, ["spend", "total_spend", "investment"]);
    const impressions = numberFrom(summary, ["impressions", "total_impressions"]);
    const reach = numberFrom(summary, ["reach", "total_reach"]);
    const clicks = numberFrom(summary, ["clicks", "total_clicks"]);
    const conversions = numberFrom(summary, ["platform_conversions", "conversions", "purchases"]);
    const ctr = numberOrNull(summary, ["ctr", "click_through_rate"])
      ?? (impressions > 0 ? (clicks / impressions) * 100 : null);
    const cpc = numberOrNull(summary, ["cpc", "cost_per_click"])
      ?? (clicks > 0 ? spend / clicks : null);
    const cpm = numberOrNull(summary, ["cpm", "cost_per_mille"])
      ?? (impressions > 0 ? (spend / impressions) * 1000 : null);

    const metrics = [
      { label: "Investimento", value: formatCurrency(spend), icon: "fa-wallet" },
      { label: "Impressões", value: formatCompact(impressions), icon: "fa-eye" },
      { label: "Alcance", value: formatCompact(reach), icon: "fa-users-viewfinder" },
      { label: "Cliques", value: formatCompact(clicks), icon: "fa-arrow-pointer" },
      { label: "CTR", value: ctr === null ? "—" : `${formatDecimal(ctr)}%`, icon: "fa-percent" },
      { label: "CPC", value: cpc === null ? "—" : formatCurrency(cpc), icon: "fa-coins" },
      { label: "CPM", value: cpm === null ? "—" : formatCurrency(cpm), icon: "fa-chart-column" },
      { label: "Conversões da mídia", value: formatCompact(conversions), icon: "fa-bullseye" },
    ];

    renderSharedMarketingMetrics(summary);
    renderSharedMarketingGoals(summary);

    if (elements.marketingApiMetrics) {
      elements.marketingApiMetrics.innerHTML = metrics.map((metric) => `
        <article class="marketing-api-metric">
          <span><i class="fa-solid ${metric.icon}" aria-hidden="true"></i>${escapeHtml(metric.label)}</span>
          <strong>${escapeHtml(metric.value)}</strong>
        </article>`).join("");
    }

    const coverage = clamp(numberFrom(
      dashboard.data_quality || dashboard.attribution || summary,
      ["attribution_rate", "coverage_percent", "attribution_coverage", "coverage"],
    ), 0, 100);
    if (elements.marketingAttributionCoverage) elements.marketingAttributionCoverage.textContent = `${formatDecimal(coverage)}%`;
    if (elements.marketingAttributionCoverageBar) elements.marketingAttributionCoverageBar.style.width = `${coverage}%`;

    const breakdown = normalizeRows(dashboard, ["breakdown", "campaigns", "sources", "rows"]);
    renderBreakdown(breakdown);

    const lastSync = dashboard.last_sync_at
      || state.connections.map((row) => row.last_sync_at).filter(Boolean).sort().at(-1)
      || "";
    if (elements.marketingApiLastSync) {
      elements.marketingApiLastSync.textContent = lastSync
        ? `Atualizado ${formatDateTime(lastSync)}`
        : connectedProviders().length
        ? "Aguardando primeira sincronização"
        : "Conecte uma conta para importar os dados";
    }
  }

  function renderBreakdown(rows) {
    if (!elements.marketingApiBreakdown) return;
    if (!rows.length) {
      elements.marketingApiBreakdown.innerHTML = `
        <div class="marketing-breakdown-empty">
          <span><i class="fa-solid fa-chart-simple" aria-hidden="true"></i></span>
          <div><strong>Nenhuma mídia sincronizada no período</strong><small>Conecte Meta ou Google e faça a primeira sincronização.</small></div>
        </div>`;
      return;
    }

    elements.marketingApiBreakdown.innerHTML = rows.slice(0, 12).map((row) => {
      const provider = normalizeProvider(row.provider || row.platform);
      const info = PROVIDERS[provider] || { label: row.platform || "Mídia", icon: "fa-solid fa-chart-line" };
      const spend = numberFrom(row, ["spend", "total_spend"]);
      const clicks = numberFrom(row, ["clicks", "total_clicks"]);
      const leads = numberFrom(row, ["leads", "platform_leads", "attributed_leads"]);
      const purchases = numberFrom(row, ["purchases", "conversions", "platform_conversions"]);
      const revenue = numberFrom(row, ["revenue", "conversion_value", "platform_conversion_value"]);
      const roas = spend > 0 ? revenue / spend : null;
      const title = row.campaign_name || row.campaign || row.name || info.label;
      return `
        <article class="marketing-breakdown-row" style="--provider-accent:${escapeHtml(info.accent || "#2f8cff")}">
          <div class="marketing-breakdown-name">
            <span class="marketing-provider-mini"><i class="${escapeHtml(info.icon)}" aria-hidden="true"></i></span>
            <div><strong>${escapeHtml(title)}</strong><small>${escapeHtml(info.label)}</small></div>
          </div>
          <span><small>Investimento</small><b>${formatCurrency(spend)}</b></span>
          <span><small>Cliques</small><b>${formatCompact(clicks)}</b></span>
          <span><small>Leads</small><b>${formatCompact(leads)}</b></span>
          <span><small>Compras</small><b>${formatCompact(purchases)}</b></span>
          <span><small>ROAS</small><b>${roas === null ? "—" : `${formatDecimal(roas)}x`}</b></span>
        </article>`;
    }).join("");
    renderSharedSourcePerformance(rows);
  }

  function renderSharedMarketingMetrics(summary) {
    const spend = numberFrom(summary, ["spend", "total_spend", "investment"]);
    const connected = connectedProviders().length > 0;
    if (!connected && spend <= 0) return;
    const cpl = numberOrNull(summary, ["cpl", "cost_per_lead"]);
    const cac = numberOrNull(summary, ["cac", "customer_acquisition_cost"]);
    const roas = numberOrNull(summary, ["roas"]);
    if (elements.analyticsCpl) elements.analyticsCpl.textContent = cpl === null ? "—" : formatCurrency(cpl);
    if (elements.analyticsCac) elements.analyticsCac.textContent = cac === null ? "—" : formatCurrency(cac);
    if (elements.analyticsRoas) elements.analyticsRoas.textContent = roas === null ? "—" : `${formatDecimal(roas)}x`;
    if (elements.analyticsCplHint) {
      elements.analyticsCplHint.textContent = spend > 0
        ? `${formatCurrency(spend)} importados das contas de anúncio`
        : "Conta conectada · sem investimento no período";
    }
    if (elements.marketingDataBadge) {
      elements.marketingDataBadge.textContent = connected
        ? "Mídia conectada + dados próprios"
        : "Histórico de mídia + dados próprios";
      elements.marketingDataBadge.classList.toggle("is-connected", connected);
    }
  }

  function renderSharedMarketingGoals(summary) {
    if (!elements.marketingGoalSummary || !state.targets) return;
    const target = state.targets;
    const goals = [
      { label: "Leads", value: numberFrom(summary, ["leads", "total_leads"]), target: target.leadGoal },
      { label: "Qualificados", value: numberFrom(summary, ["qualified"]), target: target.qualifiedGoal },
      { label: "Vendas", value: numberFrom(summary, ["purchases", "sales"]), target: target.salesGoal },
      { label: "Receita", value: numberFrom(summary, ["revenue"]), target: target.revenueGoal, currency: true },
      { label: "Orçamento usado", value: numberFrom(summary, ["spend"]), target: target.monthlyBudget, currency: true, budget: true },
    ].filter((item) => item.target !== null && item.target !== undefined);
    if (!goals.length) return;
    elements.marketingGoalSummary.innerHTML = goals.map((item) => {
      const percent = Number(item.target) > 0 ? Math.round((item.value / Number(item.target)) * 100) : 0;
      const progress = clamp(percent, 0, 100);
      return `
        <article class="marketing-goal-card${item.budget && percent > 100 ? " is-alert" : ""}">
          <div><span>${escapeHtml(item.label)}</span><b>${percent}%</b></div>
          <strong>${item.currency ? formatCurrency(item.value) : formatCompact(item.value)} <small>de ${item.currency ? formatCurrency(item.target) : formatCompact(item.target)}</small></strong>
          <div class="marketing-goal-track"><i style="width:${progress}%"></i></div>
        </article>`;
    }).join("");
  }

  function renderSharedSourcePerformance(rows) {
    if (!elements.marketingSourcePerformanceList || !rows.length || !connectedProviders().length) return;
    elements.marketingSourcePerformanceList.innerHTML = rows.slice(0, 8).map((row) => {
      const provider = normalizeProvider(row.provider || row.platform);
      const spend = numberFrom(row, ["spend", "total_spend"]);
      const leads = numberFrom(row, ["attributed_leads", "leads", "platform_leads"]);
      const purchases = numberFrom(row, ["platform_conversions", "purchases", "conversions"]);
      const revenue = numberFrom(row, ["platform_conversion_value", "conversion_value", "revenue"]);
      const roas = spend > 0 ? revenue / spend : null;
      const conversion = leads > 0 ? `${formatDecimal((purchases / leads) * 100)}%` : "—";
      return `
        <article class="marketing-source-row">
          <div class="marketing-source-name"><strong>${escapeHtml(row.campaign_name || row.name || "Sem campanha")}</strong><small>${escapeHtml(PROVIDERS[provider]?.label || "Mídia")} · ${formatCompact(leads)} leads</small></div>
          <span><small>Vendas</small><b>${formatCompact(purchases)}</b></span>
          <span><small>Receita da plataforma</small><b>${formatCurrency(revenue)}</b></span>
          <span><small>Investimento</small><b>${formatCurrency(spend)}</b></span>
          <span><small>ROAS</small><b>${roas === null ? "—" : `${formatDecimal(roas)}x`}</b></span>
          <span><small>Conversão</small><b>${conversion}</b></span>
        </article>`;
    }).join("");
  }

  function renderConnections() {
    Object.keys(PROVIDERS).forEach((provider) => {
      const connection = findConnection(provider);
      const status = normalizeStatus(connection?.status);
      const badge = elements[`${provider}ConnectionBadge`];
      const label = elements[`${provider}ConnectionStatus`];
      if (badge) {
        badge.textContent = statusLabel(status);
        badge.classList.toggle("is-active", status === "active");
        badge.classList.toggle("is-error", status === "error");
        badge.classList.toggle("is-pending", status === "pending" || status === "warning");
      }
      if (label) {
        label.textContent = status === "active" || status === "warning"
          ? `${connection.account_name || connection.name || connection.connection_name || "Conta conectada"}${connection.last_sync_at ? ` · ${formatDateTime(connection.last_sync_at)}` : ""}`
          : connection?.last_error_message || connection?.last_error || (status === "pending" ? "Validação pendente" : "Aguardando conexão segura");
      }
      const button = elements.providerButtons.find((item) => item.dataset.marketingProviderConfigure === provider);
      if (button) button.innerHTML = connection ? '<i class="fa-solid fa-sliders"></i>Gerenciar' : '<i class="fa-solid fa-plus"></i>Conectar';
    });
  }

  function renderSyncRuns() {
    if (!elements.marketingSyncHistory) return;
    if (!state.syncRuns.length) {
      elements.marketingSyncHistory.innerHTML = '<span class="marketing-sync-empty">Nenhuma sincronização executada.</span>';
      return;
    }
    elements.marketingSyncHistory.innerHTML = state.syncRuns.slice(0, 6).map((run) => {
      const provider = normalizeProvider(run.provider);
      const info = PROVIDERS[provider] || { label: "Mídia", icon: "fa-solid fa-rotate" };
      const status = syncRunStatus(run.status);
      return `
        <div class="marketing-sync-row is-${escapeHtml(status.className)}">
          <span><i class="${escapeHtml(info.icon)}" aria-hidden="true"></i></span>
          <div><strong>${escapeHtml(info.label)} · ${escapeHtml(syncTypeLabel(run.sync_type || run.kind))}</strong><small>${formatDateTime(run.started_at || run.created_at)}</small></div>
          <b>${escapeHtml(status.label)}</b>
        </div>`;
    }).join("");
  }

  function renderJourneys() {
    if (!elements.marketingJourneyList) return;
    if (!state.journeys.length) {
      elements.marketingJourneyList.innerHTML = `
        <div class="marketing-journey-empty">
          <i class="fa-solid fa-route" aria-hidden="true"></i>
          <div><strong>Nenhuma jornada identificada neste período</strong><small>O rastreador começará a ligar cliques e leads assim que for instalado.</small></div>
        </div>`;
      return;
    }

    elements.marketingJourneyList.innerHTML = state.journeys.slice(0, 12).map((journey) => {
      const provider = normalizeProvider(journey.provider || journey.platform || journey.utm_source);
      const info = PROVIDERS[provider] || { label: journey.utm_source || "Origem direta", icon: "fa-solid fa-link", accent: "#7b879b" };
      const stages = normalizeJourneyStages(journey);
      const leadName = journey.lead_name || journey.name || "Lead identificado";
      const source = journey.campaign_name || journey.utm_campaign || journey.source || info.label;
      return `
        <article class="marketing-journey-row" style="--provider-accent:${escapeHtml(info.accent || "#2f8cff")}">
          <div class="marketing-journey-person">
            <span><i class="${escapeHtml(info.icon)}" aria-hidden="true"></i></span>
            <div><strong>${escapeHtml(leadName)}</strong><small>${escapeHtml(source)}</small></div>
          </div>
          <div class="marketing-journey-stages" aria-label="Etapas da jornada">
            ${stages.map((stage) => `
              <span class="${stage.complete ? "is-complete" : ""}">
                <i class="fa-solid ${escapeHtml(stage.icon)}" aria-hidden="true"></i>
                <b>${escapeHtml(stage.label)}</b>
                <small>${escapeHtml(stage.value)}</small>
              </span>`).join('<i class="fa-solid fa-chevron-right" aria-hidden="true"></i>')}
          </div>
        </article>`;
    }).join("");
  }

  function normalizeJourneyStages(journey) {
    const firstTouch = journey.first_touch_at || journey.touchpoint_at;
    const leadAt = journey.lead_created_at || journey.lead_at || journey.created_at;
    const qualifiedAt = journey.qualified_at;
    const purchasedAt = journey.purchased_at || journey.won_at;
    return [
      { label: "Clique", icon: "fa-arrow-pointer", complete: Boolean(firstTouch), value: firstTouch ? formatShortDate(firstTouch) : "—" },
      { label: "Lead", icon: "fa-user-plus", complete: Boolean(leadAt), value: leadAt ? formatShortDate(leadAt) : "—" },
      { label: "Qualificado", icon: "fa-user-check", complete: Boolean(qualifiedAt || journey.qualified), value: qualifiedAt ? formatShortDate(qualifiedAt) : journey.qualified ? "Sim" : "—" },
      { label: "Compra", icon: "fa-bag-shopping", complete: Boolean(purchasedAt || journey.purchased), value: purchasedAt ? formatShortDate(purchasedAt) : journey.purchased ? "Sim" : "—" },
    ];
  }

  function syncPermissions() {
    const canConfigure = ["admin", "technician"].includes(state.profile?.role);
    [elements.marketingConnectButton, elements.marketingSyncButton].forEach((button) => {
      if (button) button.hidden = !canConfigure;
    });
    elements.providerButtons.forEach((button) => { button.hidden = !canConfigure; });
    if (elements.marketingConnectionSave) elements.marketingConnectionSave.hidden = !canConfigure;
    if (elements.marketingConnectionTest) elements.marketingConnectionTest.hidden = !canConfigure;
    if (elements.marketingConnectionDisconnect) elements.marketingConnectionDisconnect.hidden = !canConfigure;
    if (elements.marketingTrackerRotate) elements.marketingTrackerRotate.hidden = !canConfigure;
  }

  function preferredProvider() {
    if (!findConnection("meta")) return "meta";
    if (!findConnection("google")) return "google";
    return "meta";
  }

  async function openConnectionModal(provider = "meta") {
    if (!state.storeId) return notify("Selecione um cliente antes de configurar as integrações.", "error");
    if (!["admin", "technician"].includes(state.profile?.role)) {
      return notify("A configuração das contas é feita pela agência responsável.", "error");
    }
    state.modalTrigger = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    elements.marketingConnectionModal.hidden = false;
    document.body.classList.add("is-marketing-modal-open");
    if (elements.marketingConnectionStoreName) elements.marketingConnectionStoreName.textContent = state.storeName || "Cliente selecionado";
    selectProvider(provider);
    clearMessage();
    clearTrackerUi();
    await loadTrackerConfig().catch((error) => {
      showMessage(`Integrações carregadas, mas o rastreador não respondeu: ${readableError(error)}`, "error");
    });
    renderSyncRuns();
    global.requestAnimationFrame(() => elements.providerTabs.find((button) => button.classList.contains("is-active"))?.focus());
  }

  function closeConnectionModal() {
    if (!elements.marketingConnectionModal) return;
    elements.marketingConnectionModal.hidden = true;
    document.body.classList.remove("is-marketing-modal-open");
    clearSecrets();
    forgetTrackerToken();
    clearTrackerUi();
    clearMessage();
    state.modalTrigger?.focus?.();
    state.modalTrigger = null;
  }

  function selectProvider(provider) {
    state.activeProvider = normalizeProvider(provider) || "meta";
    elements.providerTabs.forEach((button) => {
      const active = button.dataset.marketingProviderTab === state.activeProvider;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-selected", String(active));
      button.tabIndex = active ? 0 : -1;
    });
    if (elements.marketingMetaFields) elements.marketingMetaFields.hidden = state.activeProvider !== "meta";
    if (elements.marketingGoogleFields) elements.marketingGoogleFields.hidden = state.activeProvider !== "google";
    fillConnectionForm(findConnection(state.activeProvider));
    clearMessage();
  }

  function fillConnectionForm(connection) {
    const config = connection?.public_config || connection?.config || {};
    if (elements.marketingConnectionName) {
      elements.marketingConnectionName.value = connection?.name || connection?.connection_name || connection?.account_name || "";
    }
    if (elements.marketingMetaAdAccountId) {
      elements.marketingMetaAdAccountId.value = cleanMetaAccountId(config.ad_account_id || connection?.account_external_id || "");
    }
    if (elements.marketingMetaPixelId) elements.marketingMetaPixelId.value = config.pixel_id || config.dataset_id || "";
    if (elements.marketingMetaApiVersion) elements.marketingMetaApiVersion.value = connection?.api_version || config.api_version || "v26.0";
    if (elements.marketingGoogleCustomerId) {
      elements.marketingGoogleCustomerId.value = formatGoogleCustomerId(config.customer_id || config.operating_account_id || connection?.account_external_id || "");
    }
    if (elements.marketingGoogleLoginCustomerId) {
      elements.marketingGoogleLoginCustomerId.value = formatGoogleCustomerId(config.login_customer_id || config.login_account_id || "");
    }
    if (elements.marketingGoogleConversionActionId) elements.marketingGoogleConversionActionId.value = config.conversion_action_id || "";
    if (elements.marketingGoogleCallbackUrl) elements.marketingGoogleCallbackUrl.value = googleCallbackUrl();
    clearSecrets();
    const hasCredentials = Boolean(connection?.has_credentials || connection?.credentials_configured);
    const suffix = hasCredentials ? "Credenciais já protegidas. Preencha somente para substituir." : "Informe as credenciais para conectar.";
    if (elements.marketingConnectionMessage) {
      elements.marketingConnectionMessage.textContent = suffix;
      elements.marketingConnectionMessage.className = `form-message${hasCredentials ? " is-neutral" : ""}`;
    }
    if (elements.marketingConnectionDisconnect) elements.marketingConnectionDisconnect.hidden = !connection;
  }

  function clearSecrets() {
    [
      elements.marketingMetaAccessToken,
      elements.marketingGoogleDeveloperToken,
      elements.marketingGoogleClientId,
      elements.marketingGoogleClientSecret,
      elements.marketingGoogleRefreshToken,
    ].filter(Boolean).forEach((input) => { input.value = ""; });
  }

  function buildConnectionPayload() {
    const name = elements.marketingConnectionName?.value.trim() || PROVIDERS[state.activeProvider].label;
    const existing = findConnection(state.activeProvider);
    if (state.activeProvider === "meta") {
      const adAccountId = cleanMetaAccountId(elements.marketingMetaAdAccountId?.value);
      const pixelId = digitsOnly(elements.marketingMetaPixelId?.value);
      const accessToken = elements.marketingMetaAccessToken?.value.trim() || "";
      if (!adAccountId || !pixelId) throw new Error("Informe a conta de anúncios e o Pixel/Dataset da Meta.");
      if (!connectionHasCredentials(existing) && !accessToken) throw new Error("Informe o Access Token da Meta.");
      return {
        connection_id: existing?.id || null,
        store_id: state.storeId,
        provider: "meta",
        name,
        account_external_id: adAccountId,
        ad_account_id: adAccountId,
        dataset_id: pixelId,
        pixel_id: pixelId,
        api_version: elements.marketingMetaApiVersion?.value || "v26.0",
        ...(accessToken ? { access_token: accessToken } : {}),
        public_config: {
          ad_account_id: adAccountId,
          dataset_id: pixelId,
          pixel_id: pixelId,
        },
        credentials: compactObject({ access_token: accessToken }),
        tracking_allowed_origins: trackerOrigins(),
      };
    }

    const customerId = digitsOnly(elements.marketingGoogleCustomerId?.value);
    const loginCustomerId = digitsOnly(elements.marketingGoogleLoginCustomerId?.value) || customerId;
    const conversionActionId = digitsOnly(elements.marketingGoogleConversionActionId?.value);
    const credentials = compactObject({
      developer_token: elements.marketingGoogleDeveloperToken?.value.trim(),
      client_id: elements.marketingGoogleClientId?.value.trim(),
      client_secret: elements.marketingGoogleClientSecret?.value.trim(),
      refresh_token: elements.marketingGoogleRefreshToken?.value.trim(),
    });
    if (!customerId) throw new Error("Informe o Customer ID do Google Ads.");
    if (!connectionHasCredentials(existing) && !credentials.developer_token) {
      throw new Error("Informe o Developer Token do Google Ads.");
    }
    if (!connectionHasCredentials(existing) && (!credentials.client_id || !credentials.client_secret)) {
      throw new Error("Informe o Client ID e o Client Secret OAuth do Google.");
    }
    return {
      connection_id: existing?.id || null,
      store_id: state.storeId,
      provider: "google",
      name,
      account_external_id: customerId,
      customer_id: customerId,
      login_customer_id: loginCustomerId,
      conversion_action_id: conversionActionId || null,
      api_version: "v25",
      ...credentials,
      public_config: {
        customer_id: customerId,
        operating_account_id: customerId,
        login_customer_id: loginCustomerId,
        login_account_id: loginCustomerId,
        conversion_action_id: conversionActionId,
      },
      credentials,
      tracking_allowed_origins: trackerOrigins(),
    };
  }

  async function handleSaveConnection(event) {
    event.preventDefault();
    const provider = state.activeProvider;
    try {
      const payload = buildConnectionPayload();
      setConnectionBusy(true, "Protegendo e salvando...");
      const result = unwrap(await request("save-connection", payload)) || {};
      preserveTrackerCredentials(result.tracker_credentials);
      const connectionId = result.id || result.connection_id || findConnection(provider)?.id;
      const canValidateNow = provider === "meta"
        || Boolean(elements.marketingGoogleRefreshToken?.value.trim())
        || normalizeStatus(findConnection("google")?.status) === "active";
      if (canValidateNow && connectionId) {
        await request("test-connection", { store_id: state.storeId, connection_id: connectionId });
      }
      clearSecrets();
      await refresh({ silent: true });
      selectProvider(provider);
      showMessage(canValidateNow
        ? "Credenciais protegidas e conexão validada."
        : "Dados protegidos. Agora clique em “Autorizar com Google”.", "success");
    } catch (error) {
      showMessage(readableError(error), "error");
    } finally {
      setConnectionBusy(false);
    }
  }

  async function handleTestConnection() {
    const provider = state.activeProvider;
    try {
      if (provider === "google" && !elements.marketingGoogleRefreshToken?.value.trim()
        && normalizeStatus(findConnection("google")?.status) !== "active") {
        throw new Error("Salve os dados e use “Autorizar com Google” antes de testar a conexão.");
      }
      const payload = buildConnectionPayload();
      setConnectionBusy(true, "Protegendo os dados e validando com a plataforma...");
      const saved = unwrap(await request("save-connection", payload)) || {};
      preserveTrackerCredentials(saved.tracker_credentials);
      const connectionId = saved.id || saved.connection_id || findConnection(provider)?.id;
      if (!connectionId) throw new Error("Não foi possível preparar a conexão para o teste.");
      const result = unwrap(await request("test-connection", {
        store_id: state.storeId,
        connection_id: connectionId,
      })) || {};
      preserveTrackerCredentials(result.tracker_credentials || result.connection?.tracker_credentials);
      const details = result.details || {};
      const accountName = details.account_name || result.account_name || result.name || "Credenciais válidas";
      await refresh({ silent: true });
      selectProvider(provider);
      showMessage(`${accountName}. A conexão respondeu corretamente.`, "success");
    } catch (error) {
      showMessage(readableError(error), "error");
    } finally {
      setConnectionBusy(false);
    }
  }

  async function handleDisconnectConnection() {
    const connection = findConnection(state.activeProvider);
    if (!connection) return;
    const providerLabel = PROVIDERS[state.activeProvider].label;
    if (!global.confirm(`Desconectar ${providerLabel} de ${state.storeName}? Os dados já importados serão preservados.`)) return;
    try {
      setConnectionBusy(true, "Desconectando...");
      await request("disconnect-connection", {
        store_id: state.storeId,
        provider: state.activeProvider,
        connection_id: connection.id,
      });
      showMessage(`${providerLabel} desconectado. Os históricos foram preservados.`, "success");
      await refresh({ silent: true });
      fillConnectionForm(null);
    } catch (error) {
      showMessage(readableError(error), "error");
    } finally {
      setConnectionBusy(false);
    }
  }

  async function handleSyncAll() {
    if (!state.storeId) return;
    if (!connectedProviders().length) return openConnectionModal(preferredProvider());
    try {
      setButtonBusy(elements.marketingSyncButton, true, "Sincronizando...");
      const scheduled = unwrap(await request("sync-now", {
        store_id: state.storeId,
        provider: null,
        start_date: state.dateStart || null,
        end_date: state.dateEnd || null,
      })) || {};
      const jobIds = normalizeRows(scheduled, ["jobs"])
        .map((job) => String(job?.job_id || job?.queue_id || job?.id || ""))
        .filter(Boolean);
      notify("Sincronização iniciada. Os dados serão atualizados em segundo plano.");
      await refresh({ silent: true });
      startSyncPolling(jobIds);
    } catch (error) {
      notify(readableError(error), "error");
    } finally {
      setButtonBusy(elements.marketingSyncButton, false);
    }
  }

  function startSyncPolling(expectedJobIds = []) {
    stopSyncPolling();
    const generation = state.contextGeneration;
    const storeId = state.storeId;
    const expected = new Set(expectedJobIds);
    state.syncPollAttempts = 0;

    const poll = async () => {
      if (generation !== state.contextGeneration || storeId !== state.storeId) return stopSyncPolling();
      state.syncPollAttempts += 1;
      await refresh({ silent: true });
      if (generation !== state.contextGeneration || storeId !== state.storeId) return stopSyncPolling();

      const matchingRuns = [...expected].map((jobId) => (
        state.syncRuns.find((run) => String(run.queue_id || run.job_id || "") === jobId)
      ));
      const failed = matchingRuns.find((run) => (
        run && ["failed", "error", "cancelled"].includes(String(run.status || "").toLowerCase())
      ));
      if (failed) {
        stopSyncPolling();
        notify(failed.last_error_message || failed.error_message || "A sincronização falhou. Revise as credenciais e tente novamente.", "error");
        return;
      }
      const completed = expected.size > 0 && matchingRuns.length === expected.size && matchingRuns.every((run) => (
        run && ["completed", "success"].includes(String(run.status || "").toLowerCase())
      ));
      if (completed) {
        stopSyncPolling();
        notify("Sincronização concluída. As métricas já estão atualizadas.");
        return;
      }
      if (state.syncPollAttempts >= 36) {
        stopSyncPolling();
        notify("A sincronização continua em segundo plano. O painel será atualizado na próxima consulta.");
        return;
      }
      state.syncPollTimer = global.setTimeout(poll, 5000);
    };

    state.syncPollTimer = global.setTimeout(poll, 2500);
  }

  function stopSyncPolling() {
    if (state.syncPollTimer) global.clearTimeout(state.syncPollTimer);
    state.syncPollTimer = null;
    state.syncPollAttempts = 0;
  }

  async function handleGoogleOAuth() {
    if (state.activeProvider !== "google") return;
    try {
      const payload = buildConnectionPayload();
      setConnectionBusy(true, "Preparando autorização segura...");
      const saved = unwrap(await request("save-connection", payload)) || {};
      preserveTrackerCredentials(saved.tracker_credentials);
      const connectionId = saved.id || saved.connection_id || findConnection("google")?.id;
      if (!connectionId) throw new Error("Não foi possível preparar a conexão Google.");
      const result = unwrap(await request("start-google-oauth", {
        store_id: state.storeId,
        connection_id: connectionId,
        redirect_after: global.location.href.split("#")[0],
      })) || {};
      if (!result.authorization_url) throw new Error("O Google não devolveu a URL de autorização.");
      global.location.assign(result.authorization_url);
    } catch (error) {
      showMessage(readableError(error), "error");
      setConnectionBusy(false);
    }
  }

  async function copyGoogleCallbackUrl() {
    const value = elements.marketingGoogleCallbackUrl?.value || googleCallbackUrl();
    if (!value) return notify("A URL do Supabase ainda não está disponível.", "error");
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      elements.marketingGoogleCallbackUrl?.select();
      document.execCommand("copy");
    }
    notify("URL de redirecionamento copiada.");
  }

  function googleCallbackUrl() {
    return state.supabaseUrl ? `${state.supabaseUrl}/functions/v1/marketing-api?oauth=google` : "";
  }

  async function loadTrackerConfig() {
    if (!state.storeId) return;
    const generation = state.contextGeneration;
    const previous = state.tracker || {};
    const result = unwrap(await request("get-tracker-config", { store_id: state.storeId })) || {};
    if (generation !== state.contextGeneration) return;
    const source = Array.isArray(result.sources) ? result.sources[0] : null;
    const sameSource = !previous.source_id || !source?.id || previous.source_id === source.id;
    state.tracker = {
      ...result,
      ...(sameSource && previous.tracking_token ? { tracking_token: previous.tracking_token } : {}),
      ...(source || {}),
      source_id: source?.id || previous.source_id || null,
    };
    renderTracker();
  }

  function renderTracker() {
    if (!elements.marketingTrackerSnippet) return;
    const tracker = state.tracker || {};
    const source = Array.isArray(tracker.sources) ? tracker.sources[0] : null;
    const hasSource = Boolean(source || tracker.source_id);
    const token = tracker.tracking_token || tracker.public_token || "";
    const snippet = token ? buildTrackerSnippet({ ...tracker, tracking_token: token }) : "Gere um código para este domínio. O token completo é exibido somente no momento da criação ou troca.";
    elements.marketingTrackerSnippet.value = snippet;
    if (elements.marketingTrackerCopy) elements.marketingTrackerCopy.disabled = !token;
    if (elements.marketingTrackerRotate) {
      elements.marketingTrackerRotate.innerHTML = hasSource
        ? '<i class="fa-solid fa-key" aria-hidden="true"></i>Gerar novo código'
        : '<i class="fa-solid fa-plus" aria-hidden="true"></i>Criar código';
    }
    if (elements.marketingTrackerOrigin) elements.marketingTrackerOrigin.value = source?.allowed_origins?.[0] || tracker.allowed_origins?.[0] || "";
    if (elements.marketingTrackerStatus) {
      elements.marketingTrackerStatus.textContent = source?.is_active === false || tracker.active === false
        ? "Rastreador desativado"
        : source?.last_used_at || tracker.last_event_at
        ? `Último acesso ${formatDateTime(source?.last_used_at || tracker.last_event_at)}`
        : token
        ? "Código pronto para instalar no site ou GTM"
        : hasSource
        ? "Código já protegido · gere outro somente para reinstalar"
        : "Informe o domínio para gerar o código";
    }
  }

  function buildTrackerSnippet(config) {
    const token = String(config.tracking_token || config.public_token || "");
    const endpoint = String(config.endpoint || `${state.supabaseUrl}/functions/v1/marketing-api`);
    return `<script>\n(function(){\n  var sent=false,retries=0;\n  var uuid=function(){return self.crypto&&crypto.randomUUID?crypto.randomUUID():String(Date.now())+'-'+Math.random().toString(16).slice(2)};\n  var eventKey='page:'+uuid();\n  var hasConsent=function(){var ok=window.LC_MARKETING_CONSENT===true;try{ok=ok||localStorage.getItem('lc_marketing_consent')==='granted'}catch(e){}return ok};\n  var cookie=function(n){var m=document.cookie.match(new RegExp('(?:^|; )'+n.replace(/([.$?*|{}()\\[\\]\\\\\\/+^])/g,'\\\\$1')+'=([^;]*)'));return m?decodeURIComponent(m[1]):null};\n  var send=function(){\n    if(sent||!hasConsent())return;\n    sent=true;\n    var p=new URLSearchParams(location.search),now=Date.now(),aid,sid;\n    try{aid=localStorage.getItem('lc_marketing_anonymous_id')||uuid();localStorage.setItem('lc_marketing_anonymous_id',aid);sid=sessionStorage.getItem('lc_marketing_session_id')||uuid();sessionStorage.setItem('lc_marketing_session_id',sid)}catch(e){aid=uuid();sid=uuid()}\n    var fbclid=p.get('fbclid'),payload={event_name:'page_view',occurred_at:new Date().toISOString(),idempotency_key:eventKey,anonymous_id:aid,session_id:sid,landing_page_url:location.href,referrer_url:document.referrer||null,utm_source:p.get('utm_source'),utm_medium:p.get('utm_medium'),utm_campaign:p.get('utm_campaign'),utm_content:p.get('utm_content'),utm_term:p.get('utm_term'),gclid:p.get('gclid'),gbraid:p.get('gbraid'),wbraid:p.get('wbraid'),fbclid:fbclid,fbc:cookie('_fbc')||(fbclid?'fb.1.'+now+'.'+fbclid:null),fbp:cookie('_fbp'),marketing_consent:true,consent_at:new Date().toISOString(),consent_version:'site-v1',consent_source:'site'};\n    fetch('${escapeJs(endpoint)}',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'capture-touchpoint',tracking_token:'${escapeJs(token)}',payload:payload}),keepalive:true}).then(function(r){if(!r.ok)throw new Error('tracker_http_'+r.status);return r.json()}).then(function(x){var id=x&&x.data&&x.data.touchpoint_id;if(id)try{sessionStorage.setItem('lc_touchpoint_id',id)}catch(e){}}).catch(function(){sent=false;if(retries<3){retries+=1;setTimeout(send,retries*2000)}});\n  };\n  window.addEventListener('lc:marketing-consent-granted',send);\n  window.addEventListener('storage',function(e){if(e.key==='lc_marketing_consent'&&e.newValue==='granted')send()});\n  window.LCMarketingTrackerCapture=send;\n  send();\n})();\n<\/script>`;
  }

  async function copyTrackerSnippet() {
    const value = elements.marketingTrackerSnippet?.value || "";
    if (!value) return;
    try {
      await navigator.clipboard.writeText(value);
      notify("Código de rastreamento copiado.");
    } catch {
      elements.marketingTrackerSnippet.select();
      document.execCommand("copy");
      notify("Código de rastreamento copiado.");
    }
  }

  async function rotateTrackerToken() {
    let origins;
    try {
      origins = trackerOrigins(true);
    } catch (error) {
      return notify(readableError(error), "error");
    }
    const source = Array.isArray(state.tracker?.sources) ? state.tracker.sources[0] : null;
    const sourceId = source?.id || state.tracker?.source_id || null;
    if (sourceId && !global.confirm("Gerar um novo código? O código anterior deixará de funcionar até ser substituído no site.")) return;
    try {
      setButtonBusy(elements.marketingTrackerRotate, true, "Gerando...");
      const result = unwrap(await request("rotate-tracker-token", {
        store_id: state.storeId,
        source_id: sourceId,
        name: "Site principal",
        allowed_origins: origins,
      })) || null;
      state.tracker = {
        ...(state.tracker || {}),
        ...(result || {}),
        source_id: result?.source_id || source?.id || null,
        allowed_origins: origins,
      };
      renderTracker();
      notify(sourceId ? "Novo código criado. Substitua o anterior no site." : "Código criado e pronto para instalar.");
    } catch (error) {
      notify(readableError(error), "error");
    } finally {
      setButtonBusy(elements.marketingTrackerRotate, false);
      renderTracker();
    }
  }

  function setConnectionBusy(isBusy, message = "") {
    const form = elements.marketingConnectionForm;
    if (form) {
      form.setAttribute("aria-busy", String(isBusy));
      Array.from(form.querySelectorAll("button, input, select")).forEach((control) => {
        if (control === elements.marketingConnectionClose) return;
        control.disabled = isBusy;
      });
    }
    elements.providerTabs.forEach((button) => { button.disabled = isBusy; });
    elements.providerButtons.forEach((button) => { button.disabled = isBusy; });
    if (message) showMessage(message, "neutral");
  }

  function setButtonBusy(button, isBusy, busyLabel = "Processando...") {
    if (!button) return;
    if (isBusy) {
      button.dataset.originalHtml = button.innerHTML;
      button.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin" aria-hidden="true"></i>${escapeHtml(busyLabel)}`;
      button.disabled = true;
    } else {
      button.innerHTML = button.dataset.originalHtml || button.innerHTML;
      button.disabled = false;
      delete button.dataset.originalHtml;
    }
  }

  function showMessage(message, type = "neutral") {
    if (!elements.marketingConnectionMessage) return;
    elements.marketingConnectionMessage.textContent = message;
    elements.marketingConnectionMessage.className = `form-message is-${type}`;
  }

  function clearMessage() {
    if (!elements.marketingConnectionMessage) return;
    elements.marketingConnectionMessage.textContent = "";
    elements.marketingConnectionMessage.className = "form-message";
  }

  function notify(message, type = "success") {
    if (typeof state.notify === "function") state.notify(message, type === "error" ? "error" : undefined);
  }

  function findConnection(provider) {
    return state.connections.find((item) => normalizeProvider(item.provider) === provider) || null;
  }

  function connectedProviders() {
    return state.connections.filter((item) => ["active", "token_expiring"].includes(String(item.status || "").toLowerCase()));
  }

  function connectionHasCredentials(connection) {
    return Boolean(connection?.has_credentials || connection?.credentials_configured);
  }

  function trackerOrigins(required = false) {
    const raw = elements.marketingTrackerOrigin?.value.trim() || "";
    if (!raw) {
      if (required) throw new Error("Informe o domínio do site onde o rastreador será instalado.");
      return [];
    }
    let url;
    try {
      url = new URL(raw);
    } catch {
      throw new Error("Informe um domínio completo, por exemplo https://www.site.com.br.");
    }
    if (!["https:", "http:"].includes(url.protocol)) throw new Error("O domínio do rastreador deve usar HTTPS.");
    return [url.origin];
  }

  function preserveTrackerCredentials(credentials) {
    if (!credentials || typeof credentials !== "object") return;
    state.tracker = { ...(state.tracker || {}), ...credentials };
    renderTracker();
  }

  function forgetTrackerToken() {
    if (!state.tracker) return;
    const { tracking_token: _trackingToken, public_token: _publicToken, ...safeTracker } = state.tracker;
    state.tracker = safeTracker;
  }

  function clearTrackerUi() {
    if (elements.marketingTrackerSnippet) elements.marketingTrackerSnippet.value = "";
    if (elements.marketingTrackerOrigin) elements.marketingTrackerOrigin.value = "";
    if (elements.marketingTrackerCopy) elements.marketingTrackerCopy.disabled = true;
    if (elements.marketingTrackerStatus) elements.marketingTrackerStatus.textContent = "Carregando configuração do rastreador...";
  }

  function handleOAuthReturn() {
    const url = new URL(global.location.href);
    const status = url.searchParams.get("marketing_oauth");
    if (!status) return;
    const provider = url.searchParams.get("provider") || "google";
    const errorCode = url.searchParams.get("error_code") || "";
    ["marketing_oauth", "provider", "connection_id", "error_code"].forEach((key) => url.searchParams.delete(key));
    global.history.replaceState({}, document.title, `${url.pathname}${url.search}${url.hash}`);
    state.pendingOAuthNotice = status === "success"
      ? { message: `${PROVIDERS[provider]?.label || "Google Ads"} autorizado com sucesso.`, type: "success" }
      : { message: `Não foi possível autorizar o Google Ads${errorCode ? ` (${errorCode})` : ""}.`, type: "error" };
    flushOAuthNotice();
  }

  function flushOAuthNotice() {
    if (!state.pendingOAuthNotice || !state.profile || !state.storeId || typeof state.notify !== "function") return;
    const notice = state.pendingOAuthNotice;
    state.pendingOAuthNotice = null;
    global.setTimeout(() => notify(notice.message, notice.type), 0);
  }

  function trapModalFocus(event) {
    const focusable = Array.from(elements.marketingConnectionModal.querySelectorAll(
      'button:not([disabled]):not([hidden]), input:not([disabled]):not([hidden]), select:not([disabled]):not([hidden]), textarea:not([disabled]):not([hidden]), [tabindex]:not([tabindex="-1"])',
    )).filter((item) => item.offsetParent !== null);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function normalizeProvider(value) {
    const provider = String(value || "").toLowerCase();
    if (provider.includes("facebook") || provider.includes("instagram")) return "meta";
    if (provider.includes("google")) return "google";
    return PROVIDERS[provider] ? provider : "";
  }

  function normalizeStatus(value) {
    const status = String(value || "disconnected").toLowerCase();
    if (["active", "connected", "success", "completed", "sent"].includes(status)) return "active";
    if (["token_expiring", "expiring"].includes(status)) return "warning";
    if (["error", "failed", "expired"].includes(status)) return "error";
    if (["pending", "processing", "running", "queued"].includes(status)) return "pending";
    return "disconnected";
  }

  function statusLabel(status) {
    if (status === "active") return "Conectado";
    if (status === "error") return "Atenção";
    if (status === "pending") return "Processando";
    if (status === "warning") return "Token expirando";
    return "Desconectado";
  }

  function syncRunStatus(value) {
    const status = String(value || "queued").toLowerCase();
    if (["completed", "success", "sent"].includes(status)) return { className: "active", label: "Concluído" };
    if (["failed", "error", "expired", "cancelled"].includes(status)) return { className: "error", label: status === "cancelled" ? "Cancelado" : "Falhou" };
    if (["running", "processing"].includes(status)) return { className: "pending", label: "Em andamento" };
    if (["queued", "pending", "submitted"].includes(status)) return { className: "pending", label: "Na fila" };
    return { className: "disconnected", label: "Aguardando" };
  }

  function syncTypeLabel(value) {
    const type = String(value || "dados").replace(/[_-]+/g, " ");
    return type.charAt(0).toUpperCase() + type.slice(1);
  }

  function numberFrom(object, keys) {
    return numberOrNull(object, keys) ?? 0;
  }

  function numberOrNull(object, keys) {
    for (const key of keys) {
      const raw = object?.[key];
      if (raw !== null && raw !== undefined && raw !== "" && Number.isFinite(Number(raw))) return Number(raw);
    }
    return null;
  }

  function compactObject(value) {
    return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined && item !== null && item !== ""));
  }

  function digitsOnly(value) {
    return String(value || "").replace(/\D/g, "");
  }

  function cleanMetaAccountId(value) {
    return digitsOnly(String(value || "").replace(/^act_/i, ""));
  }

  function formatGoogleCustomerId(value) {
    const digits = digitsOnly(value).slice(0, 10);
    return digits.length > 6 ? `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}` : digits;
  }

  function formatCurrency(value) {
    return new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(Number(value || 0));
  }

  function formatCompact(value) {
    return new Intl.NumberFormat("pt-BR", { notation: Number(value) >= 10000 ? "compact" : "standard", maximumFractionDigits: 1 }).format(Number(value || 0));
  }

  function formatDecimal(value) {
    return new Intl.NumberFormat("pt-BR", { minimumFractionDigits: 0, maximumFractionDigits: 2 }).format(Number(value || 0));
  }

  function formatDateTime(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "—";
    return new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }).format(date);
  }

  function formatShortDate(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "—";
    return new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "short" }).format(date);
  }

  function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, Number(value || 0)));
  }

  function normalizeDateRange(startValue, endValue, maximumDays) {
    const start = String(startValue || "");
    const end = String(endValue || "");
    const startDate = parseIsoDate(start);
    const endDate = parseIsoDate(end);
    if (!startDate || !endDate || startDate > endDate) return { start, end };
    const dayMs = 86400000;
    const span = Math.round((endDate.getTime() - startDate.getTime()) / dayMs);
    if (span <= maximumDays) return { start, end };
    const minimum = new Date(endDate.getTime() - (maximumDays * dayMs));
    return { start: minimum.toISOString().slice(0, 10), end };
  }

  function parseIsoDate(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))) return null;
    const date = new Date(`${value}T00:00:00Z`);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function readableError(error) {
    if (error?.error?.message) return error.error.message;
    if (error?.message) return error.message;
    return "Não foi possível concluir a operação.";
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function escapeJs(value) {
    return String(value || "").replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\r?\n/g, "");
  }

  global.MarketingAttributionModule = Object.freeze({
    initialize,
    setContext,
    refresh,
    openConnectionModal,
    closeConnectionModal,
  });
})(window);
