const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-app-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ConnectionRuntime = {
  admin_user_id: string;
  user_id: string;
  provider: "meta" | "google";
  account_external_id: string;
  public_config: Record<string, unknown>;
  secret_config: Record<string, unknown>;
};

type QueueEvent = {
  id: string;
  lead_id: string;
  event_name: string;
  event_at: string;
  payload: Record<string, unknown>;
  attempt_count: number;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse({ error: "Método não permitido." }, 405);
  }

  try {
    const sessionToken = request.headers.get("x-app-session")?.trim() || "";
    const body = await request.json().catch(() => ({}));
    const storeId = typeof body?.store_id === "string" ? body.store_id : "";
    const provider = body?.provider === "google"
      ? "google"
      : body?.provider === "meta"
      ? "meta"
      : "";
    if (!sessionToken || !storeId || !provider) {
      return jsonResponse({
        error: "Sessão, loja e provedor são obrigatórios.",
      }, 400);
    }

    const connectionRows = await serviceRpc<ConnectionRuntime[]>(
      "lc_marketing_connection_runtime",
      {
        p_session_token: sessionToken,
        p_store_id: storeId,
        p_provider: provider,
      },
    );
    const connection = connectionRows?.[0];
    if (!connection) {
      return jsonResponse(
        { error: "Conector não está ativo para esta loja." },
        409,
      );
    }

    const events = await listPendingEvents(storeId, provider);
    const results = [];
    for (const event of events) {
      await updateQueueEvent(event.id, {
        status: "processing",
        attempt_count: (event.attempt_count || 0) + 1,
      });
      try {
        const receipt = provider === "meta"
          ? await sendMetaEvent(connection, event)
          : await sendGoogleEvent(connection, event);
        await updateQueueEvent(event.id, {
          status: "sent",
          processed_at: new Date().toISOString(),
          last_error: null,
        });
        results.push({ id: event.id, status: "sent", receipt });
      } catch (error) {
        const message = error instanceof Error
          ? error.message
          : "Falha no envio da conversão.";
        const nextAttempt = new Date(
          Date.now() +
            Math.min(60, 2 ** Math.min(event.attempt_count || 0, 5)) * 60_000,
        );
        await updateQueueEvent(event.id, {
          status: "failed",
          next_attempt_at: nextAttempt.toISOString(),
          last_error: message.slice(0, 2000),
        });
        results.push({ id: event.id, status: "failed", error: message });
      }
    }

    return jsonResponse({ ok: true, processed: results.length, results });
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Não foi possível processar as conversões.";
    return jsonResponse(
      { error: message },
      /sess[aã]o|permiss[aã]o/i.test(message) ? 401 : 500,
    );
  }
});

async function sendMetaEvent(connection: ConnectionRuntime, event: QueueEvent) {
  const accessToken = String(connection.secret_config?.access_token || "");
  const pixelId = String(
    connection.secret_config?.pixel_id || connection.public_config?.pixel_id ||
      "",
  );
  const apiVersion = String(connection.secret_config?.api_version || "v23.0");
  if (!accessToken || !pixelId) {
    throw new Error("Credenciais da Meta incompletas.");
  }

  const userData = await buildHashedUserData(event.payload);
  const payload: Record<string, unknown> = {
    data: [{
      event_name: event.event_name,
      event_time: Math.floor(new Date(event.event_at).getTime() / 1000),
      event_id: event.id,
      action_source: "physical_store",
      user_data: {
        ...userData.meta,
        ...(event.payload?.fbc ? { fbc: event.payload.fbc } : {}),
        ...(event.payload?.fbp ? { fbp: event.payload.fbp } : {}),
      },
      custom_data: {
        value: Number(event.payload?.value || 0),
        currency: String(event.payload?.currency || "BRL"),
        order_id: String(event.payload?.order_id || event.lead_id),
      },
    }],
  };
  const testCode = String(connection.secret_config?.test_event_code || "");
  if (testCode) payload.test_event_code = testCode;

  const response = await fetch(
    `https://graph.facebook.com/${apiVersion}/${
      encodeURIComponent(pixelId)
    }/events?access_token=${encodeURIComponent(accessToken)}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    },
  );
  return readProviderResponse(response);
}

async function sendGoogleEvent(
  connection: ConnectionRuntime,
  event: QueueEvent,
) {
  const accessToken = String(connection.secret_config?.access_token || "");
  const operatingAccountId = String(
    connection.public_config?.operating_account_id ||
      connection.account_external_id || "",
  );
  const loginAccountId = String(
    connection.public_config?.login_account_id || operatingAccountId,
  );
  const conversionActionId = String(
    connection.public_config?.conversion_action_id || "",
  );
  if (!accessToken || !operatingAccountId || !conversionActionId) {
    throw new Error("Credenciais ou destino do Google incompletos.");
  }

  const userData = await buildHashedUserData(event.payload);
  const adIdentifiers = compactObject({
    gclid: event.payload?.gclid,
    gbraid: event.payload?.gbraid,
    wbraid: event.payload?.wbraid,
  });
  const hasConsent = Boolean(event.payload?.marketing_consent);
  const requestBody = {
    destinations: [{
      reference: "purchase_destination",
      loginAccount: { accountId: loginAccountId, accountType: "GOOGLE_ADS" },
      operatingAccount: {
        accountId: operatingAccountId,
        accountType: "GOOGLE_ADS",
      },
      productDestinationId: conversionActionId,
    }],
    events: [{
      destinationReferences: ["purchase_destination"],
      transactionId: String(event.payload?.order_id || event.id),
      eventTimestamp: new Date(event.event_at).toISOString(),
      eventSource: "IN_STORE",
      currency: String(event.payload?.currency || "BRL"),
      conversionValue: Number(event.payload?.value || 0),
      conversionCount: 1,
      ...(Object.keys(adIdentifiers).length ? { adIdentifiers } : {}),
      ...(userData.google.length
        ? { userData: { userIdentifiers: userData.google } }
        : {}),
      consent: {
        adUserData: hasConsent ? "CONSENT_GRANTED" : "CONSENT_DENIED",
        adPersonalization: hasConsent ? "CONSENT_GRANTED" : "CONSENT_DENIED",
      },
    }],
    encoding: "HEX",
  };

  const response = await fetch(
    "https://datamanager.googleapis.com/v1/events:ingest",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
    },
  );
  return readProviderResponse(response);
}

async function buildHashedUserData(payload: Record<string, unknown>) {
  const email = normalizeEmail(payload?.email);
  const phone = normalizeBrazilPhone(payload?.phone);
  const emailHash = email ? await sha256(email) : "";
  const phoneHash = phone ? await sha256(phone) : "";
  return {
    meta: compactObject({
      em: emailHash ? [emailHash] : undefined,
      ph: phoneHash ? [phoneHash] : undefined,
    }),
    google: [
      ...(emailHash ? [{ emailAddress: emailHash }] : []),
      ...(phoneHash ? [{ phoneNumber: phoneHash }] : []),
    ],
  };
}

function normalizeEmail(value: unknown) {
  return String(value || "").trim().toLowerCase();
}

function normalizeBrazilPhone(value: unknown) {
  const digits = String(value || "").replace(/\D/g, "");
  if (!digits) return "";
  return digits.startsWith("55") ? `+${digits}` : `+55${digits}`;
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

function compactObject(value: Record<string, unknown>) {
  return Object.fromEntries(
    Object.entries(value).filter(([, item]) =>
      item !== null && item !== undefined && item !== ""
    ),
  );
}

function listPendingEvents(
  storeId: string,
  provider: string,
): Promise<QueueEvent[]> {
  const query = new URLSearchParams({
    select: "id,lead_id,event_name,event_at,payload,attempt_count",
    store_id: `eq.${storeId}`,
    provider: `eq.${provider}`,
    status: "in.(pending,failed)",
    next_attempt_at: `lte.${new Date().toISOString()}`,
    order: "created_at.asc",
    limit: "50",
  });
  return serviceRest<QueueEvent[]>(`marketing_conversion_queue?${query}`);
}

function updateQueueEvent(id: string, payload: Record<string, unknown>) {
  return serviceRest(
    `marketing_conversion_queue?id=eq.${encodeURIComponent(id)}`,
    {
      method: "PATCH",
      body: JSON.stringify(payload),
      headers: { Prefer: "return=minimal" },
    },
  );
}

function serviceRpc<T>(
  name: string,
  payload: Record<string, unknown>,
): Promise<T> {
  return serviceRest<T>(`rpc/${name}`, {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

async function serviceRest<T = unknown>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(data?.message || data?.error || "Falha no Supabase.");
  }
  return data as T;
}

async function readProviderResponse(response: Response) {
  const text = await response.text();
  let data: Record<string, unknown> | null = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }
  if (!response.ok) {
    const nestedError = data?.error as Record<string, unknown> | undefined;
    throw new Error(
      String(
        nestedError?.message || data?.message || text ||
          "O provedor recusou a conversão.",
      ),
    );
  }
  return data;
}

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}
