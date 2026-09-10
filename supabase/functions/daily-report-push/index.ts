import "@supabase/functions-js/edge-runtime.d.ts";
import webpush from "npm:web-push@3.6.7";

type Delivery = {
  delivery_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  content_encoding: "aes128gcm" | "aesgcm";
  payload: {
    store_id: string;
    store_name: string;
    report_date: string;
    revenue_cents: number | string;
    prospections: number | string;
    converted_prospections: number | string;
    conversion_rate: number | string;
    url?: string;
  };
  attempt: number;
};

type DeliveryResult = {
  succeeded: boolean;
  permanent: boolean;
  status: number | null;
  error: string | null;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function constantTimeEqual(left: string, right: string) {
  const encoder = new TextEncoder();
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  const length = Math.max(leftBytes.length, rightBytes.length);
  let difference = leftBytes.length ^ rightBytes.length;

  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] || 0) ^ (rightBytes[index] || 0);
  }

  return difference === 0;
}

function asSafeNumber(value: number | string | undefined) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function formatCurrencyFromCents(value: number | string | undefined) {
  return new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(asSafeNumber(value) / 100);
}

function formatPercent(value: number | string | undefined) {
  return new Intl.NumberFormat("pt-BR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 1,
  }).format(asSafeNumber(value));
}

function pluralizeProspections(value: number) {
  return `${value} ${value === 1 ? "prospecção" : "prospecções"}`;
}

function buildNotification(delivery: Delivery) {
  const report = delivery.payload || ({} as Delivery["payload"]);
  const prospections = Math.max(0, Math.trunc(asSafeNumber(report.prospections)));
  const storeName = String(report.store_name || "Loja").trim() || "Loja";
  const reportDate = String(report.report_date || "");

  return JSON.stringify({
    title: `Resumo diário · ${storeName}`,
    body: `${formatCurrencyFromCents(report.revenue_cents)} vendidos · ${
      pluralizeProspections(prospections)
    } · ${formatPercent(report.conversion_rate)}% de conversão`,
    icon: "./assets/app-icon-192.png",
    badge: "./assets/favicon-32.png",
    tag: `daily-report-${report.store_id}-${reportDate}`,
    renotify: false,
    data: {
      url: report.url || "./?module=attendances",
      storeId: report.store_id,
      reportDate,
    },
  });
}

async function serviceRpc<T>(
  baseUrl: string,
  serviceRoleKey: string,
  functionName: string,
  args: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(
    `${baseUrl.replace(/\/$/, "")}/rest/v1/rpc/${functionName}`,
    {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(args),
    },
  );

  const rawBody = await response.text();
  if (!response.ok) {
    let message = `RPC ${functionName} falhou (${response.status}).`;
    try {
      const parsed = JSON.parse(rawBody);
      message = String(parsed?.message || parsed?.hint || message);
    } catch {
      // Nao inclui resposta arbitraria do servidor nos logs.
    }
    throw new Error(message);
  }

  return (rawBody ? JSON.parse(rawBody) : null) as T;
}

async function completeDelivery(
  baseUrl: string,
  serviceRoleKey: string,
  deliveryId: string,
  result: DeliveryResult,
) {
  await serviceRpc<boolean>(
    baseUrl,
    serviceRoleKey,
    "lc_complete_daily_report_delivery_v1",
    {
      p_delivery_id: deliveryId,
      p_succeeded: result.succeeded,
      p_permanent_failure: result.permanent,
      p_http_status: result.status,
      p_error: result.error,
    },
  );
}

async function sendDelivery(
  delivery: Delivery,
  baseUrl: string,
  serviceRoleKey: string,
) {
  let result: DeliveryResult;

  try {
    await webpush.sendNotification(
      {
        endpoint: delivery.endpoint,
        keys: {
          p256dh: delivery.p256dh,
          auth: delivery.auth,
        },
      },
      buildNotification(delivery),
      {
        TTL: 60 * 60 * 12,
        urgency: "normal",
        contentEncoding: delivery.content_encoding || "aes128gcm",
      },
    );
    result = { succeeded: true, permanent: false, status: 201, error: null };
  } catch (error) {
    const statusValue = Number(
      (error as { statusCode?: unknown })?.statusCode ??
        (error as { status?: unknown })?.status,
    );
    const status = Number.isInteger(statusValue) ? statusValue : null;
    const permanent = status === 404 || status === 410;
    result = {
      succeeded: false,
      permanent,
      status,
      error: permanent
        ? "A assinatura do aparelho expirou ou foi removida."
        : "O provedor Web Push recusou temporariamente o envio.",
    };
  }

  await completeDelivery(
    baseUrl,
    serviceRoleKey,
    delivery.delivery_id,
    result,
  );
  return result;
}

async function handleRequest(request: Request) {
  if (request.method !== "POST") {
    return jsonResponse({ error: "Método não permitido." }, 405);
  }

  const expectedSecret = Deno.env.get("DAILY_REPORT_CRON_SECRET") || "";
  const receivedSecret = request.headers.get("x-cron-secret") || "";
  if (
    expectedSecret.length < 32 ||
    !constantTimeEqual(receivedSecret, expectedSecret)
  ) {
    return jsonResponse({ error: "Não autorizado." }, 401);
  }

  const baseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") || "";
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") || "";
  const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:suporte@example.com";

  if (!baseUrl || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey) {
    return jsonResponse({ error: "Configuração do worker incompleta." }, 503);
  }

  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);

  try {
    const deliveries = await serviceRpc<Delivery[]>(
      baseUrl,
      serviceRoleKey,
      "lc_claim_daily_report_deliveries_v1",
      { p_limit: 50 },
    );

    let sent = 0;
    let failed = 0;
    for (let index = 0; index < deliveries.length; index += 5) {
      const batch = deliveries.slice(index, index + 5);
      const results = await Promise.all(
        batch.map((delivery) => sendDelivery(delivery, baseUrl, serviceRoleKey)),
      );
      sent += results.filter((result) => result.succeeded).length;
      failed += results.filter((result) => !result.succeeded).length;
    }

    return jsonResponse({ ok: true, claimed: deliveries.length, sent, failed });
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Falha inesperada no relatorio diario.";
    console.error("daily-report-push:", message);
    return jsonResponse({ error: "Não foi possível processar o relatório diário." }, 500);
  }
}

if (import.meta.main) Deno.serve(handleRequest);

export {
  asSafeNumber,
  buildNotification,
  constantTimeEqual,
  formatCurrencyFromCents,
  handleRequest,
};
