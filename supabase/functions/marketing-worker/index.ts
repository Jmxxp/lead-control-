import { constantTimeEqual } from "../_shared/marketing/crypto.ts";
import { serviceRpc, writeLog } from "../_shared/marketing/db.ts";
import {
  ensureGoogleAccessToken,
  ProviderError,
  retrieveGoogleConversionStatus,
  sendOfflineConversion,
  syncProviderMetrics,
} from "../_shared/marketing/providers.ts";
import {
  ApiError,
  correlationId,
  corsHeaders,
  failure,
  ok,
} from "../_shared/marketing/response.ts";
import type {
  JsonObject,
  MarketingConnectionRuntime,
  MarketingConversionDiagnosticJob,
  MarketingConversionJob,
  MarketingSyncJob,
} from "../_shared/marketing/types.ts";

const encryptionKey = Deno.env.get("MARKETING_CREDENTIALS_KEY") || "";
const workerSecret = Deno.env.get("MARKETING_WORKER_SECRET") || "";
const defaultSyncLimit = boundedInteger(
  Deno.env.get("MARKETING_SYNC_BATCH_SIZE"),
  1,
  1,
  1,
);
const defaultConversionLimit = boundedInteger(
  Deno.env.get("MARKETING_CONVERSION_BATCH_SIZE"),
  5,
  1,
  5,
);
const defaultDiagnosticLimit = boundedInteger(
  Deno.env.get("MARKETING_DIAGNOSTIC_BATCH_SIZE"),
  5,
  1,
  5,
);

Deno.serve(async (request) => {
  const requestCorrelationId = correlationId(request);
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  const startedAt = Date.now();
  try {
    if (request.method !== "POST") {
      throw new ApiError("Metodo nao permitido.", 405, "method_not_allowed");
    }
    authorizeWorker(request);
    requireConfiguration();
    const body = await request.json().catch(() => ({}));
    const syncLimit = boundedInteger(
      body?.sync_limit,
      defaultSyncLimit,
      1,
      1,
    );
    const conversionLimit = boundedInteger(
      body?.conversion_limit,
      defaultConversionLimit,
      1,
      5,
    );
    const diagnosticLimit = boundedInteger(
      body?.diagnostic_limit,
      defaultDiagnosticLimit,
      1,
      5,
    );
    const workerId = `marketing:${requestCorrelationId}`;
    const runtimes = new Map<string, MarketingConnectionRuntime>();

    const dueSyncsScheduled = await serviceRpc<number>(
      "ma_service_schedule_due_syncs",
      {},
    );

    const syncJobs = await serviceRpc<MarketingSyncJob[]>(
      "ma_service_claim_sync",
      { p_worker_id: workerId, p_limit: syncLimit },
    );
    const syncResults: JsonObject[] = [];
    for (const job of syncJobs) {
      syncResults.push(
        await processSyncJob(job, workerId, runtimes, requestCorrelationId),
      );
    }

    const conversionJobs = await serviceRpc<MarketingConversionJob[]>(
      "ma_service_claim_conversions",
      { p_worker_id: workerId, p_limit: conversionLimit },
    );
    const conversionResults: JsonObject[] = [];
    for (const job of conversionJobs) {
      conversionResults.push(
        await processConversionJob(
          job,
          workerId,
          runtimes,
          requestCorrelationId,
        ),
      );
    }

    const diagnosticJobs = await serviceRpc<
      MarketingConversionDiagnosticJob[]
    >(
      "ma_service_claim_conversion_diagnostics",
      { p_worker_id: workerId, p_limit: diagnosticLimit },
    );
    const diagnosticResults: JsonObject[] = [];
    for (const job of diagnosticJobs) {
      diagnosticResults.push(
        await processConversionDiagnostic(
          job,
          workerId,
          runtimes,
          requestCorrelationId,
        ),
      );
    }

    const retention = await serviceRpc<JsonObject>(
      "ma_service_run_retention",
      {},
    ).catch(() => ({ executed: false, reason: "retention_check_failed" }));
    await writeLog({
      level: "info",
      category: "worker",
      action: "worker_batch",
      success: true,
      correlation_id: requestCorrelationId,
      latency_ms: Date.now() - startedAt,
      message: "Lote do worker de marketing concluido.",
      metadata: {
        sync_claimed: syncJobs.length,
        conversions_claimed: conversionJobs.length,
        diagnostics_claimed: diagnosticJobs.length,
      },
    });
    return ok(request, {
      sync: summarize(syncResults),
      due_syncs_scheduled: dueSyncsScheduled,
      conversions: summarize(conversionResults),
      conversion_diagnostics: summarize(diagnosticResults),
      sync_results: syncResults,
      conversion_results: conversionResults,
      conversion_diagnostic_results: diagnosticResults,
      retention,
    }, requestCorrelationId);
  } catch (error) {
    await writeLog({
      level: "error",
      category: "worker",
      action: "worker_failed",
      success: false,
      correlation_id: requestCorrelationId,
      latency_ms: Date.now() - startedAt,
      error_code: error instanceof ApiError ? error.code : "internal_error",
      message: error instanceof Error ? error.message : "Falha no worker.",
    });
    return failure(request, error, requestCorrelationId);
  }
});

async function processSyncJob(
  job: MarketingSyncJob,
  workerId: string,
  runtimes: Map<string, MarketingConnectionRuntime>,
  correlation: string,
): Promise<JsonObject> {
  const startedAt = Date.now();
  try {
    let runtime = await runtimeFor(job.connection_id, runtimes);
    let synced;
    try {
      synced = await syncProviderMetrics(
        runtime,
        job.start_date,
        job.end_date,
      );
    } catch (error) {
      if (
        runtime.provider !== "google" ||
        !(error instanceof ProviderError) || error.httpStatus !== 401
      ) {
        throw error;
      }
      runtime = await forceGoogleRefresh(runtime, runtimes);
      synced = await syncProviderMetrics(
        runtime,
        job.start_date,
        job.end_date,
      );
    }
    if (synced.token.secretsPatch) {
      await persistSecretsPatch(runtime.id, synced.token.secretsPatch);
      runtimes.set(runtime.id, synced.token.runtime);
    }
    let upserted = 0;
    for (let offset = 0; offset < synced.metrics.length; offset += 500) {
      upserted += await serviceRpc<number>("ma_service_upsert_metrics", {
        p_connection_id: job.connection_id,
        p_sync_run_id: job.sync_run_id,
        p_metrics: synced.metrics.slice(offset, offset + 500),
      });
    }
    const finished = await serviceRpc<JsonObject>("ma_service_finish_sync", {
      p_queue_id: job.id,
      p_worker_id: workerId,
      p_success: true,
      p_rows_received: synced.metrics.length,
      p_rows_upserted: upserted,
      p_provider_metadata: synced.providerMetadata,
      p_error_code: null,
      p_error_message: null,
      p_retryable: false,
    });
    if (!finished.ok) {
      throw new ApiError(
        "Lease da sincronizacao foi perdido antes da confirmacao.",
        409,
        "sync_claim_lost",
      );
    }
    await writeLog({
      admin_user_id: job.admin_user_id,
      store_id: job.store_id,
      connection_id: job.connection_id,
      level: "info",
      category: "sync",
      action: "metrics_sync_completed",
      success: true,
      correlation_id: correlation,
      latency_ms: Date.now() - startedAt,
      message: "Metricas de anuncios sincronizadas.",
      metadata: {
        queue_id: job.id,
        rows_received: synced.metrics.length,
        rows_upserted: upserted,
        start_date: job.start_date,
        end_date: job.end_date,
      },
    });
    return {
      id: job.id,
      provider: job.provider,
      status: "completed",
      rows: upserted,
    };
  } catch (error) {
    const normalized = normalizeFailure(error);
    const finished = await serviceRpc<JsonObject>("ma_service_finish_sync", {
      p_queue_id: job.id,
      p_worker_id: workerId,
      p_success: false,
      p_rows_received: 0,
      p_rows_upserted: 0,
      p_provider_metadata: {},
      p_error_code: normalized.code,
      p_error_message: normalized.message,
      p_retryable: normalized.retryable,
    }).catch(() => ({ ok: false, status: "finish_failed" }));
    await markConnectionIfAuthenticationFailed(job.connection_id, error);
    await writeLog({
      admin_user_id: job.admin_user_id,
      store_id: job.store_id,
      connection_id: job.connection_id,
      level: normalized.retryable ? "warning" : "error",
      category: "sync",
      action: "metrics_sync_failed",
      success: false,
      correlation_id: correlation,
      latency_ms: Date.now() - startedAt,
      error_code: normalized.code,
      message: normalized.message,
      metadata: { queue_id: job.id, queue_status: finished.status },
    });
    return {
      id: job.id,
      provider: job.provider,
      status: String(finished.status || "failed"),
      error: normalized.message,
    };
  }
}

async function processConversionJob(
  job: MarketingConversionJob,
  workerId: string,
  runtimes: Map<string, MarketingConnectionRuntime>,
  correlation: string,
): Promise<JsonObject> {
  const startedAt = Date.now();
  try {
    let runtime = await runtimeFor(job.connection_id, runtimes);
    let sent;
    try {
      sent = await sendOfflineConversion(runtime, job);
    } catch (error) {
      if (
        runtime.provider !== "google" ||
        !(error instanceof ProviderError) || error.httpStatus !== 401
      ) {
        throw error;
      }
      runtime = await forceGoogleRefresh(runtime, runtimes);
      sent = await sendOfflineConversion(runtime, job);
    }
    if (sent.token.secretsPatch) {
      await persistSecretsPatch(runtime.id, sent.token.secretsPatch);
      runtimes.set(runtime.id, sent.token.runtime);
    }
    const finished = await serviceRpc<JsonObject>(
      "ma_service_finish_conversion",
      {
        p_queue_id: job.id,
        p_worker_id: workerId,
        p_success: true,
        p_provider_receipt: sent.receipt,
        p_error_code: null,
        p_error_message: null,
        p_retryable: false,
        p_skip: false,
      },
    );
    if (!finished.ok) {
      // O provedor aceitou uma conversao idempotente, mas o banco perdeu o
      // lease. Nao tentamos reenviar dentro desta execucao.
      await writeLog({
        admin_user_id: job.admin_user_id,
        store_id: job.store_id,
        connection_id: job.connection_id,
        level: "critical",
        category: "conversion",
        action: "provider_accepted_after_claim_lost",
        success: false,
        correlation_id: correlation,
        error_code: "conversion_claim_lost",
        message:
          "O provedor aceitou a conversao, mas o lease foi perdido; reconciliacao manual pode ser necessaria.",
        metadata: { queue_id: job.id, event_id: job.event_id },
      });
      return { id: job.id, provider: job.provider, status: "sent_unconfirmed" };
    }
    await writeLog({
      admin_user_id: job.admin_user_id,
      store_id: job.store_id,
      connection_id: job.connection_id,
      level: "info",
      category: "conversion",
      action: "offline_conversion_sent",
      success: true,
      correlation_id: correlation,
      latency_ms: Date.now() - startedAt,
      message: "Conversao offline enviada ao provedor.",
      metadata: {
        queue_id: job.id,
        event_id: job.event_id,
        event_name: job.event_name,
      },
    });
    return {
      id: job.id,
      provider: job.provider,
      status: String(finished.status || "sent"),
    };
  } catch (error) {
    const normalized = normalizeFailure(error);
    const skip = error instanceof ApiError && [
      "meta_match_key_missing",
      "google_match_key_missing",
      "meta_dataset_missing",
      "google_conversion_action_missing",
    ].includes(error.code);
    const finished = await serviceRpc<JsonObject>(
      "ma_service_finish_conversion",
      {
        p_queue_id: job.id,
        p_worker_id: workerId,
        p_success: false,
        p_provider_receipt: null,
        p_error_code: normalized.code,
        p_error_message: normalized.message,
        p_retryable: skip ? false : normalized.retryable,
        p_skip: skip,
      },
    ).catch(() => ({ ok: false, status: "finish_failed" }));
    await markConnectionIfAuthenticationFailed(job.connection_id, error);
    await writeLog({
      admin_user_id: job.admin_user_id,
      store_id: job.store_id,
      connection_id: job.connection_id,
      level: skip ? "warning" : normalized.retryable ? "warning" : "error",
      category: "conversion",
      action: skip ? "offline_conversion_skipped" : "offline_conversion_failed",
      success: false,
      correlation_id: correlation,
      latency_ms: Date.now() - startedAt,
      error_code: normalized.code,
      message: normalized.message,
      metadata: {
        queue_id: job.id,
        event_id: job.event_id,
        queue_status: finished.status,
      },
    });
    return {
      id: job.id,
      provider: job.provider,
      status: skip ? "skipped" : String(finished.status || "failed"),
      error: normalized.message,
    };
  }
}

async function processConversionDiagnostic(
  job: MarketingConversionDiagnosticJob,
  workerId: string,
  runtimes: Map<string, MarketingConnectionRuntime>,
  correlation: string,
): Promise<JsonObject> {
  const startedAt = Date.now();
  try {
    let runtime = await runtimeFor(job.connection_id, runtimes);
    let diagnostic;
    try {
      diagnostic = await retrieveGoogleConversionStatus(
        runtime,
        job.request_id,
      );
    } catch (error) {
      if (
        !(error instanceof ProviderError) || error.httpStatus !== 401
      ) {
        throw error;
      }
      runtime = await forceGoogleRefresh(runtime, runtimes);
      diagnostic = await retrieveGoogleConversionStatus(
        runtime,
        job.request_id,
      );
    }
    if (diagnostic.token.secretsPatch) {
      await persistSecretsPatch(
        runtime.id,
        diagnostic.token.secretsPatch,
      );
      runtimes.set(runtime.id, diagnostic.token.runtime);
    }
    const errorMessage = diagnostic.status === "partial"
      ? "O Google processou somente parte da conversao. Consulte o recibo para os motivos."
      : diagnostic.status === "failed"
      ? "O Google recusou a conversao durante o processamento assincrono."
      : null;
    const finished = await serviceRpc<JsonObject>(
      "ma_service_finish_conversion_diagnostic",
      {
        p_queue_id: job.id,
        p_worker_id: workerId,
        p_status: diagnostic.status,
        p_provider_receipt: diagnostic.receipt,
        p_error_code: diagnostic.status === "partial"
          ? "google_partial_success"
          : diagnostic.status === "failed"
          ? "google_conversion_failed"
          : null,
        p_error_message: errorMessage,
      },
    );
    if (!finished.ok) {
      throw new ApiError(
        "Lease do diagnostico foi perdido antes da confirmacao.",
        409,
        "conversion_diagnostic_claim_lost",
      );
    }
    await writeLog({
      admin_user_id: job.admin_user_id,
      store_id: job.store_id,
      connection_id: job.connection_id,
      level: diagnostic.status === "failed"
        ? "error"
        : diagnostic.status === "partial"
        ? "warning"
        : "info",
      category: "conversion",
      action: `offline_conversion_${diagnostic.status}`,
      success: diagnostic.status === "success",
      correlation_id: correlation,
      latency_ms: Date.now() - startedAt,
      error_code: diagnostic.status === "partial"
        ? "google_partial_success"
        : diagnostic.status === "failed"
        ? "google_conversion_failed"
        : undefined,
      message: diagnostic.status === "processing"
        ? "Conversao Google ainda em processamento; novo diagnostico agendado."
        : diagnostic.status === "success"
        ? "Conversao Google confirmada pelo Data Manager."
        : errorMessage || "Diagnostico da conversao Google concluido.",
      metadata: {
        queue_id: job.id,
        event_id: job.event_id,
        request_id: job.request_id,
        diagnostic_attempt: job.diagnostic_attempt_count,
        queue_status: finished.status,
      },
    });
    return {
      id: job.id,
      provider: job.provider,
      status: String(finished.status || diagnostic.status),
      diagnostic_status: diagnostic.status,
    };
  } catch (error) {
    const normalized = normalizeFailure(error);
    const diagnosticStatus = normalized.retryable ? "processing" : "failed";
    const finished = await serviceRpc<JsonObject>(
      "ma_service_finish_conversion_diagnostic",
      {
        p_queue_id: job.id,
        p_worker_id: workerId,
        p_status: diagnosticStatus,
        p_provider_receipt: {
          poll_error_code: normalized.code,
          poll_error_message: normalized.message,
        },
        p_error_code: normalized.code,
        p_error_message: normalized.message,
      },
    ).catch(() => ({ ok: false, status: "finish_failed" }));
    await markConnectionIfAuthenticationFailed(job.connection_id, error);
    await writeLog({
      admin_user_id: job.admin_user_id,
      store_id: job.store_id,
      connection_id: job.connection_id,
      level: normalized.retryable ? "warning" : "error",
      category: "conversion",
      action: "offline_conversion_diagnostic_failed",
      success: false,
      correlation_id: correlation,
      latency_ms: Date.now() - startedAt,
      error_code: normalized.code,
      message: normalized.message,
      metadata: {
        queue_id: job.id,
        event_id: job.event_id,
        request_id: job.request_id,
        diagnostic_attempt: job.diagnostic_attempt_count,
        queue_status: finished.status,
      },
    });
    return {
      id: job.id,
      provider: job.provider,
      status: String(finished.status || diagnosticStatus),
      error: normalized.message,
    };
  }
}

async function runtimeFor(
  connectionId: string,
  runtimes: Map<string, MarketingConnectionRuntime>,
): Promise<MarketingConnectionRuntime> {
  const cached = runtimes.get(connectionId);
  if (cached) return cached;
  const runtime = await serviceRpc<MarketingConnectionRuntime>(
    "ma_service_connection_runtime_by_id",
    { p_connection_id: connectionId, p_encryption_key: encryptionKey },
  );
  runtimes.set(connectionId, runtime);
  return runtime;
}

async function forceGoogleRefresh(
  runtime: MarketingConnectionRuntime,
  runtimes: Map<string, MarketingConnectionRuntime>,
): Promise<MarketingConnectionRuntime> {
  const refreshed = await ensureGoogleAccessToken(runtime, true);
  if (refreshed.secretsPatch) {
    await persistSecretsPatch(runtime.id, refreshed.secretsPatch);
  }
  runtimes.set(runtime.id, refreshed.runtime);
  return refreshed.runtime;
}

async function persistSecretsPatch(
  connectionId: string,
  patch: JsonObject,
): Promise<void> {
  await serviceRpc("ma_service_update_connection_secrets", {
    p_connection_id: connectionId,
    p_encryption_key: encryptionKey,
    p_patch: patch,
  });
}

async function markConnectionIfAuthenticationFailed(
  connectionId: string,
  error: unknown,
): Promise<void> {
  if (
    !(error instanceof ProviderError) ||
    ![401, 403].includes(error.httpStatus)
  ) return;
  await serviceRpc("ma_service_set_connection_status", {
    p_connection_id: connectionId,
    p_status: "error",
    p_error_code: error.code,
    p_error_message: error.message,
    p_metadata: {},
  }).catch(() => null);
}

function normalizeFailure(error: unknown): {
  code: string;
  message: string;
  retryable: boolean;
} {
  if (error instanceof ApiError) {
    return {
      code: error.code,
      message: error.message.slice(0, 4000),
      retryable: error.retryable,
    };
  }
  return {
    code: "internal_error",
    message: error instanceof Error
      ? error.message.slice(0, 4000)
      : "Falha interna no worker.",
    retryable: true,
  };
}

function authorizeWorker(request: Request): void {
  if (workerSecret.length < 32) {
    throw new ApiError(
      "MARKETING_WORKER_SECRET nao configurado.",
      500,
      "worker_secret_missing",
    );
  }
  const supplied = request.headers.get("x-worker-secret") || "";
  if (!constantTimeEqual(workerSecret, supplied)) {
    throw new ApiError(
      "Worker nao autorizado.",
      401,
      "worker_unauthorized",
    );
  }
}

function requireConfiguration(): void {
  if (encryptionKey.length < 32) {
    throw new ApiError(
      "MARKETING_CREDENTIALS_KEY nao configurada.",
      500,
      "credential_key_missing",
    );
  }
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

function summarize(items: JsonObject[]): JsonObject {
  const counts: Record<string, number> = {};
  for (const item of items) {
    const status = String(item.status || "unknown");
    counts[status] = (counts[status] || 0) + 1;
  }
  return { claimed: items.length, ...counts };
}
