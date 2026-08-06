import { buildMessagePayload } from "./meta.ts";
import {
  describeWebhook,
  extractBusinessAccountId,
  extractPhoneNumberId,
  partitionWebhookPayload,
} from "./webhook-processor.ts";

Deno.test("monta mensagem oficial sem campos arbitrarios", () => {
  const payload = buildMessagePayload({
    to: "+55 (19) 99999-0000",
    type: "text",
    text: "Ola",
  });
  if (
    payload.messaging_product !== "whatsapp" || payload.to !== "5519999990000"
  ) {
    throw new Error("Payload oficial incorreto.");
  }
  if ((payload.text as Record<string, unknown>).body !== "Ola") {
    throw new Error("Texto nao preservado.");
  }
});

Deno.test("recusa tipos de mensagem fora da allowlist", () => {
  let rejected = false;
  try {
    buildMessagePayload({
      to: "5519999990000",
      type: "__proto__",
      __proto__: { polluted: true },
    });
  } catch (error) {
    rejected = error instanceof Error &&
      error.message.includes("nao suportado");
  }
  if (!rejected) throw new Error("Tipo arbitrario deveria ser recusado.");
});

Deno.test("identifica tenant e tipo no webhook", () => {
  const payload = {
    object: "whatsapp_business_account",
    entry: [{
      id: "waba-1",
      changes: [{
        field: "messages",
        value: {
          metadata: { phone_number_id: "phone-1" },
          messages: [{ id: "wamid.1", type: "text" }],
        },
      }],
    }],
  };
  if (extractPhoneNumberId(payload) !== "phone-1") {
    throw new Error("Phone Number ID ausente.");
  }
  if (extractBusinessAccountId(payload) !== "waba-1") {
    throw new Error("WABA ID ausente.");
  }
  const description = describeWebhook(payload);
  if (
    description.eventType !== "message.text" ||
    description.providerMessageId !== "wamid.1"
  ) {
    throw new Error("Evento nao classificado.");
  }
});

Deno.test("isola cada numero de um webhook multiempresa", () => {
  const payload = {
    object: "whatsapp_business_account",
    entry: [
      {
        id: "waba-1",
        changes: [{
          field: "messages",
          value: {
            metadata: { phone_number_id: "phone-1" },
            messages: [{ id: "wamid.1", type: "text" }],
          },
        }],
      },
      {
        id: "waba-2",
        changes: [{
          field: "messages",
          value: {
            metadata: { phone_number_id: "phone-2" },
            messages: [{ id: "wamid.2", type: "image" }],
          },
        }],
      },
    ],
  };
  const partitions = partitionWebhookPayload(payload);
  if (partitions.length !== 2) {
    throw new Error("Cada numero deve produzir um subpayload isolado.");
  }
  const first = partitions.find((item) => item.phoneNumberId === "phone-1");
  const second = partitions.find((item) => item.phoneNumberId === "phone-2");
  if (!first || !second) throw new Error("Rotas dos numeros nao preservadas.");
  if (
    JSON.stringify(first.payload).includes("phone-2") ||
    JSON.stringify(second.payload).includes("phone-1")
  ) {
    throw new Error("Um subpayload recebeu dados do outro numero.");
  }
});
