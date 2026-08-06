import type { JsonObject } from "./types.ts";

export class ApiError extends Error {
  status: number;
  code: string;
  details?: unknown;
  retryable: boolean;

  constructor(
    message: string,
    status = 500,
    code = "internal_error",
    details?: unknown,
    retryable = false,
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
    this.retryable = retryable;
  }
}

function allowedOrigin(request: Request): string {
  const origin = request.headers.get("origin") || "";
  const configured = (Deno.env.get("WHATSAPP_ALLOWED_ORIGINS") || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (!configured.length) return "*";
  if (origin && configured.includes(origin)) return origin;
  return configured[0];
}

export function corsHeaders(request: Request): HeadersInit {
  return {
    "Access-Control-Allow-Origin": allowedOrigin(request),
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-app-session, x-correlation-id, x-worker-secret",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

export function jsonResponse(
  request: Request,
  payload: unknown,
  status = 200,
  correlationId?: string,
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders(request),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...(correlationId ? { "X-Correlation-Id": correlationId } : {}),
    },
  });
}

export function ok(
  request: Request,
  data: unknown,
  correlationId: string,
  status = 200,
): Response {
  return jsonResponse(
    request,
    { ok: true, data, correlation_id: correlationId },
    status,
    correlationId,
  );
}

export function failure(
  request: Request,
  error: unknown,
  correlationId: string,
): Response {
  const normalized = error instanceof ApiError ? error : new ApiError(
    error instanceof Error
      ? error.message
      : "Falha interna no modulo WhatsApp.",
  );
  const body: JsonObject = {
    ok: false,
    error: {
      code: normalized.code,
      message: normalized.message,
      retryable: normalized.retryable,
      ...(normalized.details === undefined
        ? {}
        : { details: normalized.details }),
    },
    correlation_id: correlationId,
  };
  return jsonResponse(request, body, normalized.status, correlationId);
}

export function correlationId(request: Request): string {
  const supplied = request.headers.get("x-correlation-id")?.trim();
  return supplied && supplied.length <= 160 ? supplied : crypto.randomUUID();
}
