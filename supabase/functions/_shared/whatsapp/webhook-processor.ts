import { serviceRpc } from "./db.ts";
import type {
  JsonObject,
  NormalizedWebhookMessage,
  NormalizedWebhookStatus,
} from "./types.ts";

type ProcessResult = {
  messages: number;
  statuses: number;
  templates: number;
  ignored: number;
};

export type WebhookPartition = {
  businessAccountId: string;
  phoneNumberId: string;
  routingKey: string;
  changeCount: number;
  payload: JsonObject;
};

export async function processWebhookPayload(
  connectionId: string,
  payload: JsonObject,
  eventId?: string,
  alreadyClaimed = false,
): Promise<ProcessResult> {
  if (eventId && !alreadyClaimed) {
    await serviceRpc("wa_service_mark_webhook", {
      p_event_id: eventId,
      p_status: "processing",
      p_error: null,
    });
  }
  const result: ProcessResult = {
    messages: 0,
    statuses: 0,
    templates: 0,
    ignored: 0,
  };
  try {
    // Defesa em profundidade para eventos antigos, reprocessados ou inseridos
    // manualmente. Um job nunca pode aplicar changes de mais de um numero/WABA
    // usando o connectionId que veio na linha da fila.
    const partitions = partitionWebhookPayload(payload);
    const totalChanges = countWebhookChanges(payload);
    if (
      totalChanges > 0 &&
      (partitions.length !== 1 || partitions[0].changeCount !== totalChanges)
    ) {
      throw new Error(
        "Webhook contem changes de mais de uma conexao ou sem roteamento.",
      );
    }
    const entries = asArray(payload.entry);
    for (const entry of entries) {
      for (const change of asArray(entry.changes)) {
        const value = asObject(change.value);
        const field = String(change.field || "");
        if (field.startsWith("message_template")) {
          await serviceRpc("wa_service_apply_template_webhook", {
            p_connection_id: connectionId,
            p_payload: value,
          });
          result.templates += 1;
        }
        const contacts = asArray(value.contacts);
        const contactByWaId = new Map<string, JsonObject>();
        for (const item of contacts) {
          const waId = String(item.wa_id || "");
          if (waId) contactByWaId.set(waId, item);
        }

        for (const rawMessage of asArray(value.messages)) {
          const message = normalizeMessage(rawMessage);
          const sender = String(rawMessage.from || "");
          if (!message.provider_message_id || !sender) {
            result.ignored += 1;
            continue;
          }
          const profile = contactByWaId.get(sender) || contacts[0] || {};
          await serviceRpc("wa_service_upsert_inbound_message", {
            p_connection_id: connectionId,
            p_contact: {
              wa_id: String(profile.wa_id || sender),
              phone: sender,
              profile_name: String(asObject(profile.profile).name || ""),
            },
            p_message: message,
          });
          result.messages += 1;
        }

        for (const rawStatus of asArray(value.statuses)) {
          const status = normalizeStatus(rawStatus);
          if (!status.provider_message_id || !status.status) {
            result.ignored += 1;
            continue;
          }
          await serviceRpc("wa_service_update_message_status", {
            p_connection_id: connectionId,
            p_status_payload: status,
          });
          result.statuses += 1;
        }
      }
    }
    if (eventId) {
      await serviceRpc("wa_service_mark_webhook", {
        p_event_id: eventId,
        p_status: result.messages || result.statuses || result.templates
          ? "processed"
          : "ignored",
        p_error: null,
      });
    }
    return result;
  } catch (error) {
    if (eventId) {
      await serviceRpc("wa_service_mark_webhook", {
        p_event_id: eventId,
        p_status: "failed",
        p_error: error instanceof Error
          ? error.message.slice(0, 8000)
          : "Falha ao processar webhook.",
      }).catch(() => null);
    }
    throw error;
  }
}

/**
 * Separa o envelope da Meta pelo destino real de cada change. Mantemos apenas
 * object, entry.id, field e value: cabecalhos/entries de outro numero jamais
 * seguem para o evento persistido de um tenant.
 */
export function partitionWebhookPayload(
  payload: JsonObject,
): WebhookPartition[] {
  const object = String(payload.object || "");
  const groups = new Map<
    string,
    {
      businessAccountId: string;
      phoneNumberId: string;
      changes: JsonObject[];
    }
  >();

  for (const entry of asArray(payload.entry)) {
    const rawBusinessAccountId = String(entry.id || "").trim();
    const businessAccountId = providerIdentifier(rawBusinessAccountId);
    for (const rawChange of asArray(entry.changes)) {
      const value = asObject(rawChange.value);
      const metadata = asObject(value.metadata);
      const rawPhoneNumberId = String(metadata.phone_number_id || "").trim();
      const phoneNumberId = providerIdentifier(rawPhoneNumberId);
      // Identificador presente, mas fora do limite aceito: deixa o change sem
      // particao para que a camada HTTP rejeite o envelope inteiro.
      if (
        (rawBusinessAccountId && !businessAccountId) ||
        (rawPhoneNumberId && !phoneNumberId)
      ) continue;
      if (!phoneNumberId && !businessAccountId) continue;

      const routingKey = JSON.stringify([businessAccountId, phoneNumberId]);
      let group = groups.get(routingKey);
      if (!group) {
        group = { businessAccountId, phoneNumberId, changes: [] };
        groups.set(routingKey, group);
      }
      group.changes.push({
        field: String(rawChange.field || ""),
        value,
      });
    }
  }

  return [...groups.entries()].map(([routingKey, group]) => ({
    businessAccountId: group.businessAccountId,
    phoneNumberId: group.phoneNumberId,
    routingKey,
    changeCount: group.changes.length,
    payload: {
      object,
      entry: [{ id: group.businessAccountId, changes: group.changes }],
    },
  }));
}

export function countWebhookChanges(payload: JsonObject): number {
  let count = 0;
  for (const entry of asArray(payload.entry)) {
    count += asArray(entry.changes).length;
  }
  return count;
}

export function extractPhoneNumberId(payload: JsonObject): string {
  for (const entry of asArray(payload.entry)) {
    for (const change of asArray(entry.changes)) {
      const metadata = asObject(asObject(change.value).metadata);
      const id = String(metadata.phone_number_id || "").trim();
      if (id) return id;
    }
  }
  return "";
}

export function extractBusinessAccountId(payload: JsonObject): string {
  const entry = asArray(payload.entry)[0];
  return entry ? String(entry.id || "").trim() : "";
}

export function describeWebhook(payload: JsonObject): {
  eventType: string;
  providerObject: string;
  providerMessageId: string;
} {
  const object = String(payload.object || "");
  for (const entry of asArray(payload.entry)) {
    for (const change of asArray(entry.changes)) {
      const value = asObject(change.value);
      const message = asArray(value.messages)[0];
      if (message) {
        return {
          eventType: `message.${String(message.type || "unknown")}`,
          providerObject: object,
          providerMessageId: String(message.id || ""),
        };
      }
      const status = asArray(value.statuses)[0];
      if (status) {
        return {
          eventType: `status.${String(status.status || "unknown")}`,
          providerObject: object,
          providerMessageId: String(status.id || ""),
        };
      }
      return {
        eventType: String(change.field || "unknown"),
        providerObject: object,
        providerMessageId: "",
      };
    }
  }
  return {
    eventType: "unknown",
    providerObject: object,
    providerMessageId: "",
  };
}

function normalizeMessage(
  raw: JsonObject,
): NormalizedWebhookMessage & JsonObject {
  const providerType = String(raw.type || "unknown");
  const type = normalizeMessageType(providerType);
  const typed = asObject(raw[providerType]);
  const context = asObject(raw.context);
  const normalized: NormalizedWebhookMessage & JsonObject = {
    provider_message_id: String(raw.id || ""),
    type,
    sent_at: unixSecondsToIso(raw.timestamp),
    reply_to_provider_message_id: String(context.id || "") || undefined,
    raw,
  };
  if (providerType === "text") {
    normalized.text = String(asObject(raw.text).body || "");
  } else if (providerType === "button") {
    normalized.text = String(asObject(raw.button).text || "");
  } else if (providerType === "interactive") {
    normalized.text = interactiveText(asObject(raw.interactive));
  } else if (
    ["image", "document", "audio", "video", "sticker"].includes(
      providerType,
    )
  ) {
    normalized.text = String(typed.caption || typed.filename || "");
    normalized.media = {
      id: typed.id,
      mime_type: typed.mime_type,
      sha256: typed.sha256,
      filename: typed.filename,
      caption: typed.caption,
      voice: typed.voice,
    };
  } else if (providerType === "location") {
    const location = asObject(raw.location);
    normalized.text = [location.name, location.address].filter(Boolean).join(
      " — ",
    );
  }
  return normalized;
}

function normalizeMessageType(providerType: string): string {
  if (providerType === "button") return "interactive";
  return [
      "text",
      "image",
      "document",
      "audio",
      "video",
      "sticker",
      "location",
      "contacts",
      "interactive",
      "reaction",
      "template",
    ].includes(providerType)
    ? providerType
    : "unknown";
}

function normalizeStatus(
  raw: JsonObject,
): NormalizedWebhookStatus & JsonObject {
  const errors = asArray(raw.errors);
  const firstError = errors[0] || {};
  const errorData = asObject(firstError.error_data);
  return {
    provider_message_id: String(raw.id || ""),
    status: String(raw.status || ""),
    timestamp: unixSecondsToIso(raw.timestamp),
    recipient_id: String(raw.recipient_id || "") || undefined,
    biz_opaque_callback_data: String(raw.biz_opaque_callback_data || "") ||
      undefined,
    conversation: asObject(raw.conversation),
    pricing: asObject(raw.pricing),
    error_code: firstError.code === undefined
      ? undefined
      : String(firstError.code),
    error_message: String(
      firstError.message || firstError.title || errorData.details || "",
    ) || undefined,
    raw,
  };
}

function interactiveText(interactive: JsonObject): string {
  const buttonReply = asObject(interactive.button_reply);
  const listReply = asObject(interactive.list_reply);
  return String(
    buttonReply.title || listReply.title || listReply.description || "",
  );
}

function unixSecondsToIso(value: unknown): string {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) {
    return new Date().toISOString();
  }
  return new Date(seconds * 1000).toISOString();
}

function asArray(value: unknown): JsonObject[] {
  return Array.isArray(value)
    ? value.filter((item): item is JsonObject =>
      Boolean(item) && typeof item === "object"
    )
    : [];
}

function asObject(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

function providerIdentifier(value: unknown): string {
  const identifier = String(value || "").trim();
  return identifier.length <= 256 ? identifier : "";
}
