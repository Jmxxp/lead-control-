import { sha256Hex } from "./crypto.ts";
import { ApiError } from "./response.ts";
import type {
  JsonObject,
  MarketingConnectionRuntime,
  MarketingConversionJob,
  MarketingMetric,
} from "./types.ts";

const providerTimeoutMs = 30_000;
const maxMetaPages = 30;

export class ProviderError extends ApiError {
  provider: "meta" | "google";
  httpStatus: number;

  constructor(
    provider: "meta" | "google",
    message: string,
    httpStatus: number,
    code: string,
    details?: unknown,
    retryable = false,
  ) {
    super(message, providerHttpStatus(httpStatus), code, details, retryable);
    this.name = "ProviderError";
    this.provider = provider;
    this.httpStatus = httpStatus;
  }
}

export type GoogleTokenResult = {
  runtime: MarketingConnectionRuntime;
  secretsPatch: JsonObject | null;
};

export async function ensureGoogleAccessToken(
  runtime: MarketingConnectionRuntime,
  force = false,
): Promise<GoogleTokenResult> {
  if (runtime.provider !== "google") {
    return { runtime, secretsPatch: null };
  }
  const accessToken = stringValue(runtime.secrets.access_token);
  const expiration = Date.parse(
    stringValue(runtime.secrets.access_token_expires_at),
  );
  const stillValid = accessToken && Number.isFinite(expiration) &&
    expiration > Date.now() + 5 * 60_000;
  if (!force && stillValid) return { runtime, secretsPatch: null };

  const clientId = stringValue(runtime.secrets.client_id);
  const clientSecret = stringValue(runtime.secrets.client_secret);
  const refreshToken = stringValue(runtime.secrets.refresh_token);
  if (!clientId || !clientSecret || !refreshToken) {
    if (!force && accessToken && !Number.isFinite(expiration)) {
      return { runtime, secretsPatch: null };
    }
    throw new ProviderError(
      "google",
      "A conexao Google precisa de client_id, client_secret e refresh_token para renovar o acesso.",
      401,
      "google_refresh_credentials_missing",
    );
  }

  const form = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
    grant_type: "refresh_token",
  });
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
    signal: AbortSignal.timeout(providerTimeoutMs),
  });
  const data = await readProviderResponse(response, "google");
  const refreshedToken = stringValue(data.access_token);
  if (!refreshedToken) {
    throw new ProviderError(
      "google",
      "O Google nao devolveu um access_token durante a renovacao.",
      502,
      "google_refresh_response_invalid",
      safeProviderDetails(data),
      true,
    );
  }
  const expiresIn = boundedNumber(data.expires_in, 3600, 60, 86_400);
  const patch: JsonObject = {
    access_token: refreshedToken,
    access_token_expires_at: new Date(
      Date.now() + expiresIn * 1000,
    ).toISOString(),
    ...(stringValue(data.scope) ? { scope: stringValue(data.scope) } : {}),
    ...(stringValue(data.token_type)
      ? { token_type: stringValue(data.token_type) }
      : {}),
  };
  return {
    runtime: { ...runtime, secrets: { ...runtime.secrets, ...patch } },
    secretsPatch: patch,
  };
}

export function buildGoogleAuthorizationUrl(input: {
  clientId: string;
  redirectUri: string;
  state: string;
}): string {
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.searchParams.set("client_id", input.clientId);
  url.searchParams.set("redirect_uri", input.redirectUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set(
    "scope",
    [
      "https://www.googleapis.com/auth/adwords",
      "https://www.googleapis.com/auth/datamanager",
    ].join(" "),
  );
  url.searchParams.set("access_type", "offline");
  url.searchParams.set("include_granted_scopes", "true");
  url.searchParams.set("prompt", "consent");
  url.searchParams.set("state", input.state);
  return url.toString();
}

export async function exchangeGoogleAuthorizationCode(input: {
  code: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}): Promise<JsonObject> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code: input.code,
      client_id: input.clientId,
      client_secret: input.clientSecret,
      redirect_uri: input.redirectUri,
      grant_type: "authorization_code",
    }),
    signal: AbortSignal.timeout(providerTimeoutMs),
  });
  const data = await readProviderResponse(response, "google");
  if (!stringValue(data.access_token)) {
    throw new ProviderError(
      "google",
      "O Google nao devolveu um access_token.",
      502,
      "google_oauth_response_invalid",
      safeProviderDetails(data),
    );
  }
  const expiresIn = boundedNumber(data.expires_in, 3600, 60, 86_400);
  return {
    access_token: stringValue(data.access_token),
    access_token_expires_at: new Date(
      Date.now() + expiresIn * 1000,
    ).toISOString(),
    ...(stringValue(data.refresh_token)
      ? { refresh_token: stringValue(data.refresh_token) }
      : {}),
    ...(stringValue(data.scope) ? { scope: stringValue(data.scope) } : {}),
    ...(stringValue(data.token_type)
      ? { token_type: stringValue(data.token_type) }
      : {}),
  };
}

export async function testProviderConnection(
  inputRuntime: MarketingConnectionRuntime,
): Promise<{ details: JsonObject; token: GoogleTokenResult }> {
  const token = await ensureGoogleAccessToken(inputRuntime);
  const runtime = token.runtime;
  if (runtime.provider === "meta") {
    const account = metaAdAccount(runtime);
    const datasetId = digitsOnly(
      runtime.public_config.dataset_id || runtime.public_config.pixel_id,
    );
    if (!datasetId) {
      throw new ProviderError(
        "meta",
        "Dataset ID ou Pixel ID nao configurado para a Conversions API.",
        409,
        "meta_dataset_missing",
      );
    }
    const response = await providerFetch(
      `https://graph.facebook.com/${metaVersion(runtime)}/${account}` +
        "?fields=id,name,account_status,currency,timezone_name,business_name",
      {
        headers: { Authorization: `Bearer ${metaAccessToken(runtime)}` },
      },
      "meta",
    );
    // Consultar o ativo com o mesmo token valida que a credencial nao esta
    // limitada apenas a conta de anuncios. O envio real continua protegido
    // pela fila idempotente e e validado pelo endpoint /events no primeiro
    // evento consentido, sem criar um evento artificial durante o teste.
    const dataset = await providerFetch(
      `https://graph.facebook.com/${metaVersion(runtime)}/${datasetId}` +
        "?fields=id,name",
      {
        headers: { Authorization: `Bearer ${metaAccessToken(runtime)}` },
      },
      "meta",
    );
    return {
      token,
      details: {
        account_id: response.id,
        account_name: response.name || response.business_name,
        account_status: response.account_status,
        currency: response.currency,
        timezone: response.timezone_name,
        dataset_id: dataset.id || datasetId,
        dataset_name: dataset.name,
        capi_asset_access: true,
      },
    };
  }

  const rows = await googleAdsSearch(
    runtime,
    [
      "SELECT customer.id, customer.descriptive_name, customer.currency_code, customer.time_zone",
      "FROM customer",
      "LIMIT 1",
    ].join(" "),
  );
  const customer = objectValue(objectValue(rows[0]).customer);
  const conversionActionId = googleConversionActionId(runtime);
  if (!conversionActionId) {
    throw new ProviderError(
      "google",
      "Conversion Action ID obrigatorio para conversoes offline.",
      409,
      "google_conversion_action_missing",
    );
  }
  const conversionRows = await googleAdsSearch(
    runtime,
    [
      "SELECT conversion_action.id, conversion_action.name, conversion_action.status,",
      "conversion_action.type, conversion_action.category, conversion_action.owner_customer",
      "FROM conversion_action",
      `WHERE conversion_action.id = ${conversionActionId}`,
      "LIMIT 1",
    ].join(" "),
  );
  const conversionAction = objectValue(
    objectValue(conversionRows[0]).conversionAction,
  );
  if (!Object.keys(conversionAction).length) {
    throw new ProviderError(
      "google",
      "A acao de conversao nao existe ou nao pertence a conta de conversao acessivel.",
      404,
      "google_conversion_action_not_found",
      { conversion_action_id: conversionActionId },
    );
  }
  const conversionActionType = stringValue(conversionAction.type)
    .toUpperCase();
  if (conversionActionType !== "UPLOAD_CLICKS") {
    throw new ProviderError(
      "google",
      "A acao de conversao precisa ser do tipo UPLOAD_CLICKS para receber conversoes offline.",
      409,
      "google_conversion_action_invalid_type",
      {
        conversion_action_id: conversionActionId,
        conversion_action_type: conversionActionType,
      },
    );
  }
  const conversionOwnerId = digitsOnly(conversionAction.ownerCustomer);
  const operatingAccountId = googleCustomerId(runtime);
  if (conversionOwnerId && conversionOwnerId !== operatingAccountId) {
    throw new ProviderError(
      "google",
      "O Customer ID operacional precisa ser a conta proprietaria da acao de conversao.",
      409,
      "google_conversion_customer_mismatch",
      {
        configured_customer_id: operatingAccountId,
        conversion_owner_customer_id: conversionOwnerId,
        conversion_action_id: conversionActionId,
      },
    );
  }
  return {
    token,
    details: {
      account_id: customer.id || googleCustomerId(runtime),
      account_name: customer.descriptiveName,
      currency: customer.currencyCode,
      timezone: customer.timeZone,
      conversion_action_id: conversionAction.id || conversionActionId,
      conversion_action_name: conversionAction.name,
      conversion_action_status: conversionAction.status,
      conversion_action_type: conversionActionType,
      conversion_action_category: conversionAction.category,
      conversion_owner_customer_id: conversionOwnerId || operatingAccountId,
    },
  };
}

export async function syncProviderMetrics(
  inputRuntime: MarketingConnectionRuntime,
  startDate: string,
  endDate: string,
): Promise<{
  metrics: MarketingMetric[];
  token: GoogleTokenResult;
  providerMetadata: JsonObject;
}> {
  validateDateRange(startDate, endDate);
  const token = await ensureGoogleAccessToken(inputRuntime);
  const runtime = token.runtime;
  if (runtime.provider === "meta") {
    const metrics = await syncMetaMetrics(runtime, startDate, endDate);
    return {
      metrics,
      token,
      providerMetadata: { rows: metrics.length, level: "ad" },
    };
  }
  const metrics = await syncGoogleMetrics(runtime, startDate, endDate);
  return {
    metrics,
    token,
    providerMetadata: { rows: metrics.length, resource: "campaign" },
  };
}

export async function sendOfflineConversion(
  inputRuntime: MarketingConnectionRuntime,
  job: MarketingConversionJob,
): Promise<{ receipt: JsonObject; token: GoogleTokenResult }> {
  const token = await ensureGoogleAccessToken(inputRuntime);
  const runtime = token.runtime;
  if (runtime.provider === "meta") {
    const datasetId = stringValue(
      runtime.public_config.dataset_id || runtime.public_config.pixel_id,
    );
    if (!datasetId) {
      throw new ProviderError(
        "meta",
        "Dataset ID ou Pixel ID nao configurado para enviar conversoes.",
        409,
        "meta_dataset_missing",
      );
    }
    const body = await buildMetaConversionPayload(job, runtime);
    const receipt = await providerFetch(
      `https://graph.facebook.com/${metaVersion(runtime)}/${
        encodeURIComponent(datasetId)
      }/events`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${metaAccessToken(runtime)}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      },
      "meta",
    );
    return { receipt, token };
  }

  const body = await buildGoogleConversionPayload(job, runtime);
  const receipt = await providerFetch(
    "https://datamanager.googleapis.com/v1/events:ingest",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${googleAccessToken(runtime)}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
    "google",
  );
  return { receipt, token };
}

export async function retrieveGoogleConversionStatus(
  inputRuntime: MarketingConnectionRuntime,
  requestId: string,
): Promise<{
  status: "processing" | "success" | "partial" | "failed";
  receipt: JsonObject;
  token: GoogleTokenResult;
}> {
  const token = await ensureGoogleAccessToken(inputRuntime);
  const url = new URL(
    "https://datamanager.googleapis.com/v1/requestStatus:retrieve",
  );
  url.searchParams.set("requestId", requestId);
  const receipt = await providerFetch(
    url.toString(),
    {
      headers: { Authorization: `Bearer ${googleAccessToken(token.runtime)}` },
    },
    "google",
  );
  const destinations = arrayValue(receipt.requestStatusPerDestination).map(
    objectValue,
  );
  const statuses = destinations.map((item) =>
    stringValue(item.requestStatus).toUpperCase()
  );
  let status: "processing" | "success" | "partial" | "failed" = "processing";
  if (statuses.some((value) => value === "FAILED" || value === "FAILURE")) {
    status = "failed";
  } else if (statuses.some((value) => value === "PARTIAL_SUCCESS")) {
    status = "partial";
  } else if (
    statuses.length && statuses.every((value) => value === "SUCCESS")
  ) {
    status = "success";
  }
  return { status, receipt, token };
}

export async function buildMetaConversionPayload(
  job: MarketingConversionJob,
  runtime: MarketingConnectionRuntime,
): Promise<JsonObject> {
  const consent = booleanValue(job.payload.marketing_consent);
  const userData: JsonObject = {};
  if (consent) {
    const email = normalizeEmail(job.payload.email);
    const phone = normalizePhone(job.payload.phone);
    if (email) userData.em = [await sha256Hex(email)];
    if (phone) userData.ph = [await sha256Hex(phone)];
    if (stringValue(job.payload.fbc)) userData.fbc = job.payload.fbc;
    if (stringValue(job.payload.fbp)) userData.fbp = job.payload.fbp;
    if (stringValue(job.payload.external_id)) {
      userData.external_id = [
        await sha256Hex(stringValue(job.payload.external_id)),
      ];
    }
  }
  if (!Object.keys(userData).length) {
    throw new ProviderError(
      "meta",
      "Conversao sem identificador consentido para correspondencia na Meta.",
      422,
      "meta_match_key_missing",
    );
  }
  const event: JsonObject = {
    event_name: mapMetaEventName(job.event_name),
    event_time: Math.floor(Date.parse(job.event_at) / 1000),
    event_id: job.event_id,
    action_source: stringValue(job.payload.action_source) || "physical_store",
    user_data: userData,
    custom_data: compactObject({
      value: finiteNumber(job.payload.value, 0),
      currency: stringValue(job.payload.currency) || "BRL",
      order_id: stringValue(job.payload.order_id) || job.lead_id,
      content_name: stringValue(job.payload.content_name),
    }),
  };
  const payload: JsonObject = { data: [event] };
  const testCode = stringValue(runtime.secrets.test_event_code);
  if (testCode) payload.test_event_code = testCode;
  return payload;
}

export async function buildGoogleConversionPayload(
  job: MarketingConversionJob,
  runtime: MarketingConnectionRuntime,
): Promise<JsonObject> {
  const operatingAccountId = googleCustomerId(runtime);
  const loginAccountId = digitsOnly(
    runtime.public_config.login_customer_id || operatingAccountId,
  );
  const conversionActionId = googleConversionActionId(runtime);
  if (!conversionActionId) {
    throw new ProviderError(
      "google",
      "Conversion Action ID nao configurado para o Google.",
      409,
      "google_conversion_action_missing",
    );
  }
  const consent = booleanValue(job.payload.marketing_consent);
  const userIdentifiers: JsonObject[] = [];
  if (consent) {
    const email = normalizeEmail(job.payload.email);
    const phone = normalizePhone(job.payload.phone);
    if (email) userIdentifiers.push({ emailAddress: await sha256Hex(email) });
    if (phone) userIdentifiers.push({ phoneNumber: await sha256Hex(phone) });
  }
  const adIdentifiers = compactObject({
    gclid: stringValue(job.payload.gclid),
    gbraid: stringValue(job.payload.gbraid),
    wbraid: stringValue(job.payload.wbraid),
  });
  if (!Object.keys(adIdentifiers).length && !userIdentifiers.length) {
    throw new ProviderError(
      "google",
      "Conversao sem click ID ou identificador consentido para o Google.",
      422,
      "google_match_key_missing",
    );
  }
  return {
    destinations: [{
      reference: "google_ads_destination",
      loginAccount: {
        accountId: loginAccountId || operatingAccountId,
        accountType: "GOOGLE_ADS",
      },
      operatingAccount: {
        accountId: operatingAccountId,
        accountType: "GOOGLE_ADS",
      },
      productDestinationId: conversionActionId,
    }],
    events: [{
      destinationReferences: ["google_ads_destination"],
      transactionId: stringValue(job.payload.order_id) || job.event_id,
      eventTimestamp: new Date(job.event_at).toISOString(),
      eventSource: stringValue(job.payload.event_source) || "IN_STORE",
      eventName: mapGoogleEventName(job.event_name),
      currency: stringValue(job.payload.currency) || "BRL",
      conversionValue: finiteNumber(job.payload.value, 0),
      conversionCount: 1,
      ...(Object.keys(adIdentifiers).length ? { adIdentifiers } : {}),
      ...(userIdentifiers.length ? { userData: { userIdentifiers } } : {}),
      consent: {
        adUserData: consent ? "CONSENT_GRANTED" : "CONSENT_DENIED",
        adPersonalization: consent ? "CONSENT_GRANTED" : "CONSENT_DENIED",
      },
    }],
    encoding: "HEX",
  };
}

async function syncMetaMetrics(
  runtime: MarketingConnectionRuntime,
  startDate: string,
  endDate: string,
): Promise<MarketingMetric[]> {
  const account = metaAdAccount(runtime);
  const fields = [
    "date_start",
    "account_id",
    "account_currency",
    "campaign_id",
    "campaign_name",
    "adset_id",
    "adset_name",
    "ad_id",
    "ad_name",
    "spend",
    "impressions",
    "reach",
    "clicks",
    "actions",
    "action_values",
  ].join(",");
  const url = new URL(
    `https://graph.facebook.com/${metaVersion(runtime)}/${account}/insights`,
  );
  url.searchParams.set("fields", fields);
  url.searchParams.set("level", "ad");
  url.searchParams.set("time_increment", "1");
  url.searchParams.set("limit", "500");
  url.searchParams.set(
    "time_range",
    JSON.stringify({
      since: startDate,
      until: endDate,
    }),
  );

  const rows: JsonObject[] = [];
  let nextUrl = url.toString();
  for (let page = 0; nextUrl && page < maxMetaPages; page += 1) {
    const response = await providerFetch(
      nextUrl,
      { headers: { Authorization: `Bearer ${metaAccessToken(runtime)}` } },
      "meta",
    );
    rows.push(...arrayValue(response.data).map(objectValue));
    const candidate = stringValue(objectValue(response.paging).next);
    if (candidate) {
      const parsed = new URL(candidate);
      if (
        parsed.protocol !== "https:" || parsed.hostname !== "graph.facebook.com"
      ) {
        throw new ProviderError(
          "meta",
          "A Meta devolveu uma URL de paginacao invalida.",
          502,
          "meta_pagination_url_invalid",
        );
      }
      // A Meta pode repetir o token na URL de paginacao. Removemos o segredo
      // e continuamos autenticando exclusivamente pelo header Bearer.
      parsed.searchParams.delete("access_token");
      nextUrl = parsed.toString();
    } else {
      nextUrl = "";
    }
  }
  if (nextUrl) {
    throw new ProviderError(
      "meta",
      "A consulta da Meta excedeu o limite seguro de paginacao. Reduza o periodo e tente novamente.",
      503,
      "meta_pagination_limit",
      { pages: maxMetaPages },
      true,
    );
  }
  return rows.map((row) => {
    const actions = arrayValue(row.actions).map(objectValue);
    const values = arrayValue(row.action_values).map(objectValue);
    return {
      metric_date: stringValue(row.date_start),
      provider: "meta" as const,
      account_external_id: stringValue(row.account_id) ||
        digitsOnly(runtime.account_external_id),
      campaign_external_id: stringValue(row.campaign_id),
      campaign_name: stringValue(row.campaign_name),
      adset_external_id: stringValue(row.adset_id),
      adset_name: stringValue(row.adset_name),
      ad_external_id: stringValue(row.ad_id),
      ad_name: stringValue(row.ad_name),
      currency: stringValue(row.account_currency) || "BRL",
      spend: finiteNumber(row.spend),
      impressions: integerNumber(row.impressions),
      reach: integerNumber(row.reach),
      clicks: integerNumber(row.clicks),
      platform_leads: sumMetaActions(actions, [
        "lead",
        "onsite_conversion.lead_grouped",
        "offsite_conversion.fb_pixel_lead",
      ]),
      platform_conversions: sumMetaActions(actions, [
        "purchase",
        "offsite_conversion.fb_pixel_purchase",
        "omni_purchase",
      ]),
      conversion_value: sumMetaActions(values, [
        "purchase",
        "offsite_conversion.fb_pixel_purchase",
        "omni_purchase",
      ]),
      raw_metrics: {
        actions,
        action_values: values,
      },
    };
  }).filter((row) => /^\d{4}-\d{2}-\d{2}$/.test(row.metric_date));
}

async function syncGoogleMetrics(
  runtime: MarketingConnectionRuntime,
  startDate: string,
  endDate: string,
): Promise<MarketingMetric[]> {
  const query = [
    "SELECT segments.date, customer.id, customer.currency_code,",
    "campaign.id, campaign.name, campaign.advertising_channel_type,",
    "metrics.cost_micros, metrics.impressions, metrics.clicks,",
    "metrics.conversions, metrics.conversions_value",
    "FROM campaign",
    `WHERE segments.date BETWEEN '${startDate}' AND '${endDate}'`,
  ].join(" ");
  const rows = await googleAdsSearch(runtime, query);
  return rows.map((raw) => {
    const row = objectValue(raw);
    const segments = objectValue(row.segments);
    const customer = objectValue(row.customer);
    const campaign = objectValue(row.campaign);
    const metrics = objectValue(row.metrics);
    return {
      metric_date: stringValue(segments.date),
      provider: "google" as const,
      account_external_id: stringValue(customer.id) ||
        googleCustomerId(runtime),
      campaign_external_id: stringValue(campaign.id),
      campaign_name: stringValue(campaign.name),
      adset_external_id: "",
      adset_name: "",
      ad_external_id: "",
      ad_name: "",
      currency: stringValue(customer.currencyCode) || "BRL",
      spend: finiteNumber(metrics.costMicros) / 1_000_000,
      impressions: integerNumber(metrics.impressions),
      reach: 0,
      clicks: integerNumber(metrics.clicks),
      platform_leads: 0,
      platform_conversions: finiteNumber(metrics.conversions),
      conversion_value: finiteNumber(metrics.conversionsValue),
      raw_metrics: {
        ...metrics,
        advertising_channel_type: campaign.advertisingChannelType,
      },
    };
  }).filter((row) => /^\d{4}-\d{2}-\d{2}$/.test(row.metric_date));
}

async function googleAdsSearch(
  runtime: MarketingConnectionRuntime,
  query: string,
): Promise<JsonObject[]> {
  const customerId = googleCustomerId(runtime);
  const version = googleVersion(runtime);
  const headers: Record<string, string> = {
    Authorization: `Bearer ${googleAccessToken(runtime)}`,
    "developer-token": requiredSecret(
      runtime,
      "developer_token",
      "Developer Token do Google ausente.",
    ),
    "Content-Type": "application/json",
  };
  const loginCustomerId = digitsOnly(runtime.public_config.login_customer_id);
  if (loginCustomerId) headers["login-customer-id"] = loginCustomerId;
  const response = await providerFetch(
    `https://googleads.googleapis.com/${version}/customers/${customerId}/googleAds:searchStream`,
    { method: "POST", headers, body: JSON.stringify({ query }) },
    "google",
  );
  const chunks = Array.isArray(response) ? response : [response];
  return chunks.flatMap((chunk) =>
    arrayValue(objectValue(chunk).results).map(objectValue)
  );
}

function metaAccessToken(runtime: MarketingConnectionRuntime): string {
  return requiredSecret(
    runtime,
    "access_token",
    "Access Token da Meta ausente.",
  );
}

function googleAccessToken(runtime: MarketingConnectionRuntime): string {
  return requiredSecret(
    runtime,
    "access_token",
    "Access Token do Google ausente. Conecte a conta por OAuth.",
  );
}

function metaAdAccount(runtime: MarketingConnectionRuntime): string {
  const id = digitsOnly(
    runtime.public_config.ad_account_id || runtime.account_external_id,
  );
  if (!id) {
    throw new ProviderError(
      "meta",
      "Ad Account ID da Meta ausente.",
      400,
      "meta_ad_account_missing",
    );
  }
  return `act_${id}`;
}

function googleCustomerId(runtime: MarketingConnectionRuntime): string {
  const id = digitsOnly(
    runtime.public_config.customer_id || runtime.account_external_id,
  );
  if (!id) {
    throw new ProviderError(
      "google",
      "Customer ID do Google Ads ausente.",
      400,
      "google_customer_missing",
    );
  }
  return id;
}

function googleConversionActionId(
  runtime: MarketingConnectionRuntime,
): string {
  const raw = stringValue(runtime.public_config.conversion_action_id);
  const resourceMatch = raw.match(/conversionActions\/(\d+)$/i);
  const id = resourceMatch?.[1] || (/^\d+$/.test(raw) ? raw : "");
  if (!id) {
    throw new ProviderError(
      "google",
      "Conversion Action ID obrigatorio e deve ser numerico.",
      409,
      "google_conversion_action_missing",
    );
  }
  return id;
}

function metaVersion(runtime: MarketingConnectionRuntime): string {
  return normalizeVersion(runtime.api_version, "v26.0", true);
}

function googleVersion(runtime: MarketingConnectionRuntime): string {
  return normalizeVersion(runtime.api_version, "v25", false);
}

function normalizeVersion(
  value: unknown,
  fallback: string,
  allowMinor: boolean,
): string {
  const version = stringValue(value) || fallback;
  const expression = allowMinor ? /^v\d{2,3}(?:\.\d+)?$/ : /^v\d{2,3}$/;
  return expression.test(version) ? version : fallback;
}

function requiredSecret(
  runtime: MarketingConnectionRuntime,
  name: string,
  message: string,
): string {
  const value = stringValue(runtime.secrets[name]);
  if (!value) {
    throw new ProviderError(runtime.provider, message, 400, `${name}_missing`);
  }
  return value;
}

async function providerFetch(
  url: string,
  init: RequestInit,
  provider: "meta" | "google",
): Promise<JsonObject> {
  let response: Response;
  try {
    response = await fetch(url, {
      ...init,
      signal: init.signal || AbortSignal.timeout(providerTimeoutMs),
    });
  } catch (error) {
    throw new ProviderError(
      provider,
      error instanceof Error && error.name === "TimeoutError"
        ? `A API ${provider} excedeu o tempo limite.`
        : `Nao foi possivel acessar a API ${provider}.`,
      503,
      `${provider}_network_error`,
      undefined,
      true,
    );
  }
  return await readProviderResponse(response, provider);
}

async function readProviderResponse(
  response: Response,
  provider: "meta" | "google",
): Promise<JsonObject> {
  const text = await response.text();
  let data: unknown = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { message: text.slice(0, 2000) };
  }
  if (!response.ok) {
    const root = objectValue(data);
    const metaError = objectValue(root.error);
    const googleError = objectValue(root.error);
    const message = stringValue(
      metaError.message || googleError.message || root.message,
    ) || `A API ${provider} recusou a operacao.`;
    const providerCode = stringValue(
      metaError.code || googleError.status || googleError.code,
    );
    const metaCode = Number(metaError.code);
    const retryable = response.status === 408 || response.status === 429 ||
      response.status >= 500 || metaError.is_transient === true ||
      (provider === "meta" && [1, 2, 4, 17, 32, 613].includes(metaCode));
    throw new ProviderError(
      provider,
      message,
      response.status,
      `${provider}_api_error`,
      {
        provider_code: providerCode || undefined,
        provider_subcode: stringValue(metaError.error_subcode) || undefined,
        retry_after: response.headers.get("retry-after") || undefined,
        response: safeProviderDetails(data),
      },
      retryable,
    );
  }
  return data as JsonObject;
}

function safeProviderDetails(value: unknown): unknown {
  if (Array.isArray(value)) return value.slice(0, 10).map(safeProviderDetails);
  if (!value || typeof value !== "object") {
    return typeof value === "string" ? value.slice(0, 2000) : value;
  }
  const result: JsonObject = {};
  for (const [key, item] of Object.entries(value as JsonObject).slice(0, 50)) {
    if (/token|secret|authorization/i.test(key)) result[key] = "[REDACTED]";
    else result[key] = safeProviderDetails(item);
  }
  return result;
}

function sumMetaActions(rows: JsonObject[], names: string[]): number {
  const wanted = new Set(names);
  return rows.reduce(
    (total, row) =>
      wanted.has(stringValue(row.action_type))
        ? total + finiteNumber(row.value)
        : total,
    0,
  );
}

function mapMetaEventName(value: string): string {
  switch (value.toLowerCase()) {
    case "lead_created":
    case "lead":
      return "Lead";
    case "qualified":
      return "QualifiedLead";
    case "scheduled":
      return "Schedule";
    case "visited":
      return "ViewContent";
    case "purchased":
    case "purchase":
      return "Purchase";
    default:
      return value.slice(0, 80) || "Lead";
  }
}

function mapGoogleEventName(value: string): string {
  return value.toLowerCase() === "purchased"
    ? "purchase"
    : value.toLowerCase().replace(/[^a-z0-9_]/g, "_").slice(0, 80);
}

export function normalizeEmail(value: unknown): string {
  return stringValue(value).trim().toLowerCase();
}

export function normalizePhone(value: unknown): string {
  const digits = digitsOnly(value);
  if (!digits) return "";
  return digits.startsWith("55") ? `+${digits}` : `+55${digits}`;
}

export function compactObject(value: JsonObject): JsonObject {
  return Object.fromEntries(
    Object.entries(value).filter(([, item]) =>
      item !== null && item !== undefined && item !== ""
    ),
  );
}

function validateDateRange(startDate: string, endDate: string): void {
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(startDate) ||
    !/^\d{4}-\d{2}-\d{2}$/.test(endDate)
  ) {
    throw new ApiError("Periodo invalido.", 400, "invalid_date_range");
  }
  const start = Date.parse(`${startDate}T00:00:00Z`);
  const end = Date.parse(`${endDate}T00:00:00Z`);
  if (start > end || end - start > 400 * 86_400_000) {
    throw new ApiError(
      "O periodo deve ter no maximo 400 dias.",
      400,
      "date_range_too_large",
    );
  }
}

function objectValue(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(value: unknown): string {
  return typeof value === "string" || typeof value === "number"
    ? String(value).trim()
    : "";
}

function digitsOnly(value: unknown): string {
  return stringValue(value).replace(/\D/g, "");
}

function finiteNumber(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function integerNumber(value: unknown): number {
  return Math.max(0, Math.round(finiteNumber(value)));
}

function boundedNumber(
  value: unknown,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  return Math.min(Math.max(finiteNumber(value, fallback), minimum), maximum);
}

function booleanValue(value: unknown): boolean {
  return value === true || value === 1 ||
    (typeof value === "string" && ["true", "1", "sim", "yes"].includes(
      value.toLowerCase(),
    ));
}

function providerHttpStatus(status: number): number {
  if (
    status === 400 || status === 401 || status === 403 || status === 409 ||
    status === 422 || status === 429
  ) return status;
  if (status >= 500) return 502;
  return 400;
}
