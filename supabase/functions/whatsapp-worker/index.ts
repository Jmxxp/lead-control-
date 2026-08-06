import { constantTimeEqual } from "../_shared/whatsapp/crypto.ts";
import { serviceRpc, writeLog } from "../_shared/whatsapp/db.ts";
import { MetaApiError, sendMessage } from "../_shared/whatsapp/meta.ts";
import {
  ApiError,
  correlationId,
  corsHeaders,
  failure,
  ok,
} from "../_shared/whatsapp/response.ts";
import type {
  JsonObject,
  QueueJob,
  WhatsAppRuntime,
} from "../_shared/whatsapp/types.ts";
import { processWebhookPayload } from "../_shared/whatsapp/webhook-processor.ts";

const encryptionKey = Deno.env.get("WHATSAPP_CREDENTIAL_ENCRYPTION_KEY") || "";
const workerSecret = Deno.env.get("WHATSAPP_WORKER_SECRET") || "";
const configuredBatchSize = Number(
  Deno.env.get("WHATSAPP_WORKER_BATCH_SIZE") || 20,
);
const maxDispatchWaitMs = Math.min(
  Math.max(
    Number(Deno.env.get("WHATSAPP_WORKER_MAX_WAIT_MS") || 12_000),
    1_000,
  ),
  15_000,
);

Deno.serve(async (request) => {
  const requestCorrelationId = correlationId(request);
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  try {
    if (request.method !== "POST") {
      throw new ApiError("Metodo nao permitido.", 405, "method_not_allowed");
    }
    authorizeWorker(request);
    if (encryptionKey.length < 32) {
      throw new ApiError(
        "WHATSAPP_CREDENTIAL_ENCRYPTION_KEY nao configurada.",
        500,
        "credential_key_missing",
      );
    }
    const body = await request.json().catch(() => ({}));
    const requestedLimit = Number(body?.limit || configuredBatchSize);
    const limit = Math.min(
      Math.max(Number.isFinite(requestedLimit) ? requestedLimit : 20, 1),
      50,
    );
    const workerId = `edge:${requestCorrelationId}`;
    const webhookEvents = await serviceRpc<
      Array<{
        id: string;
        connection_id: string;
        payload: JsonObject;
        admin_user_id: string;
        store_id: string;
      }>
    >("wa_service_claim_webhooks", {
      p_worker_id: workerId,
      p_limit: Math.min(limit, 25),
    });
    const webhookResults: JsonObject[] = [];
    for (const event of webhookEvents) {
      try {
        const processed = await processWebhookPayload(
          event.connection_id,
          event.payload,
          event.id,
          true,
        );
        webhookResults.push({
          id: event.id,
          status: "processed",
          ...processed,
        });
      } catch (error) {
        webhookResults.push({
          id: event.id,
          status: "failed",
          error: error instanceof Error ? error.message : "Falha no webhook.",
        });
        await writeLog({
          admin_user_id: event.admin_user_id,
          store_id: event.store_id,
          connection_id: event.connection_id,
          level: "error",
          category: "webhook",
          action: "async_webhook_failed",
          correlation_id: requestCorrelationId,
          success: false,
          message: error instanceof Error ? error.message : "Falha no webhook.",
          metadata: { event_id: event.id },
        });
      }
    }
    const jobs = await serviceRpc<QueueJob[]>("wa_service_claim_queue", {
      p_worker_id: workerId,
      p_limit: limit,
    });
    const runtimes = new Map<string, WhatsAppRuntime>();
    const results: JsonObject[] = [];
    jobs.sort((left, right) => dispatchTime(left) - dispatchTime(right));
    for (const job of jobs) {
      const scheduledFor = dispatchTime(job);
      const waitMs = Math.max(0, scheduledFor - Date.now());
      if (waitMs > maxDispatchWaitMs) {
        const released = await serviceRpc<boolean>(
          "wa_service_release_queue_claim",
          {
            p_queue_id: job.id,
            p_worker_id: workerId,
            p_available_at: new Date(scheduledFor).toISOString(),
            p_reason:
              "Envio devolvido a fila para evitar espera longa na Edge Function.",
          },
        );
        results.push({
          id: job.id,
          status: released ? "deferred" : "claim_lost",
        });
        continue;
      }
      await delay(waitMs);
      const startedAt = Date.now();
      try {
        const prepared = await serviceRpc<{
          ready: boolean;
          status?: string;
          reason?: string;
        }>("wa_service_prepare_queue_send", {
          p_queue_id: job.id,
          p_worker_id: workerId,
        });
        if (!prepared.ready) {
          results.push({
            id: job.id,
            status: prepared.status || "skipped",
            reason: prepared.reason || null,
          });
          continue;
        }
        let runtime = runtimes.get(job.connection_id);
        if (!runtime) {
          runtime = await serviceRpc<WhatsAppRuntime>(
            "wa_service_connection_runtime_by_id",
            {
              p_connection_id: job.connection_id,
              p_encryption_key: encryptionKey,
            },
          );
          runtimes.set(job.connection_id, runtime);
        }
        validateQueuedPayload(job.payload);
        const providerResponse = await sendMessage(runtime, job.payload);
        const providerMessageId = providerId(providerResponse);
        if (!providerMessageId) {
          const quarantined = await quarantineAcceptedQueue(
            job,
            providerResponse,
            "A Meta respondeu sucesso sem devolver o ID da mensagem.",
          );
          results.push({
            id: job.id,
            status: "sent_unconfirmed",
            provider_message_id: null,
            quarantined,
          });
          await writeLog({
            admin_user_id: job.admin_user_id,
            store_id: job.store_id,
            connection_id: job.connection_id,
            level: "critical",
            category: "queue",
            action: "provider_message_id_missing",
            correlation_id: requestCorrelationId,
            success: false,
            message:
              "A Meta aceitou o POST sem informar o ID da mensagem; o item foi bloqueado contra reenvio automatico.",
            metadata: { queue_id: job.id, quarantined },
          });
          continue;
        }
        const finished = await serviceRpc<{
          ok: boolean;
          queue_status?: string;
          finalize_error?: string;
        }>("wa_service_finish_queue_claim", {
          p_queue_id: job.id,
          p_worker_id: workerId,
          p_success: true,
          p_provider_message_id: providerMessageId || null,
          p_provider_response: providerResponse,
          p_http_status: 200,
          p_error_code: null,
          p_error_message: null,
          p_retry_at: null,
          p_terminal: false,
        }).catch((error) => ({
          ok: false,
          queue_status: "finalize_error",
          finalize_error: error instanceof Error
            ? error.message
            : "Falha ao confirmar o envio no banco.",
        }));
        if (!finished.ok) {
          const quarantined = await quarantineAcceptedQueue(
            job,
            providerResponse,
            finished.finalize_error ||
              "O lease foi perdido depois que a Meta aceitou a mensagem.",
            providerMessageId,
          );
          results.push({
            id: job.id,
            status: "sent_unconfirmed",
            provider_message_id: providerMessageId,
            quarantined,
          });
          await writeLog({
            admin_user_id: job.admin_user_id,
            store_id: job.store_id,
            connection_id: job.connection_id,
            level: "critical",
            category: "queue",
            action: "provider_accepted_after_claim_lost",
            correlation_id: requestCorrelationId,
            success: false,
            message:
              "A Meta aceitou a mensagem, mas o lease da fila nao pertencia mais a este worker. Requer reconciliacao antes de reenviar.",
            metadata: {
              queue_id: job.id,
              provider_message_id: providerMessageId,
              queue_status: finished.queue_status,
              finalize_error: finished.finalize_error,
              quarantined,
            },
          });
          continue;
        }
        results.push({
          id: job.id,
          status: "sent",
          provider_message_id: providerMessageId,
        });
        await writeLog({
          admin_user_id: job.admin_user_id,
          store_id: job.store_id,
          connection_id: job.connection_id,
          level: "info",
          category: "message",
          action: "message_sent",
          correlation_id: requestCorrelationId,
          success: true,
          http_method: "POST",
          endpoint:
            `/${runtime.graph_api_version}/${runtime.phone_number_id}/messages`,
          http_status: 200,
          latency_ms: Date.now() - startedAt,
          message: "Mensagem aceita pela Cloud API.",
          metadata: {
            queue_id: job.id,
            provider_message_id: providerMessageId,
            attempt: job.attempt_count,
          },
        });
      } catch (error) {
        const failure = normalizeFailure(error, job.attempt_count);
        if (
          error instanceof MetaApiError &&
          (error.httpStatus === 401 || error.httpStatus === 403 ||
            [102, 190].includes(error.metaCode || -1))
        ) {
          await serviceRpc("wa_service_set_connection_status", {
            p_connection_id: job.connection_id,
            p_status: "error",
            p_error_code: failure.code,
            p_error_message: failure.message,
            p_metadata: {},
          }).catch(() => null);
        }
        const finished = await serviceRpc<{
          ok: boolean;
          queue_status?: string;
        }>("wa_service_finish_queue_claim", {
          p_queue_id: job.id,
          p_worker_id: workerId,
          p_success: false,
          p_provider_message_id: null,
          p_provider_response: failure.providerResponse,
          p_http_status: failure.httpStatus,
          p_error_code: failure.code,
          p_error_message: failure.message,
          p_retry_at: failure.retryAt,
          p_terminal: !failure.retryable,
        }).catch(() => null);
        const resultStatus = !finished?.ok
          ? "claim_lost"
          : failure.retryable
          ? "retry"
          : "failed";
        results.push({
          id: job.id,
          status: resultStatus,
          error: failure.message,
        });
        await writeLog({
          admin_user_id: job.admin_user_id,
          store_id: job.store_id,
          connection_id: job.connection_id,
          level: failure.retryable ? "warning" : "error",
          category: "message",
          action: "message_send_failed",
          correlation_id: requestCorrelationId,
          success: false,
          http_status: failure.httpStatus,
          latency_ms: Date.now() - startedAt,
          error_code: failure.code,
          message: failure.message,
          metadata: {
            queue_id: job.id,
            attempt: job.attempt_count,
            retry_at: failure.retryAt,
          },
        });
      }
    }
    return ok(request, {
      webhooks_claimed: webhookEvents.length,
      webhooks_processed: webhookResults.filter((item) =>
        item.status === "processed"
      ).length,
      webhook_results: webhookResults,
      claimed: jobs.length,
      sent: results.filter((item) => item.status === "sent").length,
      retry: results.filter((item) => item.status === "retry").length,
      failed: results.filter((item) => item.status === "failed").length,
      deferred: results.filter((item) => item.status === "deferred").length,
      sent_unconfirmed: results.filter((item) =>
        item.status === "sent_unconfirmed"
      ).length,
      claim_lost: results.filter((item) => item.status === "claim_lost").length,
      results,
    }, requestCorrelationId);
  } catch (error) {
    await writeLog({
      level: "error",
      category: "queue",
      action: "worker_failed",
      correlation_id: requestCorrelationId,
      success: false,
      message: error instanceof Error ? error.message : "Falha no worker.",
    });
    return failure(request, error, requestCorrelationId);
  }
});

function authorizeWorker(request: Request): void {
  if (workerSecret.length < 24) {
    throw new ApiError(
      "WHATSAPP_WORKER_SECRET nao configurado.",
      500,
      "worker_secret_missing",
    );
  }
  const supplied = request.headers.get("x-worker-secret") || "";
  if (!constantTimeEqual(workerSecret, supplied)) {
    throw new ApiError("Worker nao autorizado.", 401, "worker_unauthorized");
  }
}

function validateQueuedPayload(payload: JsonObject): void {
  if (payload.messaging_product !== "whatsapp") {
    throw new ApiError(
      "Payload da fila sem messaging_product valido.",
      400,
      "invalid_queue_payload",
    );
  }
  const to = String(payload.to || "");
  if (!/^\d{7,15}$/.test(to)) {
    throw new ApiError(
      "Destinatario da fila invalido.",
      400,
      "invalid_queue_recipient",
    );
  }
  if (!String(payload.type || "")) {
    throw new ApiError(
      "Tipo da mensagem ausente.",
      400,
      "invalid_queue_payload",
    );
  }
}

function providerId(response: JsonObject): string {
  const messages = Array.isArray(response.messages) ? response.messages : [];
  const first = messages[0];
  return first && typeof first === "object"
    ? String((first as JsonObject).id || "")
    : "";
}

async function quarantineAcceptedQueue(
  job: QueueJob,
  providerResponse: JsonObject,
  reason: string,
  providerMessageId = "",
): Promise<boolean> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const result = await serviceRpc<{ ok: boolean }>(
      "wa_service_quarantine_accepted_queue",
      {
        p_queue_id: job.id,
        p_provider_message_id: providerMessageId || null,
        p_provider_response: providerResponse,
        p_reason: reason,
      },
    ).catch(() => null);
    if (result?.ok) return true;
    if (attempt < 3) await delay(150 * 2 ** attempt);
  }
  return false;
}

function normalizeFailure(error: unknown, attempt: number): {
  message: string;
  code: string;
  retryable: boolean;
  retryAt: string;
  httpStatus: number | null;
  providerResponse: JsonObject;
} {
  const meta = error instanceof MetaApiError ? error : null;
  const retryable = meta
    ? meta.retryable
    : !(error instanceof ApiError) || error.status >= 500;
  const baseDelaySeconds = meta?.retryAfterSeconds ??
    Math.min(21600, 5 * 2 ** Math.min(attempt, 12));
  const jitter = Math.floor(
    Math.random() * Math.max(1, baseDelaySeconds * 0.2),
  );
  return {
    message: error instanceof Error
      ? error.message.slice(0, 4000)
      : "Falha ao enviar mensagem.",
    code: meta?.metaCode
      ? String(meta.metaCode)
      : error instanceof ApiError
      ? error.code
      : "network_error",
    retryable,
    retryAt: new Date(Date.now() + (baseDelaySeconds + jitter) * 1000)
      .toISOString(),
    httpStatus: meta?.httpStatus ?? null,
    providerResponse: meta?.details && typeof meta.details === "object"
      ? meta.details as JsonObject
      : {},
  };
}

function delay(milliseconds: number): Promise<void> {
  if (milliseconds <= 0) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function dispatchTime(job: QueueJob): number {
  const parsed = Date.parse(job.dispatch_at || job.reserved_dispatch_at || "");
  return Number.isFinite(parsed) ? parsed : Date.now();
}
