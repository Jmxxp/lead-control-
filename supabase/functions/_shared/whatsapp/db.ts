import { ApiError } from "./response.ts";
import type { JsonObject } from "./types.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

export function requireServerConfiguration(): void {
  if (!supabaseUrl || !serviceRoleKey) {
    throw new ApiError(
      "Edge Function sem SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY.",
      500,
      "server_configuration_missing",
    );
  }
}

export async function serviceRpc<T>(
  name: string,
  payload: JsonObject = {},
): Promise<T> {
  requireServerConfiguration();
  const response = await fetch(
    `${supabaseUrl}/rest/v1/rpc/${encodeURIComponent(name)}`,
    {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
        "X-Client-Info": "lead-control-whatsapp/1.0",
      },
      body: JSON.stringify(payload),
    },
  );
  const raw = await response.text();
  let data: unknown = null;
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch {
      data = raw;
    }
  }
  if (!response.ok) {
    const record = data && typeof data === "object" ? data as JsonObject : {};
    const message = String(
      record.message || record.error || raw || "Falha no banco de dados.",
    );
    const authenticationError = /sess[aã]o|token|permiss[aã]o|autoriz/i.test(
      message,
    );
    throw new ApiError(
      message,
      authenticationError ? 401 : response.status >= 500 ? 500 : 400,
      authenticationError
        ? "session_or_permission_error"
        : "database_rpc_error",
      { rpc: name, hint: record.hint, code: record.code },
      response.status >= 500,
    );
  }
  return data as T;
}

export async function writeLog(payload: JsonObject): Promise<void> {
  const sanitized = sanitizeLogPayload(payload);
  await serviceRpc("wa_service_log", { p_payload: sanitized }).catch(() =>
    null
  );
}

/**
 * Registra uma acao iniciada por usuario sem confiar em identificadores de
 * tenant enviados pelo cliente. A RPC resolve administrador, usuario e escopo
 * a partir da sessao e descarta qualquer tentativa de forjar esse contexto.
 */
export async function writeSessionLog(
  sessionToken: string,
  payload: JsonObject,
): Promise<void> {
  const sanitized = sanitizeLogPayload(payload);
  delete sanitized.admin_user_id;
  delete sanitized.user_id;
  const sessionLogged = await serviceRpc("wa_service_log_session", {
    p_session_token: sessionToken,
    p_payload: sanitized,
  }).then(() => true).catch(() => false);
  // Sessao invalida ou migracao ainda nao aplicada: preserva ao menos o log
  // global, mas remove o contexto que somente a RPC autenticada pode validar.
  if (!sessionLogged) {
    const globalPayload = { ...sanitized };
    delete globalPayload.store_id;
    delete globalPayload.connection_id;
    await serviceRpc("wa_service_log", { p_payload: globalPayload }).catch(
      () => null,
    );
  }
}

function sanitizeLogPayload(payload: JsonObject): JsonObject {
  return redactSecrets(structuredClone(payload)) as JsonObject;
}

function redactSecrets(value: unknown, depth = 0): unknown {
  if (depth > 12) return "[TRUNCATED]";
  if (Array.isArray(value)) {
    return value.map((item) => redactSecrets(item, depth + 1));
  }
  if (!value || typeof value !== "object") return value;
  const result: JsonObject = {};
  for (const [key, item] of Object.entries(value as JsonObject)) {
    if (
      /^(?:access[_-]?token|app[_-]?secret|verify[_-]?token|authorization|token)$/i
        .test(key)
    ) {
      result[key] = "[REDACTED]";
    } else {
      result[key] = redactSecrets(item, depth + 1);
    }
  }
  return result;
}
