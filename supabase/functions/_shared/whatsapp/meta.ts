import { ApiError } from "./response.ts";
import { hmacSha256Hex } from "./crypto.ts";
import type { JsonObject, MetaErrorPayload, WhatsAppRuntime } from "./types.ts";

const graphHost = "https://graph.facebook.com";

export class MetaApiError extends ApiError {
  httpStatus: number;
  metaCode?: number;
  subcode?: number;
  retryAfterSeconds?: number;

  constructor(
    message: string,
    httpStatus: number,
    details: JsonObject,
    retryAfterSeconds?: number,
  ) {
    const metaCode = Number(details.code || 0) || undefined;
    const retryable = httpStatus === 429 || httpStatus >= 500 ||
      [1, 2, 4, 17, 32, 613].includes(metaCode || -1);
    super(
      message,
      httpStatus === 401 || httpStatus === 403 ? 401 : 502,
      "meta_api_error",
      details,
      retryable,
    );
    this.name = "MetaApiError";
    this.httpStatus = httpStatus;
    this.metaCode = metaCode;
    this.subcode = Number(details.error_subcode || 0) || undefined;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export async function graphRequest<T>(
  runtime: WhatsAppRuntime,
  path: string,
  init: RequestInit = {},
  accessToken = runtime.secrets.access_token,
): Promise<T> {
  const version = validateApiVersion(runtime.graph_api_version);
  const cleanPath = path.replace(/^\/+/, "");
  const url = new URL(`${graphHost}/${version}/${cleanPath}`);
  if (runtime.secrets.app_secret && accessToken) {
    url.searchParams.set(
      "appsecret_proof",
      await hmacSha256Hex(runtime.secrets.app_secret, accessToken),
    );
  }
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${accessToken}`);
  headers.set("Accept", "application/json");
  if (init.body && !(init.body instanceof FormData)) {
    headers.set("Content-Type", "application/json");
  }
  let response: Response;
  try {
    response = await fetch(url, {
      ...init,
      headers,
      signal: init.signal || AbortSignal.timeout(
        init.body instanceof FormData ? 120_000 : 45_000,
      ),
    });
  } catch (error) {
    const timeout = error instanceof DOMException &&
      error.name === "TimeoutError";
    throw new ApiError(
      timeout
        ? "A Meta excedeu o tempo limite da operacao."
        : "Nao foi possivel conectar a API da Meta.",
      timeout ? 504 : 503,
      timeout ? "meta_timeout" : "meta_network_error",
      undefined,
      true,
    );
  }
  const text = await response.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text.slice(0, 4000) };
  }
  if (!response.ok) {
    const envelope = data as MetaErrorPayload;
    const details = (envelope?.error || data || {}) as JsonObject;
    throw new MetaApiError(
      String(
        details.message || `A Meta recusou a chamada (${response.status}).`,
      ),
      response.status,
      {
        code: details.code,
        error_subcode: details.error_subcode,
        type: details.type,
        fbtrace_id: details.fbtrace_id,
        error_data: details.error_data,
      },
      parseRetryAfter(response.headers.get("retry-after")),
    );
  }
  return data as T;
}

export async function validateConnection(
  runtime: WhatsAppRuntime,
): Promise<JsonObject> {
  requireAppCredentials(runtime);
  const appAccessToken = `${runtime.app_id}|${runtime.secrets.app_secret}`;
  const debugEnvelope = await graphRequest<{ data?: JsonObject }>(
    runtime,
    `debug_token?input_token=${
      encodeURIComponent(runtime.secrets.access_token)
    }`,
    {},
    appAccessToken,
  );
  const debug = asObject(debugEnvelope.data);
  if (!debug.is_valid) {
    throw new ApiError(
      "O Access Token foi recusado ou esta expirado.",
      401,
      "access_token_invalid",
      { validation_step: "debug_token" },
    );
  }
  if (String(debug.app_id || "") !== String(runtime.app_id || "")) {
    throw new ApiError(
      "O Access Token pertence a outro App ID.",
      400,
      "access_token_app_mismatch",
      { validation_step: "debug_token", returned_app_id: debug.app_id },
    );
  }
  const scopes = collectScopes(debug);
  const requiredScopes = [
    "whatsapp_business_management",
    "whatsapp_business_messaging",
  ];
  const missingScopes = requiredScopes.filter((scope) =>
    !scopes.includes(scope)
  );
  if (missingScopes.length) {
    throw new ApiError(
      `Access Token sem permissoes obrigatorias: ${missingScopes.join(", ")}.`,
      403,
      "whatsapp_scopes_missing",
      { validation_step: "debug_token", missing_scopes: missingScopes },
    );
  }

  const wabaFields = [
    "id",
    "name",
    "currency",
    "timezone_id",
    "message_template_namespace",
    "account_review_status",
  ].join(",");
  const waba = await graphRequest<JsonObject>(
    runtime,
    `${encodeURIComponent(runtime.business_account_id)}?fields=${
      encodeURIComponent(wabaFields)
    }`,
  );
  if (String(waba.id || "") !== runtime.business_account_id) {
    throw new ApiError(
      "Business Account ID nao corresponde a conta retornada pela Meta.",
      400,
      "waba_mismatch",
      { validation_step: "business_account" },
    );
  }
  const phoneFields = [
    "id",
    "display_phone_number",
    "verified_name",
    "quality_rating",
    "platform_type",
    "throughput",
    "whatsapp_business_manager_messaging_limit",
    "code_verification_status",
    "name_status",
    "status",
  ].join(",");
  const phones = await listGraphCollection(
    runtime,
    `${
      encodeURIComponent(runtime.business_account_id)
    }/phone_numbers?limit=100&fields=${encodeURIComponent(phoneFields)}`,
    20,
  );
  const phone = phones.find((item) =>
    String(item.id || "") === runtime.phone_number_id
  );
  if (!phone) {
    throw new ApiError(
      "O Phone Number ID nao pertence ao Business Account ID informado.",
      400,
      "phone_number_not_in_waba",
      { validation_step: "phone_numbers" },
    );
  }
  const providerStatus = String(phone.status || "").toUpperCase();
  if (providerStatus !== "CONNECTED") {
    throw new ApiError(
      `O numero nao esta CONNECTED na Meta (status: ${
        providerStatus || "nao informado"
      }).`,
      409,
      "phone_number_not_connected",
      {
        validation_step: "phone_numbers",
        provider_status: providerStatus || null,
      },
    );
  }
  const configuredPhone = digits(runtime.display_phone_number || "");
  const returnedPhone = digits(String(phone.display_phone_number || ""));
  if (configuredPhone && returnedPhone && configuredPhone !== returnedPhone) {
    throw new ApiError(
      "O numero exibido nao corresponde ao Phone Number ID informado.",
      400,
      "display_phone_mismatch",
      {
        validation_step: "phone_numbers",
        returned_display_phone_number: phone.display_phone_number,
      },
    );
  }
  return {
    token: {
      app_id: debug.app_id,
      type: debug.type,
      is_valid: true,
      scopes,
      expires_at: epochToIso(debug.expires_at),
      data_access_expires_at: epochToIso(debug.data_access_expires_at),
    },
    business_account: pick(waba, [
      "id",
      "name",
      "currency",
      "timezone_id",
      "message_template_namespace",
      "account_review_status",
    ]),
    phone: pick(phone, [
      "id",
      "display_phone_number",
      "verified_name",
      "quality_rating",
      "platform_type",
      "throughput",
      "whatsapp_business_manager_messaging_limit",
      "code_verification_status",
      "name_status",
      "status",
    ]),
  };
}

export async function registerWebhook(
  runtime: WhatsAppRuntime,
): Promise<JsonObject> {
  requireAppCredentials(runtime);
  const callbackUrl = String(
    runtime.webhook_url || Deno.env.get("WHATSAPP_PUBLIC_WEBHOOK_URL") || "",
  ).trim();
  if (!/^https:\/\//i.test(callbackUrl)) {
    throw new ApiError(
      "Informe uma Webhook URL HTTPS valida.",
      400,
      "webhook_url_invalid",
    );
  }
  if (!runtime.secrets.verify_token) {
    throw new ApiError("Verify Token ausente.", 400, "verify_token_required");
  }
  const appAccessToken = `${runtime.app_id}|${runtime.secrets.app_secret}`;
  let callbackSubscription: JsonObject;
  try {
    callbackSubscription = await graphRequest<JsonObject>(
      runtime,
      `${encodeURIComponent(runtime.app_id || "")}/subscriptions`,
      {
        method: "POST",
        body: JSON.stringify({
          object: "whatsapp_business_account",
          callback_url: callbackUrl,
          verify_token: runtime.secrets.verify_token,
          fields:
            "messages,message_template_status_update,message_template_quality_update",
          include_values: true,
        }),
      },
      appAccessToken,
    );
  } catch (error) {
    throw registrationError("app_callback_subscription", error);
  }
  let wabaSubscription: JsonObject;
  try {
    wabaSubscription = await graphRequest<JsonObject>(
      runtime,
      `${encodeURIComponent(runtime.business_account_id)}/subscribed_apps`,
      { method: "POST", body: JSON.stringify({}) },
    );
  } catch (error) {
    throw registrationError("waba_subscribed_apps", error, {
      callback_subscription_succeeded: true,
    });
  }
  return {
    callback_subscription: callbackSubscription,
    waba_subscription: wabaSubscription,
    callback_url: callbackUrl,
    fields: [
      "messages",
      "message_template_status_update",
      "message_template_quality_update",
    ],
  };
}

export async function sendMessage(
  runtime: WhatsAppRuntime,
  payload: JsonObject,
): Promise<JsonObject> {
  return await graphRequest<JsonObject>(
    runtime,
    `${encodeURIComponent(runtime.phone_number_id)}/messages`,
    { method: "POST", body: JSON.stringify(payload) },
  );
}

export async function listTemplates(
  runtime: WhatsAppRuntime,
): Promise<JsonObject[]> {
  const all: JsonObject[] = [];
  let path = `${
    encodeURIComponent(runtime.business_account_id)
  }/message_templates?limit=100&fields=${
    encodeURIComponent(
      "id,name,status,category,language,parameter_format,components,quality_score,rejected_reason",
    )
  }`;
  for (let page = 0; page < 50 && path; page += 1) {
    const result = await graphRequest<
      { data?: JsonObject[]; paging?: { next?: string } }
    >(runtime, path);
    all.push(...(Array.isArray(result.data) ? result.data : []));
    const next = result.paging?.next || "";
    if (!next) break;
    path = safePaginationPath(next);
  }
  return all;
}

export async function createTemplate(
  runtime: WhatsAppRuntime,
  template: JsonObject,
): Promise<JsonObject> {
  const allowed = {
    name: template.name,
    language: template.language,
    category: template.category,
    components: template.components,
    ...(template.parameter_format
      ? { parameter_format: template.parameter_format }
      : {}),
  };
  return await graphRequest<JsonObject>(
    runtime,
    `${encodeURIComponent(runtime.business_account_id)}/message_templates`,
    { method: "POST", body: JSON.stringify(allowed) },
  );
}

export async function updateTemplate(
  runtime: WhatsAppRuntime,
  providerTemplateId: string,
  template: JsonObject,
): Promise<JsonObject> {
  if (!providerTemplateId.trim()) {
    throw new ApiError(
      "Template da Meta sem identificador para edicao.",
      400,
      "provider_template_id_required",
    );
  }
  const allowed: JsonObject = {};
  if (template.category) allowed.category = template.category;
  if (Array.isArray(template.components)) {
    allowed.components = template.components;
  }
  if (!Object.keys(allowed).length) {
    throw new ApiError(
      "Informe categoria ou componentes para editar o template.",
      400,
      "template_changes_required",
    );
  }
  return await graphRequest<JsonObject>(
    runtime,
    encodeURIComponent(providerTemplateId),
    { method: "POST", body: JSON.stringify(allowed) },
  );
}

export async function uploadMedia(
  runtime: WhatsAppRuntime,
  file: File,
): Promise<JsonObject> {
  const form = new FormData();
  form.set("messaging_product", "whatsapp");
  form.set("type", file.type || "application/octet-stream");
  form.set("file", file, file.name || "arquivo");
  return await graphRequest<JsonObject>(
    runtime,
    `${encodeURIComponent(runtime.phone_number_id)}/media`,
    { method: "POST", body: form },
  );
}

export async function downloadMedia(
  runtime: WhatsAppRuntime,
  providerMediaId: string,
): Promise<{
  body: ReadableStream<Uint8Array> | null;
  mimeType: string;
  contentLength: string | null;
}> {
  const metadata = await graphRequest<JsonObject>(
    runtime,
    encodeURIComponent(providerMediaId),
  );
  const temporaryUrl = String(metadata.url || "");
  if (!temporaryUrl.startsWith("https://")) {
    throw new ApiError(
      "A Meta nao devolveu uma URL temporaria valida para a midia.",
      502,
      "media_url_missing",
    );
  }
  let response: Response;
  try {
    response = await fetch(temporaryUrl, {
      headers: { Authorization: `Bearer ${runtime.secrets.access_token}` },
      signal: AbortSignal.timeout(120_000),
    });
  } catch (error) {
    const timeout = error instanceof DOMException &&
      error.name === "TimeoutError";
    throw new ApiError(
      timeout
        ? "A Meta excedeu o tempo limite ao baixar a midia."
        : "Nao foi possivel baixar a midia na Meta.",
      timeout ? 504 : 503,
      timeout ? "media_download_timeout" : "media_download_network_error",
      undefined,
      true,
    );
  }
  if (!response.ok) {
    throw new ApiError(
      `A Meta recusou o download da midia (${response.status}).`,
      502,
      "media_download_failed",
      { http_status: response.status },
      response.status === 429 || response.status >= 500,
    );
  }
  const declared = Number(
    response.headers.get("content-length") || metadata.file_size || 0,
  );
  const maxBytes = 100 * 1024 * 1024;
  if (declared > maxBytes) {
    response.body?.cancel().catch(() => null);
    throw new ApiError("Midia recebida excede 100 MB.", 413, "media_too_large");
  }
  return {
    body: limitReadableStream(response.body, maxBytes),
    mimeType: String(
      response.headers.get("content-type") || metadata.mime_type ||
        "application/octet-stream",
    ),
    contentLength: response.headers.get("content-length"),
  };
}

function limitReadableStream(
  source: ReadableStream<Uint8Array> | null,
  maxBytes: number,
): ReadableStream<Uint8Array> | null {
  if (!source) return null;
  let received = 0;
  return source.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        received += chunk.byteLength;
        if (received > maxBytes) {
          controller.error(
            new ApiError(
              "Midia recebida excede 100 MB.",
              413,
              "media_too_large",
            ),
          );
          return;
        }
        controller.enqueue(chunk);
      },
    }),
  );
}

export function buildMessagePayload(input: JsonObject): JsonObject {
  const to = String(input.to || "").replace(/\D/g, "");
  const type = String(input.type || "text");
  const allowedTypes = new Set([
    "audio",
    "document",
    "image",
    "sticker",
    "template",
    "text",
    "video",
  ]);
  if (!to || to.length < 7 || to.length > 15) {
    throw new ApiError(
      "Destinatario do WhatsApp invalido.",
      400,
      "invalid_recipient",
    );
  }
  if (!allowedTypes.has(type)) {
    throw new ApiError(
      "Tipo de mensagem ainda nao suportado por esta integracao.",
      400,
      "unsupported_message_type",
    );
  }
  const base: JsonObject = {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to,
    type,
  };
  if (type === "text") {
    const body = String(input.text || "").trim();
    if (!body) throw new ApiError("Digite a mensagem.", 400, "empty_message");
    base.text = {
      preview_url: Boolean(input.preview_url),
      body: body.slice(0, 4096),
    };
  } else if (type === "template") {
    const name = String(input.template_name || "").trim();
    const language = String(input.template_language || "pt_BR").trim();
    if (!name) {
      throw new ApiError(
        "Escolha um template aprovado.",
        400,
        "template_required",
      );
    }
    base.template = {
      name,
      language: { code: language },
      ...(Array.isArray(input.template_parameters)
        ? { components: input.template_parameters }
        : {}),
    };
  } else {
    const content = input[type];
    if (!content || typeof content !== "object") {
      throw new ApiError(
        `Conteudo de ${type} ausente.`,
        400,
        "media_content_required",
      );
    }
    base[type] = content;
  }
  if (input.reply_to_provider_message_id) {
    base.context = { message_id: String(input.reply_to_provider_message_id) };
  }
  return base;
}

export function runtimeFromUnsaved(payload: JsonObject): WhatsAppRuntime {
  const secrets =
    (payload.secrets && typeof payload.secrets === "object"
      ? payload.secrets
      : payload) as JsonObject;
  const runtime: WhatsAppRuntime = {
    id: String(payload.connection_id || "unsaved"),
    admin_user_id: "",
    store_id: String(payload.store_id || ""),
    name: String(payload.name || "Nova conexao"),
    phone_number_id: String(payload.phone_number_id || "").trim(),
    business_account_id: String(payload.business_account_id || "").trim(),
    display_phone_number: String(payload.display_phone_number || "").trim(),
    app_id: String(payload.app_id || "").trim(),
    graph_api_version: validateApiVersion(
      String(payload.graph_api_version || "v26.0"),
    ),
    status: "draft",
    webhook_url: String(payload.webhook_url || "").trim(),
    secrets: {
      access_token: String(secrets.access_token || "").trim(),
      app_secret: String(secrets.app_secret || "").trim(),
      verify_token: String(secrets.verify_token || "").trim(),
    },
  };
  if (
    !runtime.phone_number_id || !runtime.business_account_id ||
    !runtime.secrets.access_token
  ) {
    throw new ApiError(
      "Phone Number ID, Business Account ID e Access Token sao obrigatorios.",
      400,
      "credentials_incomplete",
    );
  }
  return runtime;
}

async function listGraphCollection(
  runtime: WhatsAppRuntime,
  initialPath: string,
  maxPages: number,
): Promise<JsonObject[]> {
  const result: JsonObject[] = [];
  let path = initialPath;
  for (let page = 0; page < maxPages && path; page += 1) {
    const envelope = await graphRequest<{
      data?: JsonObject[];
      paging?: { next?: string };
    }>(runtime, path);
    result.push(...(Array.isArray(envelope.data) ? envelope.data : []));
    const next = envelope.paging?.next || "";
    if (!next) break;
    path = safePaginationPath(next);
  }
  return result;
}

function requireAppCredentials(runtime: WhatsAppRuntime): void {
  if (!runtime.app_id || !runtime.secrets.app_secret) {
    throw new ApiError(
      "App ID e App Secret sao obrigatorios para validar e registrar o webhook.",
      400,
      "app_credentials_required",
    );
  }
}

function collectScopes(debug: JsonObject): string[] {
  const scopes = new Set<string>();
  if (Array.isArray(debug.scopes)) {
    for (const scope of debug.scopes) {
      if (typeof scope === "string") scopes.add(scope);
    }
  }
  if (Array.isArray(debug.granular_scopes)) {
    for (const item of debug.granular_scopes) {
      const scope = asObject(item).scope;
      if (typeof scope === "string") scopes.add(scope);
    }
  }
  return [...scopes].sort();
}

function registrationError(
  step: string,
  error: unknown,
  extra: JsonObject = {},
): ApiError {
  const source = error instanceof ApiError ? error : null;
  return new ApiError(
    `Falha na etapa ${step} do registro do webhook: ${
      error instanceof Error ? error.message : "erro desconhecido"
    }`,
    source?.status || 502,
    `webhook_${step}_failed`,
    {
      step,
      ...extra,
      provider_error: source?.details,
    },
    source?.retryable || false,
  );
}

function epochToIso(value: unknown): string | null {
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds > 0
    ? new Date(seconds * 1000).toISOString()
    : null;
}

function pick(source: JsonObject, keys: string[]): JsonObject {
  const result: JsonObject = {};
  for (const key of keys) {
    if (source[key] !== undefined) result[key] = source[key];
  }
  return result;
}

function digits(value: string): string {
  return value.replace(/\D/g, "");
}

function asObject(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

function validateApiVersion(value: string): string {
  return /^v[0-9]{2,3}\.[0-9]+$/.test(value) ? value : "v26.0";
}

function safePaginationPath(next: string): string {
  const parsed = new URL(next);
  parsed.searchParams.delete("access_token");
  parsed.searchParams.delete("appsecret_proof");
  return parsed.pathname.replace(/^\/v[0-9.]+\//, "") + parsed.search;
}

function parseRetryAfter(value: string | null): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds;
  const at = Date.parse(value);
  return Number.isFinite(at)
    ? Math.max(0, Math.ceil((at - Date.now()) / 1000))
    : undefined;
}
