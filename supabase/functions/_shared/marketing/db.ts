import { redactSecrets } from "./crypto.ts";
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
        "X-Client-Info": "lead-control-marketing/1.0",
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
      { rpc: name, hint: record.hint, database_code: record.code },
      response.status >= 500,
    );
  }
  return data as T;
}

export async function writeLog(payload: JsonObject): Promise<void> {
  await serviceRpc("ma_service_log", {
    p_payload: redactSecrets(structuredClone(payload)) as JsonObject,
  }).catch(() => null);
}

export async function writeSessionLog(
  sessionToken: string,
  payload: JsonObject,
): Promise<void> {
  const sanitized = redactSecrets(structuredClone(payload)) as JsonObject;
  delete sanitized.admin_user_id;
  delete sanitized.user_id;
  const written = await serviceRpc("ma_service_log_session", {
    p_session_token: sessionToken,
    p_payload: sanitized,
  }).then(() => true).catch(() => false);
  if (!written) {
    delete sanitized.store_id;
    delete sanitized.connection_id;
    await writeLog(sanitized);
  }
}

export function supabaseFunctionUrl(functionName: string): string {
  requireServerConfiguration();
  return `${supabaseUrl}/functions/v1/${encodeURIComponent(functionName)}`;
}
