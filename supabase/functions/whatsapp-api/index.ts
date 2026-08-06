import {
  serviceRpc,
  writeLog,
  writeSessionLog,
} from "../_shared/whatsapp/db.ts";
import {
  buildMessagePayload,
  createTemplate,
  downloadMedia,
  listTemplates,
  registerWebhook,
  runtimeFromUnsaved,
  updateTemplate,
  uploadMedia,
  validateConnection,
} from "../_shared/whatsapp/meta.ts";
import {
  ApiError,
  correlationId,
  corsHeaders,
  failure,
  ok,
} from "../_shared/whatsapp/response.ts";
import type { JsonObject, WhatsAppRuntime } from "../_shared/whatsapp/types.ts";

const encryptionKey = Deno.env.get("WHATSAPP_CREDENTIAL_ENCRYPTION_KEY") || "";
const maxJsonBytes = 8 * 1024 * 1024;

Deno.serve(async (request) => {
  const requestCorrelationId = correlationId(request);
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  const startedAt = Date.now();
  let input: JsonObject = {};
  let action = "";
  let sessionToken = "";
  try {
    if (request.method !== "POST") {
      throw new ApiError("Metodo nao permitido.", 405, "method_not_allowed");
    }
    sessionToken = request.headers.get("x-app-session")?.trim() || "";
    if (!sessionToken) {
      throw new ApiError("Sessao obrigatoria.", 401, "session_required");
    }
    const parsed = await parseRequest(request);
    input = parsed.input;
    action = parsed.action;
    if (!action) {
      throw new ApiError(
        "Acao do modulo WhatsApp nao informada.",
        400,
        "action_required",
      );
    }
    const data = await routeAction(
      action,
      sessionToken,
      input,
      parsed.file,
      request,
    );
    await writeSessionLog(sessionToken, {
      store_id: input.store_id,
      connection_id: input.connection_id,
      level: "info",
      category: categoryForAction(action),
      action,
      success: true,
      correlation_id: requestCorrelationId,
      latency_ms: Date.now() - startedAt,
      message: `Acao ${action} concluida.`,
    });
    if (data instanceof Response) return data;
    return ok(
      request,
      data,
      requestCorrelationId,
      action === "save-connection" ? 201 : 200,
    );
  } catch (error) {
    const logPayload: JsonObject = {
      store_id: input.store_id,
      connection_id: input.connection_id,
      level: "error",
      category: categoryForAction(action),
      action: action || "unknown",
      success: false,
      correlation_id: requestCorrelationId,
      latency_ms: Date.now() - startedAt,
      error_code: error instanceof ApiError ? error.code : "internal_error",
      message: error instanceof Error
        ? error.message
        : "Falha no modulo WhatsApp.",
    };
    if (sessionToken) await writeSessionLog(sessionToken, logPayload);
    else await writeLog(logPayload);
    return failure(request, error, requestCorrelationId);
  }
});

async function routeAction(
  action: string,
  sessionToken: string,
  input: JsonObject,
  file: File | null,
  request: Request,
): Promise<unknown> {
  switch (action) {
    case "bootstrap":
      return await serviceRpc("wa_get_bootstrap", {
        p_session_token: sessionToken,
        p_store_id: requiredString(input.store_id, "Cliente obrigatorio."),
      });
    case "save-connection":
      return await saveConnection(sessionToken, input, false);
    case "update-token":
      return await saveConnection(sessionToken, input, true);
    case "validate":
      return await validateAction(sessionToken, input, false);
    case "reconnect":
      return await validateAction(sessionToken, input, true);
    case "disconnect":
      return {
        disconnected: await serviceRpc("wa_disconnect_connection", {
          p_session_token: sessionToken,
          p_connection_id: requiredString(
            input.connection_id,
            "Conexao obrigatoria.",
          ),
        }),
      };
    case "register-webhook":
      return await registerWebhookAction(sessionToken, input);
    case "test":
      return await validateAction(sessionToken, input, false);
    case "test-send":
      return await testSendAction(sessionToken, input);
    case "send-message":
      return await enqueueMessage(sessionToken, input);
    case "sync-templates":
      return await syncTemplates(sessionToken, input);
    case "create-template":
      return await createTemplateAction(sessionToken, input);
    case "upload-media":
      return await uploadMediaAction(sessionToken, input, file);
    case "media-url":
    case "download-media":
      return await downloadMediaAction(sessionToken, input, request);
    case "create-campaign":
      return await createCampaignAction(sessionToken, input);
    case "action-campaign":
      return await serviceRpc("wa_campaign_action", {
        p_session_token: sessionToken,
        p_campaign_id: requiredString(
          input.campaign_id,
          "Campanha obrigatoria.",
        ),
        p_action: requiredString(
          input.campaign_action || input.command,
          "Acao da campanha obrigatoria.",
        ),
      });
    case "campaign-report":
      return await serviceRpc("wa_get_campaign_report", {
        p_session_token: sessionToken,
        p_campaign_id: requiredString(
          input.campaign_id,
          "Campanha obrigatoria.",
        ),
        p_limit: boundedInteger(input.limit, 200, 1, 1000),
        p_offset: boundedInteger(input.offset, 0, 0, 10_000_000),
      });
    case "import-contacts":
      return await serviceRpc("wa_service_import_contacts", {
        p_session_token: sessionToken,
        p_store_id: requiredString(input.store_id, "Cliente obrigatorio."),
        p_contacts: requireArray(
          input.contacts,
          "Lista de contatos obrigatoria.",
        ),
      });
    case "reprocess-webhook":
      return await reprocessWebhook(sessionToken, input);
    default:
      throw new ApiError(
        `Acao desconhecida: ${action}.`,
        400,
        "unknown_action",
      );
  }
}

async function createCampaignAction(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  const campaignId = await serviceRpc<string>("wa_upsert_campaign", {
    p_session_token: sessionToken,
    p_store_id: requiredString(input.store_id, "Cliente obrigatorio."),
    p_campaign_id: optionalString(input.campaign_id),
    p_payload: asObject(input.payload || input.campaign || input),
  });
  const report = await serviceRpc<JsonObject>("wa_get_campaign_report", {
    p_session_token: sessionToken,
    p_campaign_id: campaignId,
    p_limit: 1,
    p_offset: 0,
  });
  return {
    id: campaignId,
    campaign_id: campaignId,
    audience_count: asObject(report.summary).total || 0,
  };
}

async function saveConnection(
  sessionToken: string,
  input: JsonObject,
  tokenOnly: boolean,
): Promise<unknown> {
  requireEncryptionKey();
  const payload = asObject(input.connection || input.payload || input);
  if (
    tokenOnly && !optionalString(payload.connection_id || input.connection_id)
  ) {
    throw new ApiError(
      "Conexao obrigatoria para atualizar o token.",
      400,
      "connection_required",
    );
  }
  if (tokenOnly && !optionalString(payload.access_token)) {
    throw new ApiError(
      "Novo Access Token obrigatorio.",
      400,
      "access_token_required",
    );
  }
  let validationDetails: JsonObject | null = null;
  if (tokenOnly) {
    const current = await serviceRpc<WhatsAppRuntime>(
      "wa_service_connection_runtime",
      {
        p_session_token: sessionToken,
        p_connection_id: String(payload.connection_id || input.connection_id),
        p_encryption_key: encryptionKey,
        p_configuration_write: true,
      },
    );
    validationDetails = await validateConnection({
      ...current,
      secrets: {
        ...current.secrets,
        access_token: String(payload.access_token).trim(),
      },
    });
  }
  const payloadToPersist: JsonObject = tokenOnly
    ? {
      connection_id: payload.connection_id || input.connection_id,
      access_token: String(payload.access_token || "").trim(),
    }
    : {
      ...payload,
      connection_id: payload.connection_id || input.connection_id || null,
      store_id: payload.store_id || input.store_id || null,
    };
  const saved = await serviceRpc<JsonObject>("wa_service_save_connection", {
    p_session_token: sessionToken,
    p_payload: payloadToPersist,
    p_encryption_key: encryptionKey,
  });
  if (tokenOnly && validationDetails) {
    await persistConnectionValidation(
      String(saved.id || payload.connection_id || input.connection_id),
      validationDetails,
    );
    return { ...saved, validated: true, details: validationDetails };
  }
  return saved;
}

async function validateAction(
  sessionToken: string,
  input: JsonObject,
  reconnect: boolean,
): Promise<JsonObject> {
  const persistedRuntime = await resolveRuntime(sessionToken, input, true);
  const runtime = reconnect
    ? persistedRuntime
    : mergeRuntimeCandidate(persistedRuntime, input);
  const validatesCandidate = persistedRuntime.id !== "unsaved" &&
    runtimeValidationIdentityChanged(persistedRuntime, runtime);
  const persistsStatus = runtime.id !== "unsaved" && !validatesCandidate;
  const preservesOperationalStatus = isOperationalConnectionStatus(
    persistedRuntime.status,
  );
  if (persistsStatus && !preservesOperationalStatus) {
    await serviceRpc("wa_service_set_connection_status", {
      p_connection_id: runtime.id,
      p_status: "validating",
      p_error_code: null,
      p_error_message: null,
      p_metadata: {},
    });
  }
  try {
    const details = await validateConnection(runtime);
    if (persistsStatus) {
      await persistConnectionValidation(runtime.id, details);
    }
    return {
      valid: true,
      reconnected: reconnect,
      connection_id: runtime.id,
      candidate_validated: validatesCandidate || runtime.id === "unsaved",
      persisted_status: persistsStatus,
      details,
    };
  } catch (error) {
    if (persistsStatus) {
      await serviceRpc("wa_service_set_connection_status", {
        p_connection_id: runtime.id,
        p_status: shouldMarkConnectionError(error)
          ? "error"
          : persistedRuntime.status,
        p_error_code: error instanceof ApiError
          ? error.code
          : "validation_failed",
        p_error_message: error instanceof Error
          ? error.message
          : "Credenciais invalidas.",
        p_metadata: {},
      }).catch(() => null);
    }
    throw error;
  }
}

async function persistConnectionValidation(
  connectionId: string,
  details: JsonObject,
): Promise<void> {
  const phone = asObject(details.phone);
  const token = asObject(details.token);
  const businessAccount = asObject(details.business_account);
  await serviceRpc("wa_service_set_connection_status", {
    p_connection_id: connectionId,
    p_status: "connected",
    p_error_code: null,
    p_error_message: null,
    p_metadata: {
      quality_rating: phone.quality_rating,
      throughput_level: asObject(phone.throughput).level,
      whatsapp_business_manager_messaging_limit:
        phone.whatsapp_business_manager_messaging_limit,
      token_expires_at: token.expires_at,
      display_phone_number: phone.display_phone_number,
      verified_name: phone.verified_name,
      provider_status: phone.status,
      code_verification_status: phone.code_verification_status,
      name_status: phone.name_status,
      token_scopes: token.scopes,
      business_account_name: businessAccount.name,
      business_account_review_status: businessAccount.account_review_status,
    },
  });
}

async function registerWebhookAction(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  const runtime = await resolveRuntime(sessionToken, input, true);
  if (runtime.id === "unsaved") {
    throw new ApiError(
      "Salve a conexao antes de registrar o webhook.",
      409,
      "connection_must_be_saved",
    );
  }
  const preservesOperationalStatus = isOperationalConnectionStatus(
    runtime.status,
  );
  if (!preservesOperationalStatus) {
    await serviceRpc("wa_service_set_connection_status", {
      p_connection_id: runtime.id,
      p_status: "validating",
      p_error_code: null,
      p_error_message: null,
      p_metadata: {},
    });
  }
  try {
    // O wizard valida novamente a versao que acabou de ser persistida. Isso
    // evita promover para "connected" dados diferentes dos testados no passo
    // anterior ou alterados em outra aba entre validar e salvar.
    const validation = await validateConnection(runtime);
    const result = await registerWebhook(runtime);
    await persistConnectionValidation(runtime.id, validation);
    return {
      registered: true,
      connection_id: runtime.id,
      webhook_url: runtime.webhook_url,
      callback_subscription: result.callback_subscription,
      waba_subscription: result.waba_subscription,
      fields: result.fields,
      validation,
    };
  } catch (error) {
    await serviceRpc("wa_service_set_connection_status", {
      p_connection_id: runtime.id,
      p_status: preservesOperationalStatus || !shouldMarkConnectionError(error)
        ? runtime.status
        : "error",
      p_error_code: error instanceof ApiError
        ? error.code
        : "webhook_registration_failed",
      p_error_message: error instanceof Error
        ? error.message
        : "Nao foi possivel registrar o webhook.",
      p_metadata: {},
    }).catch(() => null);
    throw error;
  }
}

async function testSendAction(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  const runtime = await resolveRuntime(sessionToken, input, true);
  const contactId = requiredString(
    input.contact_id,
    "Selecione um contato com consentimento valido para receber o teste.",
  );
  const type = String(input.type || "template").toLowerCase();
  if (type !== "template") {
    throw new ApiError(
      "O envio de teste aceita somente template aprovado. Mensagens operacionais devem usar a fila e as regras de consentimento.",
      400,
      "test_send_template_only",
    );
  }
  const templateName = requiredString(
    input.template_name,
    "Escolha um template aprovado para o teste.",
  );
  const templateLanguage = String(input.template_language || "pt_BR").trim();
  const queued = await serviceRpc<JsonObject>("wa_service_enqueue_message", {
    p_session_token: sessionToken,
    p_payload: {
      store_id: runtime.store_id,
      connection_id: runtime.id,
      contact_id: contactId,
      type,
      template_name: templateName,
      template_language: templateLanguage,
      template_parameters: Array.isArray(input.template_parameters)
        ? input.template_parameters
        : [],
      idempotency_key: `wizard-test:${runtime.id}:${crypto.randomUUID()}`,
    },
  });
  return {
    queued: true,
    persisted: true,
    connection_id: runtime.id,
    ...queued,
  };
}

async function enqueueMessage(
  sessionToken: string,
  input: JsonObject,
): Promise<unknown> {
  const message = asObject(input.message || input.payload || input);
  const payload: JsonObject = {
    ...message,
    store_id: message.store_id || input.store_id,
    connection_id: message.connection_id || input.connection_id,
  };
  if (payload.to) payload.provider_payload = buildMessagePayload(payload);
  return await serviceRpc("wa_service_enqueue_message", {
    p_session_token: sessionToken,
    p_payload: payload,
  });
}

async function syncTemplates(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  const runtime = await resolveRuntime(sessionToken, input, false);
  const templates = await listTemplates(runtime);
  const synced = await serviceRpc<number>("wa_service_upsert_templates", {
    p_connection_id: runtime.id,
    p_templates: templates,
  });
  return { synced, templates };
}

async function createTemplateAction(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  const template = asObject(input.template || input.payload);
  let providerTemplateId = optionalString(
    template.provider_template_id || input.provider_template_id,
  );
  let connectionId = optionalString(
    input.connection_id || template.connection_id,
  );
  if (
    !providerTemplateId &&
    optionalString(input.template_id || template.template_id)
  ) {
    const stored = await serviceRpc<JsonObject>(
      "wa_service_template_for_edit",
      {
        p_session_token: sessionToken,
        p_template_id: String(input.template_id || template.template_id),
      },
    );
    providerTemplateId = optionalString(stored.provider_template_id);
    connectionId = optionalString(stored.connection_id);
  }
  const runtime = await resolveRuntime(
    sessionToken,
    { ...input, connection_id: connectionId || input.connection_id },
    true,
  );
  if (providerTemplateId) validateTemplateEditInput(template);
  else validateTemplateInput(template);
  const created = providerTemplateId
    ? await updateTemplate(runtime, providerTemplateId, template)
    : await createTemplate(runtime, template);
  const refreshed = await listTemplates(runtime);
  await serviceRpc("wa_service_upsert_templates", {
    p_connection_id: runtime.id,
    p_templates: refreshed,
  });
  return {
    created: !providerTemplateId,
    updated: Boolean(providerTemplateId),
    provider_template_id: providerTemplateId || created.id,
    provider_response: created,
    synced: refreshed.length,
  };
}

async function uploadMediaAction(
  sessionToken: string,
  input: JsonObject,
  file: File | null,
): Promise<JsonObject> {
  if (!file) throw new ApiError("Selecione um arquivo.", 400, "file_required");
  validateMediaFile(file);
  const runtime = await resolveRuntime(sessionToken, input, false);
  const uploaded = await uploadMedia(runtime, file);
  return {
    uploaded: true,
    id: uploaded.id,
    filename: file.name,
    mime_type: file.type,
    size: file.size,
  };
}

async function downloadMediaAction(
  sessionToken: string,
  input: JsonObject,
  request: Request,
): Promise<Response> {
  requireEncryptionKey();
  const attachment = await serviceRpc<JsonObject>(
    "wa_service_attachment_runtime",
    {
      p_session_token: sessionToken,
      p_attachment_id: requiredString(
        input.attachment_id,
        "Anexo obrigatorio.",
      ),
    },
  );
  const runtime = await serviceRpc<WhatsAppRuntime>(
    "wa_service_connection_runtime",
    {
      p_session_token: sessionToken,
      p_connection_id: requiredString(
        attachment.connection_id,
        "Anexo sem conexao.",
      ),
      p_encryption_key: encryptionKey,
      p_configuration_write: false,
    },
  );
  const media = await downloadMedia(
    runtime,
    requiredString(
      attachment.provider_media_id,
      "Anexo sem identificador da Meta.",
    ),
  );
  const filename = safeFilename(
    String(attachment.original_filename || `whatsapp-${attachment.id}`),
  );
  const disposition = canRenderInline(media.mimeType) ? "inline" : "attachment";
  return new Response(media.body, {
    status: 200,
    headers: {
      ...corsHeaders(request),
      "Access-Control-Expose-Headers":
        "Content-Type, Content-Length, Content-Disposition",
      "Content-Type": media.mimeType,
      ...(media.contentLength ? { "Content-Length": media.contentLength } : {}),
      "Content-Disposition": `${disposition}; filename="${filename}"`,
      "Cache-Control": "private, no-store, max-age=0",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": "sandbox; default-src 'none'",
    },
  });
}

async function reprocessWebhook(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  const eventId = requiredString(input.event_id, "Evento obrigatorio.");
  await serviceRpc("wa_reprocess_webhook", {
    p_session_token: sessionToken,
    p_event_id: eventId,
  });
  return { queued: true, event_id: eventId };
}

async function resolveRuntime(
  sessionToken: string,
  input: JsonObject,
  configurationWrite: boolean,
): Promise<WhatsAppRuntime> {
  const connectionId = optionalString(
    input.connection_id || asObject(input.connection).connection_id,
  );
  if (!connectionId) {
    return runtimeFromUnsaved(asObject(input.connection || input));
  }
  requireEncryptionKey();
  return await serviceRpc<WhatsAppRuntime>("wa_service_connection_runtime", {
    p_session_token: sessionToken,
    p_connection_id: connectionId,
    p_encryption_key: encryptionKey,
    p_configuration_write: configurationWrite,
  });
}

/**
 * Combina somente os campos de configuracao permitidos com a conexao
 * persistida. Assim, o wizard e a tela de configuracao conseguem validar uma
 * credencial candidata sem grava-la ou substituir uma conexao que continua
 * operacional. Campos vazios significam "manter o valor protegido atual".
 */
function mergeRuntimeCandidate(
  persisted: WhatsAppRuntime,
  input: JsonObject,
): WhatsAppRuntime {
  if (persisted.id === "unsaved") return persisted;
  const nestedConnection = asObject(input.connection);
  const nestedPayload = asObject(input.payload);
  const source = Object.keys(nestedConnection).length
    ? nestedConnection
    : Object.keys(nestedPayload).length
    ? nestedPayload
    : input;
  const nestedSecrets = asObject(source.secrets);
  const candidate = (
    keys: string[],
    fallback: string | undefined,
  ): string | undefined => {
    for (const key of keys) {
      const value = optionalString(source[key]);
      if (value) return value;
    }
    return fallback;
  };
  const candidateSecret = (
    key: keyof WhatsAppRuntime["secrets"],
  ): string =>
    optionalString(nestedSecrets[key]) ||
    optionalString(source[key]) || persisted.secrets[key];

  return {
    ...persisted,
    name: candidate(["name"], persisted.name) || persisted.name,
    phone_number_id: candidate(
      ["phone_number_id"],
      persisted.phone_number_id,
    ) || persisted.phone_number_id,
    business_account_id: candidate(
      ["business_account_id", "waba_id"],
      persisted.business_account_id,
    ) || persisted.business_account_id,
    display_phone_number: candidate(
      ["display_phone_number", "phone_number"],
      persisted.display_phone_number,
    ),
    app_id: candidate(["app_id"], persisted.app_id),
    graph_api_version: candidate(
      ["graph_api_version", "api_version"],
      persisted.graph_api_version,
    ) || persisted.graph_api_version,
    webhook_url: candidate(["webhook_url"], persisted.webhook_url),
    secrets: {
      access_token: candidateSecret("access_token"),
      app_secret: candidateSecret("app_secret"),
      verify_token: candidateSecret("verify_token"),
    },
  };
}

/**
 * Somente diferencas que participam da validacao contra a Meta impedem que o
 * resultado altere o status da conexao persistida. Nome, URL do callback e
 * Verify Token nao fazem parte de validateConnection.
 */
function runtimeValidationIdentityChanged(
  persisted: WhatsAppRuntime,
  candidate: WhatsAppRuntime,
): boolean {
  return persisted.phone_number_id !== candidate.phone_number_id ||
    persisted.business_account_id !== candidate.business_account_id ||
    (persisted.display_phone_number || "") !==
      (candidate.display_phone_number || "") ||
    (persisted.app_id || "") !== (candidate.app_id || "") ||
    persisted.graph_api_version !== candidate.graph_api_version ||
    persisted.secrets.access_token !== candidate.secrets.access_token ||
    persisted.secrets.app_secret !== candidate.secrets.app_secret;
}

function isOperationalConnectionStatus(status: string): boolean {
  return status === "connected" || status === "token_expiring";
}

function shouldMarkConnectionError(error: unknown): boolean {
  return error instanceof ApiError && !error.retryable &&
    (error.code === "meta_api_error" ||
      [400, 401, 403, 409].includes(error.status));
}

async function parseRequest(request: Request): Promise<{
  action: string;
  input: JsonObject;
  file: File | null;
}> {
  const url = new URL(request.url);
  const queryAction = url.searchParams.get("action") || "";
  const contentType = request.headers.get("content-type") || "";
  const declaredLength = Number(request.headers.get("content-length") || 0);
  if (
    !contentType.includes("multipart/form-data") &&
    declaredLength > maxJsonBytes
  ) {
    throw new ApiError(
      "Requisicao JSON excede 8 MB.",
      413,
      "payload_too_large",
    );
  }
  if (contentType.includes("multipart/form-data")) {
    const form = await request.formData();
    const input: JsonObject = {};
    let file: File | null = null;
    for (const [key, value] of form.entries()) {
      if (value instanceof File) {
        if (key === "file") file = value;
      } else if (key === "payload") {
        try {
          Object.assign(input, JSON.parse(value));
        } catch {
          throw new ApiError(
            "Campo payload do upload nao e JSON valido.",
            400,
            "invalid_upload_payload",
          );
        }
      } else input[key] = value;
    }
    return { action: queryAction || String(input.action || ""), input, file };
  }
  const input = await request.json().catch(() => {
    throw new ApiError("JSON da requisicao invalido.", 400, "invalid_json");
  }) as JsonObject;
  return {
    action: queryAction || String(input.action || ""),
    input,
    file: null,
  };
}

function validateMediaFile(file: File): void {
  const mime = (file.type || "application/octet-stream").toLowerCase();
  const category = mime.startsWith("image/")
    ? "image"
    : mime.startsWith("audio/")
    ? "audio"
    : mime.startsWith("video/")
    ? "video"
    : "document";
  const limit = category === "image"
    ? 5 * 1024 * 1024
    : category === "document"
    ? 100 * 1024 * 1024
    : 16 * 1024 * 1024;
  if (!file.size || file.size > limit) {
    throw new ApiError(
      `${category === "document" ? "Documento" : "Arquivo"} excede ${
        Math.round(limit / 1024 / 1024)
      } MB.`,
      413,
      "media_too_large",
    );
  }
}

function validateTemplateInput(template: JsonObject): void {
  const name = String(template.name || "");
  if (!/^[a-z0-9_]{1,512}$/.test(name)) {
    throw new ApiError(
      "Nome do template deve usar minusculas, numeros e sublinhado.",
      400,
      "invalid_template_name",
    );
  }
  if (
    !["MARKETING", "UTILITY", "AUTHENTICATION"].includes(
      String(template.category || "").toUpperCase(),
    )
  ) {
    throw new ApiError(
      "Categoria do template invalida.",
      400,
      "invalid_template_category",
    );
  }
  if (!String(template.language || "") || !Array.isArray(template.components)) {
    throw new ApiError(
      "Idioma e componentes do template sao obrigatorios.",
      400,
      "template_incomplete",
    );
  }
}

function validateTemplateEditInput(template: JsonObject): void {
  if (
    template.category &&
    !["MARKETING", "UTILITY", "AUTHENTICATION"].includes(
      String(template.category).toUpperCase(),
    )
  ) {
    throw new ApiError(
      "Categoria do template invalida.",
      400,
      "invalid_template_category",
    );
  }
  if (!template.category && !Array.isArray(template.components)) {
    throw new ApiError(
      "Informe categoria ou componentes para editar. Nome e idioma exigem a criacao de um novo template.",
      400,
      "template_changes_required",
    );
  }
}

function categoryForAction(action: string): string {
  if (action.includes("template")) return "template";
  if (action.includes("campaign")) return "campaign";
  if (action.includes("webhook")) return "webhook";
  if (action.includes("media")) return "media";
  if (["send-message", "test", "test-send"].includes(action)) return "message";
  return "connection";
}

function safeFilename(value: string): string {
  const cleaned = value.replace(/[\r\n"\\/]/g, "_").trim().slice(0, 180);
  return cleaned || "arquivo-whatsapp";
}

function canRenderInline(value: string): boolean {
  const mime = value.split(";", 1)[0].trim().toLowerCase();
  return /^(image\/(?:jpeg|png|gif|webp)|audio\/[a-z0-9.+-]+|video\/[a-z0-9.+-]+|application\/pdf)$/
    .test(
      mime,
    );
}

function requireEncryptionKey(): void {
  if (encryptionKey.length < 32) {
    throw new ApiError(
      "WHATSAPP_CREDENTIAL_ENCRYPTION_KEY nao configurada.",
      500,
      "credential_key_missing",
    );
  }
}

function requiredString(value: unknown, message: string): string {
  const result = typeof value === "string" ? value.trim() : "";
  if (!result) throw new ApiError(message, 400, "required_field_missing");
  return result;
}

function optionalString(value: unknown): string | null {
  const result = typeof value === "string" ? value.trim() : "";
  return result || null;
}

function asObject(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

function requireArray(value: unknown, message: string): unknown[] {
  if (!Array.isArray(value)) throw new ApiError(message, 400, "array_required");
  return value;
}

function boundedInteger(
  value: unknown,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const parsed = Number(value);
  return Math.min(
    Math.max(Number.isFinite(parsed) ? Math.trunc(parsed) : fallback, minimum),
    maximum,
  );
}
