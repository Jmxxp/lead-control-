const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-app-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type RuntimeConfig = {
  admin_user_id: string;
  user_id: string;
  user_role: string;
  provider: "gemini" | "deepseek";
  model: string;
  api_key: string;
  system_prompt: string;
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

  const startedAt = Date.now();
  try {
    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error("Função de IA sem configuração do Supabase.");
    }
    const sessionToken = request.headers.get("x-app-session")?.trim() || "";
    if (!sessionToken) {
      return jsonResponse({ error: "Sessão obrigatória." }, 401);
    }

    const body = await request.json().catch(() => ({}));
    const action = body?.action === "validate" ? "validate" : "chat";
    const configRows = await serviceRpc<RuntimeConfig[]>(
      "lc_ai_runtime_config",
      {
        p_session_token: sessionToken,
      },
    );
    const config = configRows?.[0];
    if (!config?.api_key) {
      return jsonResponse({
        error: "A IA ainda não foi configurada pelo administrador.",
      }, 409);
    }

    if (action === "validate") {
      const validationResponse = config.provider === "gemini"
        ? await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/${
            encodeURIComponent(config.model)
          }?key=${encodeURIComponent(config.api_key)}`,
        )
        : await fetch("https://api.deepseek.com/models", {
          headers: { Authorization: `Bearer ${config.api_key}` },
        });
      if (!validationResponse.ok) return providerError(validationResponse);
      return jsonResponse({
        ok: true,
        provider: config.provider,
        model: config.model,
      });
    }

    const messages = sanitizeMessages(body?.messages);
    const context = sanitizeContext(body?.context);
    if (!messages.length) {
      return jsonResponse({ error: "Envie uma mensagem para a IA." }, 400);
    }

    const systemPrompt = [
      config.system_prompt,
      "Você recebeu somente métricas agregadas e anonimizadas de uma única loja.",
      "Nunca invente dados ausentes. Diferencie fatos, inferências e recomendações.",
      "Quando a amostra for menor que 30 leads, sinalize baixa confiança.",
      "Priorize ações mensuráveis com impacto esperado, evidência usada e próximo passo.",
      `CONTEXTO_AGREGADO:\n${JSON.stringify(context)}`,
    ].join("\n\n");

    const upstream = config.provider === "gemini"
      ? await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${
          encodeURIComponent(config.model)
        }:streamGenerateContent?alt=sse&key=${
          encodeURIComponent(config.api_key)
        }`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: systemPrompt }] },
            contents: messages.map((message) => ({
              role: message.role === "assistant" ? "model" : "user",
              parts: [{ text: message.content }],
            })),
            generationConfig: { temperature: 0.25 },
          }),
        },
      )
      : await fetch("https://api.deepseek.com/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${config.api_key}`,
        },
        body: JSON.stringify({
          model: config.model,
          messages: [
            { role: "system", content: systemPrompt },
            ...messages,
          ],
          stream: true,
          temperature: 0.25,
        }),
      });

    if (!upstream.ok) {
      await logUsage(
        config,
        body?.store_id,
        action,
        messages,
        context,
        Date.now() - startedAt,
        "error",
      );
      return providerError(upstream);
    }

    await logUsage(
      config,
      body?.store_id,
      action,
      messages,
      context,
      Date.now() - startedAt,
      "success",
    );
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        ...corsHeaders,
        "Content-Type": upstream.headers.get("content-type") ||
          "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache, no-transform",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Não foi possível executar a análise.";
    const status = /sess[aã]o|permiss[aã]o/i.test(message) ? 401 : 500;
    return jsonResponse({ error: message }, status);
  }
});

function sanitizeMessages(value: unknown) {
  if (!Array.isArray(value)) return [];
  let totalLength = 0;
  return value.slice(-24).flatMap((item) => {
    const role = item?.role === "assistant"
      ? "assistant"
      : item?.role === "user"
      ? "user"
      : null;
    const content = typeof item?.content === "string"
      ? item.content.trim().slice(0, 6000)
      : "";
    if (!role || !content || totalLength + content.length > 42000) return [];
    totalLength += content.length;
    return [{ role, content }];
  });
}

function sanitizeContext(value: unknown) {
  const serialized = JSON.stringify(
    value && typeof value === "object" ? value : {},
  );
  if (serialized.length > 90000) {
    throw new Error(
      "O recorte de análise ficou grande demais. Reduza o período.",
    );
  }
  return JSON.parse(serialized);
}

async function serviceRpc<T>(
  name: string,
  payload: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(
      data?.message || data?.error || "Falha de autorização no Supabase.",
    );
  }
  return data as T;
}

async function logUsage(
  config: RuntimeConfig,
  storeId: unknown,
  kind: string,
  messages: Array<{ role: string; content: string }>,
  context: unknown,
  latencyMs: number,
  status: string,
) {
  const inputSize = JSON.stringify({ messages, context }).length;
  await serviceRpc("lc_log_ai_usage", {
    p_admin_user_id: config.admin_user_id,
    p_user_id: config.user_id,
    p_store_id: typeof storeId === "string" && storeId ? storeId : null,
    p_provider: config.provider,
    p_model: config.model,
    p_request_kind: kind,
    p_input_tokens: Math.ceil(inputSize / 4),
    p_output_tokens: null,
    p_latency_ms: latencyMs,
    p_status: status,
  }).catch(() => null);
}

async function providerError(response: Response) {
  const text = await response.text();
  let message = text;
  try {
    const data = JSON.parse(text);
    message = data?.error?.message || data?.message || text;
  } catch {
    // Mantém o texto retornado pelo provedor.
  }
  return jsonResponse({
    error: message || "O provedor de IA recusou a solicitação.",
  }, response.status || 502);
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
