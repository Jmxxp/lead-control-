import { sha256Hex } from "./crypto.ts";
import {
  buildGoogleAuthorizationUrl,
  buildGoogleConversionPayload,
  buildMetaConversionPayload,
  normalizeEmail,
  normalizePhone,
  retrieveGoogleConversionStatus,
} from "./providers.ts";
import type {
  MarketingConnectionRuntime,
  MarketingConversionJob,
} from "./types.ts";

const metaRuntime: MarketingConnectionRuntime = {
  id: "00000000-0000-4000-8000-000000000001",
  admin_user_id: "00000000-0000-4000-8000-000000000002",
  store_id: "00000000-0000-4000-8000-000000000003",
  provider: "meta",
  name: "Meta",
  status: "active",
  account_external_id: "123",
  api_version: "v26.0",
  public_config: { dataset_id: "456" },
  secrets: { access_token: "token-de-teste-com-tamanho-suficiente" },
};

const googleRuntime: MarketingConnectionRuntime = {
  ...metaRuntime,
  provider: "google",
  name: "Google",
  account_external_id: "1234567890",
  api_version: "v25",
  public_config: {
    customer_id: "1234567890",
    login_customer_id: "9999999999",
    conversion_action_id: "customers/1234567890/conversionActions/42",
  },
  secrets: {
    access_token: "access-token",
    developer_token: "developer-token",
  },
};

const conversion: MarketingConversionJob = {
  id: "00000000-0000-4000-8000-000000000010",
  connection_id: metaRuntime.id,
  admin_user_id: metaRuntime.admin_user_id,
  store_id: metaRuntime.store_id,
  provider: "meta",
  lead_id: "00000000-0000-4000-8000-000000000011",
  event_name: "purchased",
  event_at: "2026-08-06T12:00:00.000Z",
  event_id: "ma:event:1",
  attempt_count: 1,
  max_attempts: 8,
  payload: {
    phone: "(19) 99999-0000",
    email: " CLIENTE@EXEMPLO.COM ",
    fbc: "fb.1.123.abc",
    gclid: "click-google",
    marketing_consent: true,
    value: 1000,
    currency: "BRL",
    order_id: "PV-1",
  },
};

Deno.test("normaliza identificadores antes do SHA-256", () => {
  if (normalizeEmail(" TESTE@EXEMPLO.COM ") !== "teste@exemplo.com") {
    throw new Error("Email nao normalizado.");
  }
  if (normalizePhone("(19) 99999-0000") !== "+5519999990000") {
    throw new Error("Telefone brasileiro nao normalizado.");
  }
});

Deno.test("OAuth Google solicita Ads e Data Manager", () => {
  const url = new URL(buildGoogleAuthorizationUrl({
    clientId: "client-id",
    redirectUri:
      "https://project.supabase.co/functions/v1/marketing-api?oauth=google",
    state: "state-seguro",
  }));
  const scope = url.searchParams.get("scope") || "";
  if (!scope.includes("auth/adwords") || !scope.includes("auth/datamanager")) {
    throw new Error("Escopos OAuth incompletos.");
  }
  if (url.searchParams.get("access_type") !== "offline") {
    throw new Error("OAuth deve solicitar refresh token.");
  }
});

Deno.test("Meta CAPI recebe hashes e nunca PII em texto", async () => {
  const payload = await buildMetaConversionPayload(conversion, metaRuntime);
  const serialized = JSON.stringify(payload);
  if (serialized.includes("CLIENTE@") || serialized.includes("999990000")) {
    throw new Error("PII em texto vazou para o payload Meta.");
  }
  const expectedEmailHash = await sha256Hex("cliente@exemplo.com");
  if (!serialized.includes(expectedEmailHash)) {
    throw new Error("Hash do email nao foi incluido.");
  }
});

Deno.test("sem consentimento a Meta recusa identificadores pessoais", async () => {
  let rejected = false;
  try {
    await buildMetaConversionPayload({
      ...conversion,
      payload: { ...conversion.payload, marketing_consent: false },
    }, metaRuntime);
  } catch (error) {
    rejected = error instanceof Error && error.message.includes("consentido");
  }
  if (!rejected) throw new Error("Conversao sem consentimento deveria falhar.");
});

Deno.test("Google Data Manager usa click ID e consentimento", async () => {
  const payload = await buildGoogleConversionPayload({
    ...conversion,
    provider: "google",
    connection_id: googleRuntime.id,
  }, googleRuntime);
  const serialized = JSON.stringify(payload);
  if (
    !serialized.includes("click-google") ||
    !serialized.includes("CONSENT_GRANTED")
  ) {
    throw new Error("Payload do Data Manager incompleto.");
  }
  if (!serialized.includes("google_ads_destination")) {
    throw new Error("Destino Google Ads ausente.");
  }
});

Deno.test("Google Data Manager reconcilia receipt assincrono", async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = () =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            requestStatusPerDestination: [{ requestStatus: "PARTIAL_SUCCESS" }],
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" },
          },
        ),
      );
    const result = await retrieveGoogleConversionStatus(
      googleRuntime,
      "request-id-1",
    );
    if (result.status !== "partial") {
      throw new Error("PARTIAL_SUCCESS deveria ser persistido como partial.");
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});
