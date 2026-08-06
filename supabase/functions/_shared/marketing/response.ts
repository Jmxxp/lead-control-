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

function configuredOrigins(): string[] {
  return (Deno.env.get("MARKETING_ALLOWED_ORIGINS") || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

export function requestOriginAllowed(request: Request): boolean {
  const origin = request.headers.get("origin") || "";
  const configured = configuredOrigins();
  return !configured.length || !origin || configured.includes(origin);
}

function responseOrigin(request: Request, publicOrigin = false): string {
  const origin = request.headers.get("origin") || "";
  const configured = configuredOrigins();
  if (publicOrigin) return origin || "*";
  if (!configured.length) return origin || "*";
  if (origin && configured.includes(origin)) return origin;
  return configured[0];
}

export function corsHeaders(
  request: Request,
  publicOrigin = false,
): HeadersInit {
  return {
    "Access-Control-Allow-Origin": responseOrigin(request, publicOrigin),
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-app-session, x-correlation-id, x-worker-secret",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

export function correlationId(request: Request): string {
  const supplied = request.headers.get("x-correlation-id")?.trim();
  return supplied && supplied.length <= 160 ? supplied : crypto.randomUUID();
}

export function ok(
  request: Request,
  data: unknown,
  correlation: string,
  status = 200,
  publicOrigin = false,
): Response {
  return jsonResponse(
    request,
    { ok: true, data, correlation_id: correlation },
    status,
    correlation,
    publicOrigin,
  );
}

export function failure(
  request: Request,
  error: unknown,
  correlation: string,
  publicOrigin = false,
): Response {
  const normalized = error instanceof ApiError ? error : new ApiError(
    error instanceof Error
      ? error.message
      : "Falha interna no modulo de atribuicao.",
  );
  const payload: JsonObject = {
    ok: false,
    error: {
      code: normalized.code,
      message: normalized.message,
      retryable: normalized.retryable,
      ...(normalized.details === undefined
        ? {}
        : { details: normalized.details }),
    },
    correlation_id: correlation,
  };
  return jsonResponse(
    request,
    payload,
    normalized.status,
    correlation,
    publicOrigin,
  );
}

export function jsonResponse(
  request: Request,
  payload: unknown,
  status = 200,
  correlation?: string,
  publicOrigin = false,
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders(request, publicOrigin),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...(correlation ? { "X-Correlation-Id": correlation } : {}),
    },
  });
}
