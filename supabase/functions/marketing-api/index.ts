import { randomToken, sha256Hex } from "../_shared/marketing/crypto.ts";
import {
  serviceRpc,
  supabaseFunctionUrl,
  writeLog,
  writeSessionLog,
} from "../_shared/marketing/db.ts";
import {
  buildGoogleAuthorizationUrl,
  exchangeGoogleAuthorizationCode,
  testProviderConnection,
} from "../_shared/marketing/providers.ts";
import {
  ApiError,
  correlationId,
  corsHeaders,
  failure,
  ok,
  requestOriginAllowed,
} from "../_shared/marketing/response.ts";
import type {
  JsonObject,
  MarketingConnectionRuntime,
} from "../_shared/marketing/types.ts";

const encryptionKey = Deno.env.get("MARKETING_CREDENTIALS_KEY") || "";
const trackingPepper = Deno.env.get("MARKETING_TRACKING_PEPPER") || "";
const maxJsonBytes = 1024 * 1024;

Deno.serve(async (request) => {
  const requestCorrelationId = correlationId(request);
  if (request.method === "OPTIONS") {
    // O preflight nao contem o JSON/action. Refletimos a origem aqui; no POST,
    // configuracao autenticada usa a allowlist global e o tracker publico e
    // autorizado por token + allowed_origins dentro da RPC.
    return new Response("ok", { headers: corsHeaders(request, true) });
  }
  if (request.method === "GET") {
    const url = new URL(request.url);
    if (url.searchParams.has("code") || url.searchParams.has("error")) {
      return await googleOAuthCallback(request, url, requestCorrelationId);
    }
    return failure(
      request,
      new ApiError("Rota nao encontrada.", 404, "route_not_found"),
      requestCorrelationId,
    );
  }

  let input: JsonObject = {};
  let action = "";
  let sessionToken = "";
  const startedAt = Date.now();
  try {
    if (request.method !== "POST") {
      throw new ApiError("Metodo nao permitido.", 405, "method_not_allowed");
    }
    input = await parseJsonRequest(request);
    action = requiredString(input.action, "Acao obrigatoria.");
    if (action !== "capture-touchpoint" && !requestOriginAllowed(request)) {
      throw new ApiError(
        "Origem nao autorizada para o modulo de marketing.",
        403,
        "origin_not_allowed",
      );
    }
    if (action === "capture-touchpoint") {
      const data = await captureTouchpoint(request, input);
      return ok(request, data, requestCorrelationId, 202, true);
    }
    sessionToken = request.headers.get("x-app-session")?.trim() || "";
    if (!sessionToken) {
      throw new ApiError("Sessao obrigatoria.", 401, "session_required");
    }
    const data = await routeAction(
      action,
      sessionToken,
      input,
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
        : "Falha no modulo de atribuicao.",
    };
    if (sessionToken) await writeSessionLog(sessionToken, logPayload);
    else await writeLog(logPayload);
    return failure(
      request,
      error,
      requestCorrelationId,
      action === "capture-touchpoint",
    );
  }
});

async function routeAction(
  action: string,
  sessionToken: string,
  input: JsonObject,
  request: Request,
): Promise<unknown> {
  const storeId = action === "disconnect-connection" ||
      action === "test-connection" || action === "start-google-oauth"
    ? optionalUuid(input.store_id)
    : requiredUuid(input.store_id, "Cliente obrigatorio.");
  switch (action) {
    case "get-dashboard":
      return await serviceRpc("ma_get_dashboard", {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_start_date: optionalDate(input.start_date),
        p_end_date: optionalDate(input.end_date),
      });
    case "list-connections":
      return await serviceRpc("ma_list_connections", {
        p_session_token: sessionToken,
        p_store_id: storeId,
      });
    case "save-connection":
      return await saveConnection(sessionToken, input, request);
    case "test-connection":
      return await testConnection(sessionToken, input, request);
    case "disconnect-connection":
      return await disconnectConnection(sessionToken, input);
    case "sync-now":
      return await serviceRpc("ma_schedule_sync", {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_provider: optionalProvider(input.provider),
        p_start_date: optionalDate(input.start_date),
        p_end_date: optionalDate(input.end_date),
      });
    case "get-tracker-config":
      return await serviceRpc("ma_get_tracker_config", {
        p_session_token: sessionToken,
        p_store_id: storeId,
      });
    case "rotate-tracker-token":
      return await rotateTrackerToken(
        sessionToken,
        requiredUuid(storeId, "Cliente obrigatorio."),
        input,
        request,
      );
    case "list-sync-runs":
      return await serviceRpc("ma_list_sync_runs", {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_limit: boundedInteger(input.limit, 50, 1, 200),
        p_offset: boundedInteger(input.offset, 0, 0, 10_000_000),
      });
    case "list-journey":
      return await serviceRpc("ma_list_journey", {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_lead_id: optionalUuid(input.lead_id),
        p_start_date: optionalDate(input.start_date),
        p_end_date: optionalDate(input.end_date),
        p_limit: boundedInteger(input.limit, 50, 1, 100),
        p_offset: boundedInteger(input.offset, 0, 0, 10_000_000),
      });
    case "record-event":
      return await serviceRpc("ma_record_event", {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_lead_id: requiredUuid(input.lead_id, "Lead obrigatorio."),
        p_event_type: requiredString(
          input.event_type,
          "Tipo do evento obrigatorio.",
        ),
        p_payload: objectValue(input.payload),
      });
    case "start-google-oauth":
      return await startGoogleOAuth(sessionToken, input, request);
    default:
      throw new ApiError(
        `Acao desconhecida: ${action}.`,
        400,
        "unknown_action",
      );
  }
}

async function saveConnection(
  sessionToken: string,
  input: JsonObject,
  _request: Request,
): Promise<JsonObject> {
  requireEncryptionKey();
  const basePayload = objectValue(input.connection || input.payload);
  const payload = {
    ...basePayload,
    ...objectValue(basePayload.credentials),
    ...objectValue(input.credentials),
    ...input,
  };
  delete payload.action;
  delete payload.credentials;
  delete payload.connection;
  delete payload.payload;
  payload.name = optionalString(payload.name || payload.connection_name) ||
    undefined;
  payload.api_version = optionalString(
    payload.api_version || objectValue(payload.public_config).api_version,
  ) || undefined;
  const saved = await serviceRpc<JsonObject>("ma_service_save_connection", {
    p_session_token: sessionToken,
    p_payload: payload,
    p_encryption_key: encryptionKey,
  });

  let trackerCredentials: unknown = null;
  const storeId = requiredUuid(saved.store_id, "Cliente obrigatorio.");
  const tracker = await serviceRpc<JsonObject>("ma_get_tracker_config", {
    p_session_token: sessionToken,
    p_store_id: storeId,
  });
  const sources = Array.isArray(tracker.sources) ? tracker.sources : [];
  if (!sources.length) {
    const suppliedOrigins = stringArray(input.tracking_allowed_origins, 20);
    if (suppliedOrigins.length) {
      trackerCredentials = await serviceRpc("ma_rotate_tracker_token", {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_source_id: null,
        p_name: "Site principal",
        p_allowed_origins: suppliedOrigins,
      });
    }
  }
  return {
    ...saved,
    ...(trackerCredentials ? { tracker_credentials: trackerCredentials } : {}),
  };
}

async function rotateTrackerToken(
  sessionToken: string,
  storeId: string,
  input: JsonObject,
  _request: Request,
): Promise<unknown> {
  let sourceId = optionalUuid(input.source_id);
  let origins = stringArray(input.allowed_origins, 20);
  if (!sourceId || !origins.length) {
    const config = await serviceRpc<JsonObject>("ma_get_tracker_config", {
      p_session_token: sessionToken,
      p_store_id: storeId,
    });
    const first = Array.isArray(config.sources)
      ? objectValue(config.sources[0])
      : {};
    sourceId ||= optionalUuid(first.id);
    if (!origins.length) origins = stringArray(first.allowed_origins, 20);
  }
  if (!origins.length) {
    throw new ApiError(
      "Informe ao menos um dominio autorizado para o rastreador.",
      400,
      "tracker_origin_required",
    );
  }
  return await serviceRpc("ma_rotate_tracker_token", {
    p_session_token: sessionToken,
    p_store_id: storeId,
    p_source_id: sourceId,
    p_name: optionalString(input.name) || "Site principal",
    p_allowed_origins: origins,
  });
}

async function testConnection(
  sessionToken: string,
  input: JsonObject,
  request: Request,
): Promise<JsonObject> {
  requireEncryptionKey();
  // Persiste/mescla antes de validar para que o botao Testar use o token
  // acabado de digitar, inclusive em uma conexao que ja existia.
  const saved = await saveConnection(sessionToken, input, request);
  const connectionId = requiredUuid(
    saved.id,
    "Nao foi possivel salvar a conexao.",
  );
  const runtime = await serviceRpc<MarketingConnectionRuntime>(
    "ma_service_connection_runtime",
    {
      p_session_token: sessionToken,
      p_connection_id: connectionId,
      p_encryption_key: encryptionKey,
      p_configuration_write: true,
    },
  );
  await serviceRpc("ma_service_set_connection_status", {
    p_connection_id: connectionId,
    p_status: "validating",
    p_error_code: null,
    p_error_message: null,
    p_metadata: {},
  });
  try {
    const result = await testProviderConnection(runtime);
    if (result.token.secretsPatch) {
      await serviceRpc("ma_service_update_connection_secrets", {
        p_connection_id: connectionId,
        p_encryption_key: encryptionKey,
        p_patch: result.token.secretsPatch,
      });
    }
    await serviceRpc("ma_service_set_connection_status", {
      p_connection_id: connectionId,
      p_status: "active",
      p_error_code: null,
      p_error_message: null,
      p_metadata: {
        ...result.details,
        token_expires_at: result.token.secretsPatch?.access_token_expires_at ||
          runtime.token_expires_at || null,
      },
    });
    return {
      valid: true,
      connection_id: connectionId,
      provider: runtime.provider,
      details: result.details,
      ...(saved?.tracker_credentials
        ? { tracker_credentials: saved.tracker_credentials }
        : {}),
    };
  } catch (error) {
    await serviceRpc("ma_service_set_connection_status", {
      p_connection_id: connectionId,
      p_status: "error",
      p_error_code: error instanceof ApiError
        ? error.code
        : "validation_failed",
      p_error_message: error instanceof Error
        ? error.message
        : "Credenciais invalidas.",
      p_metadata: {},
    }).catch(() => null);
    throw error;
  }
}

async function disconnectConnection(
  sessionToken: string,
  input: JsonObject,
): Promise<JsonObject> {
  let connectionId = optionalUuid(input.connection_id);
  if (!connectionId) {
    const storeId = requiredUuid(input.store_id, "Cliente obrigatorio.");
    const provider = optionalProvider(input.provider);
    if (!provider) {
      throw new ApiError(
        "Informe a conexao ou o provedor a desconectar.",
        400,
        "connection_required",
      );
    }
    const rows = await serviceRpc<JsonObject[]>("ma_list_connections", {
      p_session_token: sessionToken,
      p_store_id: storeId,
    });
    const matched = rows.find((item) => item.provider === provider);
    connectionId = optionalUuid(matched?.id);
  }
  if (!connectionId) {
    throw new ApiError(
      "Conexao nao encontrada.",
      404,
      "connection_not_found",
    );
  }
  return {
    connection_id: connectionId,
    disconnected: await serviceRpc("ma_disconnect_connection", {
      p_session_token: sessionToken,
      p_connection_id: connectionId,
      p_purge_credentials: Boolean(input.purge_credentials),
    }),
  };
}

async function startGoogleOAuth(
  sessionToken: string,
  input: JsonObject,
  request: Request,
): Promise<JsonObject> {
  requireEncryptionKey();
  const connectionId = requiredUuid(
    input.connection_id,
    "Salve primeiro a conexao Google.",
  );
  const runtime = await serviceRpc<MarketingConnectionRuntime>(
    "ma_service_connection_runtime",
    {
      p_session_token: sessionToken,
      p_connection_id: connectionId,
      p_encryption_key: encryptionKey,
      p_configuration_write: true,
    },
  );
  if (runtime.provider !== "google") {
    throw new ApiError(
      "OAuth esta disponivel somente para Google Ads.",
      400,
      "google_connection_required",
    );
  }
  const clientId = requiredString(
    runtime.secrets.client_id,
    "Client ID OAuth do Google ausente.",
  );
  const redirectAfter = validateRedirectAfter(
    requiredString(
      input.redirect_after,
      "URL de retorno da aplicacao obrigatoria.",
    ),
    request.headers.get("origin") || "",
  );
  const state = randomToken(32);
  const stateHash = await sha256Hex(state);
  const callbackUrl = `${supabaseFunctionUrl("marketing-api")}?oauth=google`;
  await serviceRpc("ma_service_create_oauth_state", {
    p_session_token: sessionToken,
    p_connection_id: connectionId,
    p_state_hash: stateHash,
    p_redirect_after: redirectAfter,
  });
  return {
    authorization_url: buildGoogleAuthorizationUrl({
      clientId,
      redirectUri: callbackUrl,
      state,
    }),
    callback_url: callbackUrl,
    expires_in_seconds: 600,
  };
}

async function googleOAuthCallback(
  request: Request,
  url: URL,
  requestCorrelationId: string,
): Promise<Response> {
  let redirectAfter = "";
  let connectionId = "";
  try {
    requireEncryptionKey();
    const state = requiredString(
      url.searchParams.get("state"),
      "Estado OAuth ausente.",
    );
    const stateData = await serviceRpc<JsonObject>(
      "ma_service_consume_oauth_state",
      { p_state_hash: await sha256Hex(state) },
    );
    redirectAfter = requiredString(
      stateData.redirect_after,
      "Retorno OAuth invalido.",
    );
    connectionId = requiredUuid(
      stateData.connection_id,
      "Conexao OAuth invalida.",
    );
    const providerError = url.searchParams.get("error");
    if (providerError) {
      throw new ApiError(
        url.searchParams.get("error_description") ||
          "A autorizacao foi cancelada no Google.",
        400,
        `google_oauth_${providerError}`,
      );
    }
    const runtime = await serviceRpc<MarketingConnectionRuntime>(
      "ma_service_connection_runtime_by_id",
      {
        p_connection_id: connectionId,
        p_encryption_key: encryptionKey,
      },
    );
    const callbackUrl = `${supabaseFunctionUrl("marketing-api")}?oauth=google`;
    const patch = await exchangeGoogleAuthorizationCode({
      code: requiredString(
        url.searchParams.get("code"),
        "Codigo OAuth ausente.",
      ),
      clientId: requiredString(
        runtime.secrets.client_id,
        "Client ID OAuth ausente.",
      ),
      clientSecret: requiredString(
        runtime.secrets.client_secret,
        "Client Secret OAuth ausente.",
      ),
      redirectUri: callbackUrl,
    });
    await serviceRpc("ma_service_update_connection_secrets", {
      p_connection_id: connectionId,
      p_encryption_key: encryptionKey,
      p_patch: patch,
    });
    const updatedRuntime = {
      ...runtime,
      secrets: { ...runtime.secrets, ...patch },
    };
    const test = await testProviderConnection(updatedRuntime);
    if (test.token.secretsPatch) {
      await serviceRpc("ma_service_update_connection_secrets", {
        p_connection_id: connectionId,
        p_encryption_key: encryptionKey,
        p_patch: test.token.secretsPatch,
      });
    }
    await serviceRpc("ma_service_set_connection_status", {
      p_connection_id: connectionId,
      p_status: "active",
      p_error_code: null,
      p_error_message: null,
      p_metadata: {
        ...test.details,
        token_expires_at: patch.access_token_expires_at,
      },
    });
    await writeLog({
      admin_user_id: stateData.admin_user_id,
      user_id: stateData.user_id,
      store_id: stateData.store_id,
      connection_id: connectionId,
      level: "info",
      category: "oauth",
      action: "google_oauth_callback",
      success: true,
      correlation_id: requestCorrelationId,
      message: "Google Ads conectado por OAuth.",
    });
    return Response.redirect(
      appendRedirectResult(redirectAfter, {
        marketing_oauth: "success",
        provider: "google",
        connection_id: connectionId,
      }),
      302,
    );
  } catch (error) {
    if (connectionId) {
      await serviceRpc("ma_service_set_connection_status", {
        p_connection_id: connectionId,
        p_status: "error",
        p_error_code: error instanceof ApiError
          ? error.code
          : "google_oauth_failed",
        p_error_message: error instanceof Error
          ? error.message
          : "Falha no OAuth Google.",
        p_metadata: {},
      }).catch(() => null);
    }
    await writeLog({
      connection_id: connectionId || null,
      level: "error",
      category: "oauth",
      action: "google_oauth_callback",
      success: false,
      correlation_id: requestCorrelationId,
      error_code: error instanceof ApiError
        ? error.code
        : "google_oauth_failed",
      message: error instanceof Error
        ? error.message
        : "Falha no OAuth Google.",
    });
    if (redirectAfter) {
      return Response.redirect(
        appendRedirectResult(redirectAfter, {
          marketing_oauth: "error",
          provider: "google",
          error_code: error instanceof ApiError
            ? error.code
            : "google_oauth_failed",
        }),
        302,
      );
    }
    return failure(request, error, requestCorrelationId);
  }
}

async function captureTouchpoint(
  request: Request,
  input: JsonObject,
): Promise<unknown> {
  const token = requiredString(
    input.tracking_token || input.tracker_token,
    "Token do rastreador obrigatorio.",
  );
  const payload = objectValue(input.payload || input.touchpoint || input);
  delete payload.action;
  delete payload.tracking_token;
  if (!payload.landing_page_url && payload.page_url) {
    payload.landing_page_url = payload.page_url;
  }
  if (!payload.referrer_url && payload.referrer) {
    payload.referrer_url = payload.referrer;
  }
  if (!optionalString(payload.idempotency_key)) {
    payload.idempotency_key = crypto.randomUUID();
  }
  const ip = (request.headers.get("x-forwarded-for") || "")
    .split(",")[0].trim();
  const userAgent = request.headers.get("user-agent") || "";
  const hashesEnabled = trackingPepper.length >= 32;
  return await serviceRpc("ma_service_capture_touchpoint", {
    p_tracking_token: token,
    p_origin: request.headers.get("origin") || "",
    p_payload: payload,
    p_ip_hash: hashesEnabled && ip
      ? await sha256Hex(`${trackingPepper}:ip:${ip}`)
      : null,
    p_user_agent_hash: hashesEnabled && userAgent
      ? await sha256Hex(`${trackingPepper}:ua:${userAgent}`)
      : null,
  });
}

async function parseJsonRequest(request: Request): Promise<JsonObject> {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().includes("application/json")) {
    throw new ApiError(
      "Envie Content-Type application/json.",
      415,
      "unsupported_media_type",
    );
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maxJsonBytes) {
    throw new ApiError(
      "Payload excede 1 MB.",
      413,
      "payload_too_large",
    );
  }
  try {
    return objectValue(text ? JSON.parse(text) : {});
  } catch {
    throw new ApiError("JSON invalido.", 400, "invalid_json");
  }
}

function validateRedirectAfter(value: string, requestOrigin: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ApiError("URL de retorno invalida.", 400, "invalid_redirect_url");
  }
  if (
    url.protocol !== "https:" &&
    !(url.protocol === "http:" &&
      ["localhost", "127.0.0.1"].includes(url.hostname))
  ) {
    throw new ApiError(
      "A URL de retorno deve usar HTTPS.",
      400,
      "insecure_redirect_url",
    );
  }
  const allowed = (
    Deno.env.get("MARKETING_APP_ORIGINS") ||
    Deno.env.get("MARKETING_ALLOWED_ORIGINS") ||
    requestOrigin
  ).split(",").map((item) => item.trim()).filter(Boolean);
  if (!allowed.includes(url.origin)) {
    throw new ApiError(
      "Destino de retorno OAuth nao autorizado.",
      400,
      "redirect_origin_not_allowed",
    );
  }
  return url.toString();
}

function appendRedirectResult(
  value: string,
  entries: Record<string, string>,
): string {
  const url = new URL(value);
  for (const [key, item] of Object.entries(entries)) {
    url.searchParams.set(key, item);
  }
  return url.toString();
}

function requireEncryptionKey(): void {
  if (encryptionKey.length < 32) {
    throw new ApiError(
      "MARKETING_CREDENTIALS_KEY nao configurada.",
      500,
      "credential_key_missing",
    );
  }
}

function objectValue(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? { ...(value as JsonObject) }
    : {};
}

function requiredString(value: unknown, message: string): string {
  const normalized = optionalString(value);
  if (!normalized) throw new ApiError(message, 400, "required_field_missing");
  return normalized;
}

function optionalString(value: unknown): string {
  return typeof value === "string" || typeof value === "number"
    ? String(value).trim()
    : "";
}

function requiredUuid(value: unknown, message: string): string {
  const normalized = optionalUuid(value);
  if (!normalized) throw new ApiError(message, 400, "invalid_uuid");
  return normalized;
}

function optionalUuid(value: unknown): string | null {
  const normalized = optionalString(value);
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(normalized)
    ? normalized
    : null;
}

function optionalDate(value: unknown): string | null {
  const normalized = optionalString(value);
  if (!normalized) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(normalized)) {
    throw new ApiError("Data invalida.", 400, "invalid_date");
  }
  return normalized;
}

function optionalProvider(value: unknown): string | null {
  const normalized = optionalString(value).toLowerCase();
  if (!normalized || normalized === "all") return null;
  if (!["meta", "google"].includes(normalized)) {
    throw new ApiError("Provedor invalido.", 400, "invalid_provider");
  }
  return normalized;
}

function boundedInteger(
  value: unknown,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const parsed = Number(value);
  return Math.min(
    Math.max(Number.isInteger(parsed) ? parsed : fallback, minimum),
    maximum,
  );
}

function stringArray(value: unknown, maximum: number): string[] {
  return Array.isArray(value)
    ? value.map(optionalString).filter(Boolean).slice(0, maximum)
    : [];
}

function categoryForAction(action: string): string {
  if (action.includes("connection") || action.includes("oauth")) {
    return "connection";
  }
  if (action.includes("tracker") || action.includes("touchpoint")) {
    return "tracker";
  }
  if (action.includes("sync")) return "sync";
  if (action.includes("journey") || action.includes("event")) return "journey";
  return "analytics";
}
