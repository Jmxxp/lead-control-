(function registerAttendancesModule(global) {
  "use strict";

  const DEFAULT_RPC = Object.freeze({
    workspace: "lc_get_attendance_workspace",
    save: "lc_upsert_attendance",
  });

  const TAGS = Object.freeze({
    budget: { label: "Orçamento", icon: "fa-file-invoice-dollar", tone: "blue" },
    purchase: { label: "Compra", icon: "fa-bag-shopping", tone: "green" },
    other: { label: "Outro", icon: "fa-ellipsis", tone: "slate" },
  });

  const state = {
    root: null,
    bridge: {},
    active: false,
    loading: false,
    saving: false,
    generation: 0,
    contextGeneration: 0,
    pendingSave: null,
    selectedStoreId: "",
    stores: [],
    records: [],
    professionals: [],
    serverMetrics: {},
    feedback: null,
    loadError: "",
    idempotencyKey: "",
    idempotencyFingerprint: "",
    drafts: new Map(),
    filters: {
      search: "",
      tag: "all",
      professional: "all",
      period: "30d",
    },
  };

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
      professionalName: String(firstDefined(source.professional_name, source.professionalName, source.performed_by, source.performedBy, "Não informado")),
      customerName: String(firstDefined(source.customer_name, source.customerName, source.client_name, source.clientName, source.name, "Cliente não informado")),
      phone: formatPhone(firstDefined(source.phone, source.customer_phone, source.customerPhone, source.telephone, "")),
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
        ? professionals.map(normalizeProfessional).filter((item) => item.name && item.active)
        : [],
      metrics: payload.metrics && typeof payload.metrics === "object" ? payload.metrics : {},
    };
  }

  function normalizeStore(store = {}) {
    return {
      ...store,
      id: String(firstDefined(store.id, store.store_id, store.storeId, "")),
      name: String(firstDefined(store.name, store.store_name, store.storeName, store.username, "Cliente")),
      technicianId: String(firstDefined(store.technicianId, store.technician_id, store.agencyId, store.agency_id, "")),
      avatarUrl: safeImageUrl(firstDefined(store.avatarUrl, store.avatar_url, store.logoUrl, store.logo_url, "")),
    };
  }

  function visibleStores() {
    const profile = state.bridge?.profile || {};
    const all = (Array.isArray(state.bridge?.stores) ? state.bridge.stores : []).map(normalizeStore).filter((store) => store.id);
    if (isStoreRole()) {
      const ownId = String(firstDefined(profile.storeId, profile.store_id, profile.id, ""));
      const own = all.filter((store) => store.id === ownId);
      if (own.length) return own;
      return ownId ? [normalizeStore({ id: ownId, name: profile.name || profile.username || "Minha empresa", avatarUrl: profile.avatarUrl })] : [];
    }
    if (isAgencyRole()) {
      const agencyId = String(firstDefined(profile.id, profile.technicianId, profile.technician_id, ""));
      return agencyId ? all.filter((store) => store.technicianId === agencyId) : [];
    }
    const initialAgencyId = String(state.bridge?.initialAgencyId || "");
    if (initialAgencyId) return all.filter((store) => store.technicianId === initialAgencyId);
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
      return `<span class="${className}"><img src="${escapeHtml(store.avatarUrl)}" alt="Logo de ${escapeHtml(store.name)}" /></span>`;
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

    return `<header class="attendance-module-header">
      <div class="attendance-heading">
        ${renderAvatar(store || { name: "Atendimentos", avatarUrl: safeImageUrl(state.bridge?.profile?.avatarUrl) }, "attendance-heading-avatar")}
        <div>
          <p class="attendance-eyebrow">Operação comercial</p>
          <h1>${store ? escapeHtml(store.name) : "Atendimentos"}</h1>
          <p>${store ? "Registre o atendimento e preserve a origem comercial do cliente." : "Selecione uma empresa para trabalhar com dados totalmente isolados."}</p>
        </div>
      </div>
      <div class="attendance-header-actions">
        ${selector}
        <button class="attendance-icon-button" type="button" data-attendance-action="refresh" aria-label="Atualizar atendimentos" title="Atualizar">
          <i class="fa-solid fa-arrow-rotate-right" aria-hidden="true"></i>
        </button>
      </div>
    </header>`;
  }

  function renderNoStore() {
    const hasStores = state.stores.length > 0;
    return `<section class="attendance-context-empty" aria-live="polite">
      <span class="attendance-context-empty-icon"><i class="fa-solid ${hasStores ? "fa-arrow-pointer" : "fa-building-circle-exclamation"}" aria-hidden="true"></i></span>
      <p class="attendance-eyebrow">Dados protegidos por cliente</p>
      <h2>${hasStores ? "Escolha uma empresa para começar" : "Nenhum cliente disponível"}</h2>
      <p>${hasStores
        ? "O painel só carrega um cliente por vez. Assim, atendimentos, profissionais e valores nunca são misturados entre empresas."
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

  function professionalOptions() {
    const unique = new Map();
    state.professionals.forEach((professional) => unique.set(normalizeText(professional.name), professional.name));
    state.records.forEach((record) => {
      if (record.professionalName && record.professionalName !== "Não informado") unique.set(normalizeText(record.professionalName), record.professionalName);
    });
    return [...unique.values()].sort((a, b) => a.localeCompare(b, "pt-BR"));
  }

  function captureDraft() {
    const form = state.root?.querySelector("[data-attendance-form]");
    if (!form || !state.selectedStoreId) return;
    state.drafts.set(state.selectedStoreId, {
      professionalName: String(form.elements.professional_name?.value || ""),
      customerName: String(form.elements.customer_name?.value || ""),
      phone: String(form.elements.phone?.value || ""),
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
    const professionals = professionalOptions();
    const draft = state.drafts.get(state.selectedStoreId) || { tag: "budget" };
    return `<article class="attendance-panel attendance-form-panel">
      <header class="attendance-panel-header">
        <div><p class="attendance-eyebrow">Novo registro</p><h2>Registrar atendimento</h2><span>O sistema procura o telefone em Leads e Prospecções ao salvar.</span></div>
        <span class="attendance-header-badge"><i class="fa-solid fa-wand-magic-sparkles" aria-hidden="true"></i>Vínculo automático</span>
      </header>
      <form class="attendance-form" data-attendance-form novalidate aria-busy="${state.saving ? "true" : "false"}">
        <div class="attendance-form-grid">
          <label class="attendance-field attendance-field--wide">
            <span>Atendimento realizado por <b>*</b></span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-user-tie" aria-hidden="true"></i><input name="professional_name" list="attendanceProfessionalList" autocomplete="off" placeholder="Selecione ou informe o profissional" value="${escapeHtml(draft.professionalName || "")}" required /></span>
            <datalist id="attendanceProfessionalList">${professionals.map((name) => `<option value="${escapeHtml(name)}"></option>`).join("")}</datalist>
          </label>
          <label class="attendance-field">
            <span>Cliente <b>*</b></span>
            <span class="attendance-input-wrap"><i class="fa-solid fa-user" aria-hidden="true"></i><input name="customer_name" autocomplete="name" placeholder="Nome do cliente" value="${escapeHtml(draft.customerName || "")}" required /></span>
          </label>
          <label class="attendance-field">
            <span>Telefone <b>*</b></span>
            <span class="attendance-input-wrap"><i class="fa-brands fa-whatsapp" aria-hidden="true"></i><input name="phone" inputmode="tel" autocomplete="tel" placeholder="(00) 00000-0000" value="${escapeHtml(draft.phone || "")}" required /></span>
            <small>Usado para encontrar Lead e Prospecção.</small>
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
        <button class="attendance-primary-button" type="submit" data-attendance-save ${state.saving ? "disabled" : ""}>
          <span class="attendance-button-idle"><i class="fa-solid fa-check" aria-hidden="true"></i>Salvar atendimento</span>
          <span class="attendance-button-loading"><span class="attendance-mini-spinner" aria-hidden="true"></span>Salvando com segurança</span>
        </button>
      </form>
      ${renderFeedback()}
    </article>`;
  }

  function periodRecords() {
    const now = new Date();
    const period = state.filters.period;
    if (period === "all") return state.records.slice();
    let start = new Date(now);
    if (period === "today") start.setHours(0, 0, 0, 0);
    else start.setDate(start.getDate() - (period === "7d" ? 7 : 30));
    return state.records.filter((record) => {
      if (!record.createdAt) return false;
      const date = new Date(record.createdAt);
      return !Number.isNaN(date.getTime()) && date >= start && date <= now;
    });
  }

  function metricData() {
    const periodAliases = {
      today: ["today", "day", "hoje"],
      "7d": ["7d", "week", "last_7_days", "last7days", "semana"],
      "30d": ["30d", "month", "last_30_days", "last30days", "mes"],
      all: ["all", "total", "overall", "todo_periodo"],
    };
    const metricContainers = [state.serverMetrics?.periods, state.serverMetrics?.by_period, state.serverMetrics?.byPeriod, state.serverMetrics];
    let serverPeriod = null;
    for (const container of metricContainers) {
      if (!container || typeof container !== "object") continue;
      const alias = periodAliases[state.filters.period].find((key) => container[key] && typeof container[key] === "object");
      if (alias) {
        serverPeriod = container[alias];
        break;
      }
    }
    if (serverPeriod) {
      const total = Number(firstDefined(serverPeriod.total, serverPeriod.attendances, serverPeriod.attendance_count, serverPeriod.attendanceCount, 0)) || 0;
      const purchases = Number(firstDefined(serverPeriod.purchases, serverPeriod.purchase_count, serverPeriod.purchaseCount, 0)) || 0;
      const budgets = Number(firstDefined(serverPeriod.budgets, serverPeriod.budget_count, serverPeriod.budgetCount, 0)) || 0;
      return {
        total,
        budgets,
        purchases,
        conversion: Number(firstDefined(serverPeriod.conversion, serverPeriod.conversion_rate, serverPeriod.conversionRate, total ? Math.round((purchases / total) * 100) : 0)) || 0,
        revenue: Number(firstDefined(serverPeriod.revenue, serverPeriod.purchase_revenue, serverPeriod.purchaseRevenue, serverPeriod.sales_value, 0)) || 0,
        serviceValue: Number(firstDefined(serverPeriod.service_value, serverPeriod.serviceValue, serverPeriod.attendance_value, serverPeriod.attendanceValue, 0)) || 0,
      };
    }

    const records = periodRecords();
    const purchases = records.filter((record) => record.tag === "purchase");
    const budgets = records.filter((record) => record.tag === "budget");
    const revenue = purchases.reduce((total, record) => total + Number(record.purchaseValue || 0), 0);
    const serviceValue = records.reduce((total, record) => total + Number(record.serviceValue || 0), 0);
    return {
      total: records.length,
      budgets: budgets.length,
      purchases: purchases.length,
      conversion: records.length ? Math.round((purchases.length / records.length) * 100) : 0,
      revenue,
      serviceValue,
    };
  }

  function renderMetrics() {
    const metrics = metricData();
    const cards = [
      { label: "Atendimentos", value: metrics.total, icon: "fa-clipboard-check", tone: "blue" },
      { label: "Orçamentos", value: metrics.budgets, icon: "fa-file-invoice-dollar", tone: "violet" },
      { label: "Compras", value: metrics.purchases, icon: "fa-bag-shopping", tone: "green" },
      { label: "Conversão", value: `${metrics.conversion}%`, icon: "fa-arrow-trend-up", tone: "cyan" },
      { label: "Faturamento informado", value: formatCurrency(metrics.revenue), icon: "fa-chart-line", tone: "green" },
      { label: "Valor dos atendimentos", value: formatCurrency(metrics.serviceValue), icon: "fa-wallet", tone: "slate" },
    ];
    return `<section class="attendance-metrics" data-attendance-metrics>
      ${cards.map((card) => `<article class="attendance-metric attendance-metric--${card.tone}"><span><i class="fa-solid ${card.icon}" aria-hidden="true"></i></span><div><small>${card.label}</small><strong>${escapeHtml(card.value)}</strong></div></article>`).join("")}
    </section>`;
  }

  function filteredRecords() {
    const query = normalizeText(state.filters.search);
    return periodRecords().filter((record) => {
      if (state.filters.tag !== "all" && record.tag !== state.filters.tag) return false;
      if (state.filters.professional !== "all" && normalizeText(record.professionalName) !== normalizeText(state.filters.professional)) return false;
      if (!query) return true;
      return normalizeText([
        record.customerName,
        record.phone,
        record.professionalName,
        record.description,
        record.serviceOrder,
        TAGS[record.tag]?.label,
      ].join(" ")).includes(query);
    }).sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));
  }

  function renderRecordOrigins(record) {
    const origins = [];
    if (record.linkedLead?.linked) origins.push(`<span class="attendance-link-badge attendance-link-badge--lead"><i class="fa-solid fa-user-group" aria-hidden="true"></i>Lead</span>`);
    if (record.linkedProspection?.linked) origins.push(`<span class="attendance-link-badge attendance-link-badge--prospection"><i class="fa-solid fa-phone" aria-hidden="true"></i>Prospecção</span>`);
    if (record.ambiguous) origins.push(`<span class="attendance-link-badge attendance-link-badge--review"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>Revisar vínculo</span>`);
    if (!origins.length) origins.push(`<span class="attendance-link-badge attendance-link-badge--standalone"><i class="fa-solid fa-circle-dot" aria-hidden="true"></i>Avulso</span>`);
    return origins.join("");
  }

  function renderRecord(record) {
    const tag = TAGS[record.tag] || TAGS.other;
    const bonusApplies = record.tag === "purchase" && record.linkedProspection?.linked;
    const bonus = bonusApplies && record.bonusEligible === true
      ? `<span class="attendance-record-bonus is-positive"><i class="fa-solid fa-award" aria-hidden="true"></i>Bônus elegível${record.bonusAmount != null ? ` · ${escapeHtml(formatCurrency(record.bonusAmount))}` : ""}</span>`
      : bonusApplies && record.bonusEligible === false
        ? `<span class="attendance-record-bonus is-negative"><i class="fa-solid fa-circle-minus" aria-hidden="true"></i>Não elegível</span>`
        : "";
    return `<article class="attendance-record">
      <div class="attendance-record-accent attendance-record-accent--${tag.tone}" aria-hidden="true"></div>
      <header>
        <div class="attendance-record-person"><span>${escapeHtml(initials(record.customerName))}</span><div><strong>${escapeHtml(record.customerName)}</strong><small>${escapeHtml(record.phone || "Telefone não informado")}</small></div></div>
        <span class="attendance-record-tag attendance-record-tag--${tag.tone}"><i class="fa-solid ${tag.icon}" aria-hidden="true"></i>${tag.label}</span>
      </header>
      ${record.description ? `<p class="attendance-record-description">${escapeHtml(record.description)}</p>` : ""}
      <div class="attendance-record-meta">
        <span><i class="fa-solid fa-user-tie" aria-hidden="true"></i>Realizado por <b>${escapeHtml(record.professionalName)}</b></span>
        <span><i class="fa-regular fa-clock" aria-hidden="true"></i>${escapeHtml(formatDateTime(record.createdAt))}</span>
        ${record.serviceOrder ? `<span><i class="fa-solid fa-receipt" aria-hidden="true"></i>OS ${escapeHtml(record.serviceOrder)}</span>` : ""}
      </div>
      <footer>
        <div class="attendance-record-links">${renderRecordOrigins(record)}${record.prospectionProfessionalName ? `<span class="attendance-credit-badge"><i class="fa-solid fa-medal" aria-hidden="true"></i>Crédito: ${escapeHtml(record.prospectionProfessionalName)}</span>` : ""}${bonus}</div>
        <div class="attendance-record-values">${record.serviceValue ? `<span><small>Atendimento</small><b>${escapeHtml(formatCurrency(record.serviceValue))}</b></span>` : ""}${record.tag === "purchase" ? `<span><small>Compra</small><b>${escapeHtml(formatCurrency(record.purchaseValue))}</b></span>` : ""}</div>
      </footer>
    </article>`;
  }

  function renderRecordListContent() {
    const records = filteredRecords();
    if (!records.length) {
      return `<div class="attendance-list-empty"><span><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i></span><strong>Nenhum atendimento encontrado</strong><p>Ajuste os filtros ou registre o primeiro atendimento deste cliente.</p></div>`;
    }
    return records.map(renderRecord).join("");
  }

  function renderOverview() {
    const professionals = professionalOptions();
    return `<section class="attendance-overview">
      <div class="attendance-overview-heading"><div><p class="attendance-eyebrow">Visão da operação</p><h2>Resumo do cliente</h2><span>Métricas e registros sempre limitados à empresa selecionada.</span></div><span class="attendance-scope-badge"><i class="fa-solid fa-shield-halved" aria-hidden="true"></i>Sem mistura de contas</span></div>
      ${renderMetrics()}
      <article class="attendance-panel attendance-list-panel">
        <header class="attendance-list-header">
          <div><h2>Atendimentos recentes</h2><span data-attendance-result-count>${filteredRecords().length} registro${filteredRecords().length === 1 ? "" : "s"} no filtro</span></div>
          <div class="attendance-list-tools">
            <label class="attendance-search"><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i><input type="search" data-attendance-filter="search" value="${escapeHtml(state.filters.search)}" placeholder="Buscar cliente, telefone ou OS" aria-label="Buscar atendimentos" /></label>
            <select data-attendance-filter="tag" aria-label="Filtrar por classificação">
              <option value="all" ${state.filters.tag === "all" ? "selected" : ""}>Todas as etiquetas</option>
              ${Object.entries(TAGS).map(([value, tag]) => `<option value="${value}" ${state.filters.tag === value ? "selected" : ""}>${tag.label}</option>`).join("")}
            </select>
            <select data-attendance-filter="professional" aria-label="Filtrar por profissional">
              <option value="all">Todos os profissionais</option>
              ${professionals.map((name) => `<option value="${escapeHtml(name)}" ${state.filters.professional === name ? "selected" : ""}>${escapeHtml(name)}</option>`).join("")}
            </select>
            <select data-attendance-filter="period" aria-label="Filtrar por período">
              <option value="today" ${state.filters.period === "today" ? "selected" : ""}>Hoje</option>
              <option value="7d" ${state.filters.period === "7d" ? "selected" : ""}>Últimos 7 dias</option>
              <option value="30d" ${state.filters.period === "30d" ? "selected" : ""}>Últimos 30 dias</option>
              <option value="all" ${state.filters.period === "all" ? "selected" : ""}>Todo o período</option>
            </select>
          </div>
        </header>
        <div class="attendance-record-list" data-attendance-record-list>${renderRecordListContent()}</div>
      </article>
    </section>`;
  }

  function renderWorkspace() {
    if (!state.root) return;
    state.root.innerHTML = `<div class="attendance-shell">${renderStoreHeader()}<main class="attendance-module-main">
      ${!state.selectedStoreId ? renderNoStore() : state.loading ? renderLoading() : state.loadError ? renderLoadError() : `<div class="attendance-layout">${renderForm()}${renderOverview()}</div>`}
    </main></div>`;
    syncPurchaseFields();
  }

  function renderFilteredRegions() {
    if (!state.root || state.loading || state.loadError || !state.selectedStoreId) return;
    const list = state.root.querySelector("[data-attendance-record-list]");
    const count = state.root.querySelector("[data-attendance-result-count]");
    const metrics = state.root.querySelector("[data-attendance-metrics]");
    if (list) list.innerHTML = renderRecordListContent();
    if (count) {
      const total = filteredRecords().length;
      count.textContent = `${total} registro${total === 1 ? "" : "s"} no filtro`;
    }
    if (metrics) metrics.outerHTML = renderMetrics();
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
    if (button) button.disabled = Boolean(busy);
  }

  function createIdempotencyKey() {
    if (global.crypto?.randomUUID) return global.crypto.randomUUID();
    return `attendance-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }

  function validateForm(form) {
    const values = Object.fromEntries(new FormData(form).entries());
    const professionalName = String(values.professional_name || "").trim();
    const customerName = String(values.customer_name || "").trim();
    const phone = onlyDigits(values.phone).replace(/^55(?=\d{10,11}$)/, "");
    const description = String(values.description || "").trim();
    const tag = normalizeTag(values.tag);
    const serviceValue = normalizeMoney(values.service_value);
    const purchaseValue = normalizeMoney(values.purchase_value);
    const serviceOrder = String(values.service_order || "").trim();

    if (!professionalName) throw new Error("Informe quem realizou o atendimento.");
    if (!customerName) throw new Error("Informe o nome do cliente.");
    if (![10, 11].includes(phone.length)) throw new Error("Informe um telefone válido com DDD.");
    if (!description) throw new Error("Descreva o atendimento realizado.");
    if (serviceValue < 0) throw new Error("O valor do atendimento não pode ser negativo.");
    if (tag === "purchase" && purchaseValue <= 0) throw new Error("Informe o valor da compra.");
    if (tag === "purchase" && !serviceOrder) throw new Error("Informe a ordem de serviço da compra.");

    return { professionalName, customerName, phone, description, tag, serviceValue, purchaseValue, serviceOrder };
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

  async function rpc(operation, args) {
    const custom = state.bridge?.attendances;
    if (operation === "workspace" && typeof custom?.load === "function") return custom.load(args);
    if (operation === "save" && typeof custom?.save === "function") return custom.save(args);
    if (typeof state.bridge?.rpc !== "function") throw new Error("Integração RPC de Atendimentos não configurada.");
    const names = { ...DEFAULT_RPC, ...(state.bridge?.attendanceRpcNames || state.bridge?.rpcNames?.attendances || {}) };
    return state.bridge.rpc(names[operation], args);
  }

  async function loadWorkspace({ quiet = false } = {}) {
    if (!state.active) return;
    if (!state.selectedStoreId) {
      state.records = [];
      state.professionals = [];
      state.serverMetrics = {};
      state.loading = false;
      state.loadError = "";
      renderWorkspace();
      return;
    }

    const storeId = state.selectedStoreId;
    const requestGeneration = ++state.generation;
    state.loading = !quiet;
    state.loadError = "";
    if (!quiet) renderWorkspace();
    try {
      const raw = await rpc("workspace", { p_store_id: storeId });
      if (!state.active || requestGeneration !== state.generation || storeId !== state.selectedStoreId) return;
      const workspace = normalizeWorkspace(raw);
      state.records = workspace.records.filter((record) => !record.storeId || record.storeId === storeId);
      state.professionals = workspace.professionals;
      state.serverMetrics = workspace.metrics;
      state.loading = false;
      state.loadError = "";
      renderWorkspace();
    } catch (error) {
      if (!state.active || requestGeneration !== state.generation) return;
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
      submitted.customerName,
      submitted.phone,
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
        p_customer_name: submitted.customerName,
        p_phone: submitted.phone,
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

  function onInput(event) {
    const target = event.target;
    if (target.matches('input[name="phone"]')) {
      target.value = formatPhone(target.value);
      return;
    }
    if (target.matches('[data-attendance-filter="search"]')) {
      state.filters.search = target.value;
      renderFilteredRegions();
    }
  }

  async function onChange(event) {
    const target = event.target;
    if (target.matches("[data-attendance-store]")) {
      const nextId = String(target.value || "");
      if (nextId && !state.stores.some((store) => store.id === nextId)) return;
      captureDraft();
      const previousId = state.selectedStoreId;
      state.selectedStoreId = nextId;
      state.contextGeneration += 1;
      state.feedback = null;
      state.records = [];
      state.professionals = [];
      state.idempotencyKey = "";
      state.idempotencyFingerprint = "";
      state.filters = { search: "", tag: "all", professional: "all", period: "30d" };
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
    if (target.matches("[data-attendance-filter]")) {
      const key = target.dataset.attendanceFilter;
      if (key && key in state.filters) state.filters[key] = target.value;
      renderFilteredRegions();
    }
  }

  async function onClick(event) {
    const button = event.target.closest("[data-attendance-action]");
    if (!button) return;
    const action = button.dataset.attendanceAction;
    if (action === "refresh") await loadWorkspace();
    if (action === "dismiss-feedback") {
      state.feedback = null;
      button.closest(".attendance-save-feedback")?.remove();
    }
  }

  function onSubmit(event) {
    const form = event.target.closest("[data-attendance-form]");
    if (!form) return;
    event.preventDefault();
    submitAttendance(form);
  }

  function bindRoot(root) {
    if (root.__attendanceHandlersBound) return;
    root.addEventListener("input", onInput);
    root.addEventListener("change", onChange);
    root.addEventListener("click", onClick);
    root.addEventListener("submit", onSubmit);
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
    state.contextGeneration += 1;
    state.feedback = null;
    syncContext({ preserveSelection: false });
    if (!mount(nextBridge.root || nextBridge.mountTarget)) {
      throw new Error("Área visual de Atendimentos não encontrada.");
    }
    await loadWorkspace();
  }

  function deactivate() {
    captureDraft();
    state.active = false;
    state.loading = false;
    state.generation += 1;
    state.contextGeneration += 1;
  }

  function resetSession() {
    state.active = false;
    state.loading = false;
    state.saving = false;
    state.generation += 1;
    state.contextGeneration += 1;
    state.selectedStoreId = "";
    state.stores = [];
    state.records = [];
    state.professionals = [];
    state.serverMetrics = {};
    state.feedback = null;
    state.loadError = "";
    state.idempotencyKey = "";
    state.idempotencyFingerprint = "";
    state.pendingSave = null;
    state.filters = { search: "", tag: "all", professional: "all", period: "30d" };
    state.drafts.clear();
    state.bridge = {};
    if (state.root) state.root.replaceChildren();
  }

  async function refreshContext(nextContext = {}) {
    captureDraft();
    state.bridge = { ...state.bridge, ...nextContext };
    state.contextGeneration += 1;
    syncContext({ preserveSelection: true });
    if (state.active) {
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
      version: 1,
      mount: "<section id=\"attendanceView\" class=\"attendance-view\" hidden></section>",
      bridge: {
        required: ["profile", "stores", "rpc"],
        optional: ["initialStoreId", "initialAgencyId", "notify", "afterSave", "onAttendanceSaved", "onStoreSelected", "attendanceRpcNames", "attendances.load", "attendances.save"],
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
            p_customer_name: "text",
            p_phone: "text (digits)",
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
      },
      rules: [
        "A tela nunca consulta mais de um p_store_id por vez.",
        "Lead e Prospecção podem estar vinculados simultaneamente.",
        "Elegibilidade e valor de bônus nunca são calculados no navegador.",
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
  });
})(window);
