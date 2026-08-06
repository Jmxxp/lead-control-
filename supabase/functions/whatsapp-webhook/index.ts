import { sha256Hex, verifyMetaSignature } from "../_shared/whatsapp/crypto.ts";
import { serviceRpc, writeLog } from "../_shared/whatsapp/db.ts";
import {
  ApiError,
  correlationId,
  corsHeaders,
  failure,
  jsonResponse,
} from "../_shared/whatsapp/response.ts";
import type { JsonObject, WhatsAppRuntime } from "../_shared/whatsapp/types.ts";
import {
  countWebhookChanges,
  describeWebhook,
  partitionWebhookPayload,
  type WebhookPartition,
} from "../_shared/whatsapp/webhook-processor.ts";

const encryptionKey = Deno.env.get("WHATSAPP_CREDENTIAL_ENCRYPTION_KEY") || "";
const maxWebhookBytes = 3 * 1024 * 1024;

Deno.serve(async (request) => {
  const requestCorrelationId = correlationId(request);
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  try {
    if (request.method === "GET") {
      return await verifySubscription(request, requestCorrelationId);
    }
    if (request.method !== "POST") {
      throw new ApiError("Metodo nao permitido.", 405, "method_not_allowed");
    }
    return await receiveEvent(request, requestCorrelationId);
  } catch (error) {
    await writeLog({
      level: "error",
      category: "webhook",
      action: "receive_webhook",
      success: false,
      correlation_id: requestCorrelationId,
      message: error instanceof Error ? error.message : "Falha no webhook.",
    });
    return failure(request, error, requestCorrelationId);
  }
});

async function verifySubscription(
  request: Request,
  requestCorrelationId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const mode = url.searchParams.get("hub.mode") || "";
  const verifyToken = url.searchParams.get("hub.verify_token") || "";
  const challenge = url.searchParams.get("hub.challenge") || "";
  if (mode !== "subscribe" || !verifyToken || !challenge) {
    throw new ApiError(
      "Parametros de verificacao do webhook invalidos.",
      400,
      "invalid_webhook_challenge",
    );
  }
  const connection = await serviceRpc<JsonObject | null>(
    "wa_service_connection_by_verify_token",
    { p_verify_token: verifyToken },
  );
  if (!connection || connection === null || !connection.id) {
    await writeLog({
      level: "warning",
      category: "security",
      action: "webhook_verify_rejected",
      success: false,
      correlation_id: requestCorrelationId,
      message: "Verify Token recusado.",
    });
    throw new ApiError("Verify Token invalido.", 403, "verify_token_rejected");
  }
  await writeLog({
    admin_user_id: connection.admin_user_id,
    store_id: connection.store_id,
    connection_id: connection.id,
    level: "info",
    category: "webhook",
    action: "webhook_verified",
    success: true,
    correlation_id: requestCorrelationId,
    message: "Webhook verificado pela Meta.",
  });
  return new Response(challenge, {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Correlation-Id": requestCorrelationId,
    },
  });
}

async function receiveEvent(
  request: Request,
  requestCorrelationId: string,
): Promise<Response> {
  if (encryptionKey.length < 32) {
    throw new ApiError(
      "WHATSAPP_CREDENTIAL_ENCRYPTION_KEY nao configurada.",
      500,
      "credential_key_missing",
    );
  }
  const declaredLength = Number(request.headers.get("content-length") || 0);
  if (declaredLength > maxWebhookBytes) {
    throw new ApiError(
      "Payload do webhook excede 3 MB.",
      413,
      "webhook_too_large",
    );
  }
  const rawBody = new Uint8Array(await request.arrayBuffer());
  if (!rawBody.length || rawBody.length > maxWebhookBytes) {
    throw new ApiError(
      rawBody.length ? "Payload do webhook excede 3 MB." : "Webhook vazio.",
      rawBody.length ? 413 : 400,
      rawBody.length ? "webhook_too_large" : "empty_webhook",
    );
  }
  let payload: JsonObject;
  try {
    payload = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    throw new ApiError(
      "JSON do webhook invalido.",
      400,
      "invalid_webhook_json",
    );
  }
  const partitions = partitionWebhookPayload(payload);
  const totalChanges = countWebhookChanges(payload);
  if (
    !partitions.length || totalChanges === 0 ||
    partitions.reduce((sum, item) => sum + item.changeCount, 0) !== totalChanges
  ) {
    throw new ApiError(
      "Webhook possui change sem identificador do numero ou da conta WhatsApp.",
      400,
      "webhook_account_missing",
    );
  }

  const signature = request.headers.get("x-hub-signature-256") || "";
  const resolved: Array<{
    partition: WebhookPartition;
    runtime: WhatsAppRuntime;
  }> = [];
  const signatureChecked = new Set<string>();
  for (const partition of partitions) {
    const runtime = await resolvePartitionRuntime(partition);
    assertRuntimeOwnsPartition(runtime, partition);
    if (!signatureChecked.has(runtime.id)) {
      const signatureValid = await verifyMetaSignature(
        rawBody,
        signature,
        runtime.secrets.app_secret,
      );
      if (!signatureValid) {
        await writeLog({
          admin_user_id: runtime.admin_user_id,
          store_id: runtime.store_id,
          connection_id: runtime.id,
          level: "critical",
          category: "security",
          action: "webhook_signature_rejected",
          success: false,
          correlation_id: requestCorrelationId,
          message: "Assinatura X-Hub-Signature-256 invalida.",
        });
        throw new ApiError(
          "Assinatura do webhook invalida.",
          401,
          "invalid_webhook_signature",
        );
      }
      signatureChecked.add(runtime.id);
    }
    resolved.push({ partition, runtime });
  }

  const digest = await sha256Hex(rawBody);
  const headers = safeHeaders(request.headers);
  let accepted = 0;
  let duplicates = 0;
  for (const { partition, runtime } of resolved) {
    const description = describeWebhook(partition.payload);
    const routeDigest = await sha256Hex(
      new TextEncoder().encode(partition.routingKey),
    );
    const recorded = await serviceRpc<{ id: string; is_new: boolean }>(
      "wa_service_record_webhook",
      {
        p_connection_id: runtime.id,
        p_event_key: `sha256:${digest}:route:${routeDigest}`,
        p_event_type: description.eventType,
        p_provider_object: description.providerObject,
        p_provider_message_id: description.providerMessageId || null,
        p_headers: headers,
        p_payload: partition.payload,
      },
    );
    if (recorded.is_new) accepted += 1;
    else duplicates += 1;
    await writeLog({
      admin_user_id: runtime.admin_user_id,
      store_id: runtime.store_id,
      connection_id: runtime.id,
      level: "info",
      category: "webhook",
      action: recorded.is_new ? "webhook_accepted" : "webhook_duplicate",
      success: true,
      correlation_id: requestCorrelationId,
      message: recorded.is_new
        ? "Evento isolado por conexao e persistido para processamento assincrono."
        : "Reenvio idempotente reconhecido.",
      metadata: { event_id: recorded.id, change_count: partition.changeCount },
    });
  }
  return jsonResponse(
    request,
    {
      received: true,
      duplicate: accepted === 0,
      accepted,
      duplicates,
    },
    200,
    requestCorrelationId,
  );
}

async function resolvePartitionRuntime(
  partition: WebhookPartition,
): Promise<WhatsAppRuntime> {
  if (partition.phoneNumberId) {
    return await serviceRpc<WhatsAppRuntime>(
      "wa_service_connection_runtime_by_phone",
      {
        p_phone_number_id: partition.phoneNumberId,
        p_encryption_key: encryptionKey,
      },
    );
  }
  return await serviceRpc<WhatsAppRuntime>(
    "wa_service_connection_runtime_by_business_account",
    {
      p_business_account_id: partition.businessAccountId,
      p_encryption_key: encryptionKey,
    },
  );
}

function assertRuntimeOwnsPartition(
  runtime: WhatsAppRuntime,
  partition: WebhookPartition,
): void {
  const phoneMatches = !partition.phoneNumberId ||
    runtime.phone_number_id === partition.phoneNumberId;
  const businessMatches = !partition.businessAccountId ||
    runtime.business_account_id === partition.businessAccountId;
  if (!phoneMatches || !businessMatches) {
    throw new ApiError(
      "Identificadores do webhook nao pertencem a mesma conexao.",
      409,
      "webhook_routing_mismatch",
    );
  }
}

function safeHeaders(headers: Headers): JsonObject {
  const result: JsonObject = {};
  for (
    const key of [
      "content-type",
      "content-length",
      "user-agent",
      "x-forwarded-for",
    ]
  ) {
    const value = headers.get(key);
    if (value) result[key] = value.slice(0, 1000);
  }
  result["x-hub-signature-256-present"] = headers.has("x-hub-signature-256");
  return result;
}
