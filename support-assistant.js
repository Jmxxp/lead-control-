(() => {
  "use strict";

  const CONTEXT_EVENT = "lead-control:support-context-request";
  const NAVIGATE_EVENT = "lead-control:support-navigate";
  const MAX_MESSAGES = 6;
  const MAX_MESSAGE_LENGTH = 1800;

  const ACTION_CATALOG = Object.freeze({
    open_leads: Object.freeze({
      label: "Abrir Leads",
      icon: "fa-user-group",
      targetId: "moduleLeadsButton",
    }),
    open_prospections: Object.freeze({
      label: "Abrir Prospecções",
      icon: "fa-phone",
      targetId: "moduleProspectionsButton",
    }),
    open_attendances: Object.freeze({
      label: "Abrir Atendimentos",
      icon: "fa-clipboard-check",
      targetId: "moduleAttendancesButton",
    }),
    open_lead_configuration: Object.freeze({
      label: "Editar categorias",
      icon: "fa-sliders",
      targetId: "toggleOptionsEdit",
    }),
  });

  const appView = document.querySelector("#appView");
  const toggle = document.querySelector("#supportAssistantToggle");
  if (!appView || !toggle) return;

  const state = {
    messages: [],
    pending: false,
    controller: null,
    lastFocus: null,
    generation: 0,
  };

  const panel = buildPanel();
  appView.append(panel);

  const closeButton = panel.querySelector("#supportAssistantClose");
  const messages = panel.querySelector("#supportAssistantMessages");
  const form = panel.querySelector("#supportAssistantForm");
  const input = panel.querySelector("#supportAssistantInput");
  const sendButton = panel.querySelector("#supportAssistantSend");
  const quickPrompts = panel.querySelector("#supportAssistantPrompts");

  renderGreeting();

  toggle.addEventListener("click", () => {
    if (panel.hidden) openPanel();
    else closePanel();
  });
  closeButton.addEventListener("click", closePanel);
  form.addEventListener("submit", handleSubmit);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      form.requestSubmit();
    }
  });
  input.addEventListener("input", autoResizeInput);
  quickPrompts.addEventListener("click", (event) => {
    const button = event.target.closest("[data-support-prompt]");
    if (!button || state.pending) return;
    input.value = button.dataset.supportPrompt || "";
    autoResizeInput();
    form.requestSubmit();
  });
  messages.addEventListener("click", (event) => {
    const button = event.target.closest("[data-support-action]");
    if (!button || button.disabled) return;
    void runAllowedAction(button.dataset.supportAction || "");
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !panel.hidden) closePanel();
  });

  new MutationObserver(() => {
    if (appView.hidden) resetForSignedOutSession();
    else refreshRenderedActions();
  }).observe(appView, { attributes: true, attributeFilter: ["hidden"] });

  const capabilityObserver = new MutationObserver(refreshRenderedActions);
  [
    "moduleSwitcher",
    "moduleLeadsButton",
    "moduleProspectionsButton",
    "moduleAttendancesButton",
    "storeView",
    "toggleOptionsEdit",
  ].forEach((id) => {
    const element = document.getElementById(id);
    if (element) {
      capabilityObserver.observe(element, {
        attributes: true,
        attributeFilter: ["hidden", "disabled", "class"],
      });
    }
  });

  window.SupportAssistant = Object.freeze({
    contextEvent: CONTEXT_EVENT,
    navigateEvent: NAVIGATE_EVENT,
    allowedActionIds: Object.freeze(Object.keys(ACTION_CATALOG)),
    close: closePanel,
    refreshCapabilities: refreshRenderedActions,
  });

  function buildPanel() {
    const element = document.createElement("aside");
    element.id = "supportAssistantPanel";
    element.className = "support-assistant-panel";
    element.hidden = true;
    element.setAttribute("role", "dialog");
    element.setAttribute("aria-modal", "false");
    element.setAttribute("aria-labelledby", "supportAssistantTitle");
    element.innerHTML = `
      <header class="support-assistant-header">
        <div class="support-assistant-heading">
          <span class="support-assistant-mark" aria-hidden="true"><i class="fa-solid fa-wand-magic-sparkles"></i></span>
          <div>
            <p>Suporte IA</p>
            <h2 id="supportAssistantTitle">Como posso ajudar?</h2>
          </div>
        </div>
        <button id="supportAssistantClose" class="support-assistant-close" type="button" aria-label="Fechar suporte" title="Fechar suporte">
          <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
      </header>
      <div id="supportAssistantMessages" class="support-assistant-messages" role="log" aria-live="polite" aria-relevant="additions"></div>
      <div id="supportAssistantPrompts" class="support-assistant-prompts" aria-label="Perguntas rápidas">
        <button type="button" data-support-prompt="Como cadastrar um lead?">Cadastrar lead</button>
        <button type="button" data-support-prompt="Como usar os filtros de prospecções?">Filtrar prospecções</button>
        <button type="button" data-support-prompt="Como registrar um atendimento?">Novo atendimento</button>
      </div>
      <form id="supportAssistantForm" class="support-assistant-form">
        <label class="support-assistant-input-wrap" for="supportAssistantInput">
          <textarea id="supportAssistantInput" rows="1" maxlength="${MAX_MESSAGE_LENGTH}" placeholder="Pergunte sobre uma tela..." aria-label="Pergunta para o suporte"></textarea>
          <button id="supportAssistantSend" type="submit" aria-label="Enviar pergunta" title="Enviar pergunta">
            <i class="fa-solid fa-arrow-up" aria-hidden="true"></i>
          </button>
        </label>
      </form>
    `;
    return element;
  }

  function openPanel() {
    if (appView.hidden) return;
    state.lastFocus = document.activeElement;
    panel.hidden = false;
    toggle.classList.add("is-active");
    toggle.setAttribute("aria-expanded", "true");
    refreshRenderedActions();
    requestAnimationFrame(() => input.focus());
  }

  function closePanel() {
    if (panel.hidden) return;
    panel.hidden = true;
    toggle.classList.remove("is-active");
    toggle.setAttribute("aria-expanded", "false");
    const focusTarget = state.lastFocus instanceof HTMLElement && state.lastFocus.isConnected
      ? state.lastFocus
      : toggle;
    focusTarget.focus({ preventScroll: true });
  }

  function resetForSignedOutSession() {
    closePanel();
    state.generation += 1;
    state.controller?.abort();
    state.controller = null;
    state.pending = false;
    state.messages = [];
    setBusy(false);
    input.value = "";
    autoResizeInput();
    messages.replaceChildren();
    renderGreeting();
  }

  function renderGreeting() {
    renderAssistantMessage(
      "Olá! Eu ensino como usar **Leads**, **Prospecções** e **Atendimentos**. O que você quer fazer?",
      [],
      { transient: true },
    );
  }

  async function handleSubmit(event) {
    event.preventDefault();
    if (state.pending) return;

    const question = normalizeUserMessage(input.value);
    if (!question) {
      input.focus();
      return;
    }

    const runtime = requestRuntimeContext();
    if (!runtime.supabaseUrl || !runtime.anonKey || !runtime.sessionToken) {
      renderAssistantMessage("Sua sessão não está disponível. Entre novamente para usar o suporte.", []);
      return;
    }

    input.value = "";
    autoResizeInput();
    appendUserMessage(question);
    state.messages.push({ role: "user", content: question });
    trimConversation();
    setBusy(true);
    const typing = appendTypingIndicator();

    state.controller?.abort();
    const controller = new AbortController();
    const requestGeneration = ++state.generation;
    state.controller = controller;
    const timeoutId = window.setTimeout(() => controller.abort(), 30_000);

    try {
      const requestHeaders = {
        "Content-Type": "application/json",
        apikey: runtime.anonKey,
        "x-app-session": runtime.sessionToken,
      };
      if (!runtime.anonKey.startsWith("sb_publishable_")) {
        requestHeaders.Authorization = `Bearer ${runtime.anonKey}`;
      }
      const response = await fetch(`${runtime.supabaseUrl}/functions/v1/ai-analysis`, {
        method: "POST",
        headers: requestHeaders,
        body: JSON.stringify({
          action: "support",
          store_id: runtime.storeId || null,
          screen: runtime.activeModule || null,
          messages: state.messages.slice(-MAX_MESSAGES),
        }),
        signal: controller.signal,
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(typeof payload?.error === "string" ? payload.error : "O suporte não respondeu.");
      }
      if (requestGeneration !== state.generation || appView.hidden) return;

      const answer = typeof payload?.answer_markdown === "string"
        ? payload.answer_markdown
        : "Não consegui responder agora. Tente explicar a ação usando o nome da tela.";
      const actionIds = sanitizeResponseActionIds(payload?.actions);
      typing.remove();
      renderAssistantMessage(answer, actionIds);
      state.messages.push({ role: "assistant", content: answer.slice(0, MAX_MESSAGE_LENGTH) });
      trimConversation();
    } catch (error) {
      typing.remove();
      if (requestGeneration !== state.generation || appView.hidden) return;
      const message = error?.name === "AbortError"
        ? "A resposta demorou demais. Tente novamente em instantes."
        : error?.message || "Não foi possível consultar o suporte agora.";
      renderAssistantMessage(message, []);
    } finally {
      window.clearTimeout(timeoutId);
      if (requestGeneration === state.generation && state.controller === controller) {
        state.controller = null;
        setBusy(false);
        if (!appView.hidden) input.focus();
      }
    }
  }

  function requestRuntimeContext() {
    let provided = null;
    const detail = Object.freeze({
      provide(value) {
        if (provided) return;
        provided = sanitizeRuntimeContext(value);
      },
    });
    window.dispatchEvent(new CustomEvent(CONTEXT_EVENT, { detail }));
    if (provided) return provided;

    try {
      const profile = typeof currentProfile === "object" && currentProfile ? currentProfile : null;
      return sanitizeRuntimeContext({
        supabaseUrl: typeof SUPABASE_URL === "string" ? SUPABASE_URL : "",
        anonKey: typeof SUPABASE_ANON_KEY === "string" ? SUPABASE_ANON_KEY : "",
        sessionToken: profile?.sessionToken,
        storeId: profile?.storeId,
        activeModule: "leads",
      });
    } catch {
      return sanitizeRuntimeContext(null);
    }
  }

  function sanitizeRuntimeContext(value) {
    const source = value && typeof value === "object" && !Array.isArray(value) ? value : {};
    return {
      supabaseUrl: safeString(source.supabaseUrl, 400),
      anonKey: safeString(source.anonKey, 2400),
      sessionToken: safeString(source.sessionToken, 1200),
      storeId: safeString(source.storeId, 80),
      activeModule: ["leads", "prospections", "attendances"].includes(source.activeModule)
        ? source.activeModule
        : "",
      availableActions: Array.isArray(source.availableActions)
        ? source.availableActions.filter(isKnownActionId)
        : null,
    };
  }

  function sanitizeResponseActionIds(value) {
    if (!Array.isArray(value)) return [];
    return [...new Set(value.flatMap((item) => {
      const id = typeof item === "string" ? item : item?.id;
      return isKnownActionId(id) ? [id] : [];
    }))].slice(0, 2);
  }

  function appendUserMessage(content) {
    const item = document.createElement("article");
    item.className = "support-assistant-message support-assistant-message--user";
    const bubble = document.createElement("div");
    bubble.textContent = content;
    item.append(bubble);
    messages.append(item);
    scrollMessages();
  }

  function renderAssistantMessage(content, actionIds, { transient = false } = {}) {
    const item = document.createElement("article");
    item.className = "support-assistant-message support-assistant-message--assistant";
    if (transient) item.dataset.transient = "true";

    const avatar = document.createElement("span");
    avatar.className = "support-assistant-message-icon";
    avatar.setAttribute("aria-hidden", "true");
    const icon = document.createElement("i");
    icon.className = "fa-solid fa-wand-magic-sparkles";
    avatar.append(icon);

    const body = document.createElement("div");
    body.className = "support-assistant-message-body";
    renderSafeMarkdown(body, content);
    renderActionButtons(body, actionIds);
    item.append(avatar, body);
    messages.append(item);
    scrollMessages();
  }

  function renderSafeMarkdown(container, markdown) {
    const lines = String(markdown || "").replace(/\r/g, "").slice(0, 3000).split("\n");
    let list = null;
    let listType = "";

    lines.forEach((rawLine) => {
      const line = rawLine.trim();
      if (!line) {
        list = null;
        listType = "";
        return;
      }

      const ordered = line.match(/^\d+[.)]\s+(.+)$/);
      const unordered = line.match(/^[-*]\s+(.+)$/);
      const nextListType = ordered ? "ol" : unordered ? "ul" : "";
      if (nextListType) {
        if (!list || listType !== nextListType) {
          list = document.createElement(nextListType);
          listType = nextListType;
          container.append(list);
        }
        const item = document.createElement("li");
        appendSafeInlineMarkdown(item, ordered?.[1] || unordered?.[1] || "");
        list.append(item);
        return;
      }

      list = null;
      listType = "";
      const paragraph = document.createElement("p");
      appendSafeInlineMarkdown(paragraph, line.replace(/^#{1,3}\s+/, ""));
      container.append(paragraph);
    });
  }

  function appendSafeInlineMarkdown(container, value) {
    const text = String(value || "");
    const boldPattern = /\*\*([^*\n]{1,240})\*\*/g;
    let cursor = 0;
    let match;
    while ((match = boldPattern.exec(text))) {
      if (match.index > cursor) container.append(document.createTextNode(text.slice(cursor, match.index)));
      const strong = document.createElement("strong");
      strong.textContent = match[1];
      container.append(strong);
      cursor = match.index + match[0].length;
    }
    if (cursor < text.length) container.append(document.createTextNode(text.slice(cursor)));
  }

  function renderActionButtons(container, actionIds) {
    const available = getAvailableActionIds();
    const safeIds = actionIds.filter((id) => available.has(id));
    if (!safeIds.length) return;

    const actions = document.createElement("div");
    actions.className = "support-assistant-actions";
    safeIds.forEach((id) => {
      const definition = ACTION_CATALOG[id];
      const button = document.createElement("button");
      button.type = "button";
      button.dataset.supportAction = id;
      const icon = document.createElement("i");
      icon.className = `fa-solid ${definition.icon}`;
      icon.setAttribute("aria-hidden", "true");
      const label = document.createElement("span");
      label.textContent = definition.label;
      button.append(icon, label);
      actions.append(button);
    });
    container.append(actions);
  }

  function refreshRenderedActions() {
    const available = getAvailableActionIds();
    messages.querySelectorAll("[data-support-action]").forEach((button) => {
      const shouldHide = !available.has(button.dataset.supportAction || "");
      if (button.hidden !== shouldHide) button.hidden = shouldHide;
    });
  }

  function getAvailableActionIds() {
    const integration = requestRuntimeContext().availableActions;
    if (integration) return new Set(integration);

    const switcher = document.querySelector("#moduleSwitcher");
    const insideClient = Boolean(switcher && !switcher.hidden);
    const leadsButton = document.querySelector("#moduleLeadsButton");
    const prospectionsButton = document.querySelector("#moduleProspectionsButton");
    const attendancesButton = document.querySelector("#moduleAttendancesButton");
    const categoriesButton = document.querySelector("#toggleOptionsEdit");
    const available = new Set();

    if (insideClient && leadsButton && !leadsButton.disabled) available.add("open_leads");
    if (insideClient && isUsableModuleButton(prospectionsButton)) available.add("open_prospections");
    if (insideClient && isUsableModuleButton(attendancesButton)) available.add("open_attendances");
    if (insideClient && categoriesButton) available.add("open_lead_configuration");
    return available;
  }

  function isUsableModuleButton(button) {
    return Boolean(button && !button.disabled && !button.classList.contains("is-locked"));
  }

  async function runAllowedAction(actionId) {
    if (!isKnownActionId(actionId) || !getAvailableActionIds().has(actionId)) return;
    const navigationEvent = new CustomEvent(NAVIGATE_EVENT, {
      cancelable: true,
      detail: Object.freeze({ actionId, source: "support-assistant" }),
    });
    const useFallback = window.dispatchEvent(navigationEvent);
    if (!useFallback) {
      closePanel();
      return;
    }

    const definition = ACTION_CATALOG[actionId];
    if (actionId === "open_lead_configuration") {
      document.querySelector("#moduleLeadsButton")?.click();
      const categoriesButton = await waitForUsableElement(definition.targetId);
      categoriesButton?.click();
    } else {
      document.getElementById(definition.targetId)?.click();
    }
    closePanel();
  }

  async function waitForUsableElement(id) {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const element = document.getElementById(id);
      const storeView = document.querySelector("#storeView");
      if (element && storeView && !storeView.hidden && !element.hidden && !element.disabled) return element;
      await new Promise((resolve) => window.setTimeout(resolve, 75));
    }
    return null;
  }

  function appendTypingIndicator() {
    const item = document.createElement("article");
    item.className = "support-assistant-message support-assistant-message--assistant support-assistant-typing";
    item.setAttribute("aria-label", "Suporte está respondendo");
    const avatar = document.createElement("span");
    avatar.className = "support-assistant-message-icon";
    avatar.setAttribute("aria-hidden", "true");
    const icon = document.createElement("i");
    icon.className = "fa-solid fa-wand-magic-sparkles";
    avatar.append(icon);
    const dots = document.createElement("div");
    dots.className = "support-assistant-typing-dots";
    dots.setAttribute("aria-hidden", "true");
    dots.append(document.createElement("i"), document.createElement("i"), document.createElement("i"));
    item.append(avatar, dots);
    messages.append(item);
    scrollMessages();
    return item;
  }

  function setBusy(busy) {
    state.pending = busy;
    input.disabled = busy;
    sendButton.disabled = busy;
    quickPrompts.querySelectorAll("button").forEach((button) => { button.disabled = busy; });
    form.classList.toggle("is-busy", busy);
  }

  function trimConversation() {
    state.messages = state.messages.slice(-MAX_MESSAGES);
    while (
      state.messages.length > 1 &&
      state.messages.reduce((total, message) => total + message.content.length, 0) > 6800
    ) {
      state.messages.shift();
    }
  }

  function autoResizeInput() {
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 116)}px`;
  }

  function scrollMessages() {
    requestAnimationFrame(() => {
      messages.scrollTop = messages.scrollHeight;
    });
  }

  function normalizeUserMessage(value) {
    return String(value || "")
      .replace(/[\u0000-\u001F\u007F]/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, MAX_MESSAGE_LENGTH);
  }

  function safeString(value, limit) {
    return typeof value === "string" ? value.trim().slice(0, limit) : "";
  }

  function isKnownActionId(value) {
    return typeof value === "string" && Object.prototype.hasOwnProperty.call(ACTION_CATALOG, value);
  }
})();
