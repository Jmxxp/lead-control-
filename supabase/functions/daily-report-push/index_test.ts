import {
  buildNotification,
  constantTimeEqual,
  formatCurrencyFromCents,
  handleRequest,
} from "./index.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("compara o segredo sem aceitar prefixos ou tamanhos diferentes", () => {
  assert(constantTimeEqual("segredo-completo", "segredo-completo"), "segredos iguais deveriam passar");
  assert(!constantTimeEqual("segredo", "segredo-completo"), "prefixo nao pode passar");
  assert(!constantTimeEqual("segredo-completo", "segredo-alterado"), "valor diferente nao pode passar");
});

Deno.test("formata centavos como moeda brasileira", () => {
  const formatted = formatCurrencyFromCents(476000);
  assert(formatted.includes("4.760,00"), `moeda inesperada: ${formatted}`);
});

Deno.test("monta notificacao transparente com as tres metricas", () => {
  const payload = JSON.parse(buildNotification({
    delivery_id: "delivery-1",
    endpoint: "https://push.example.test/1",
    p256dh: "key",
    auth: "auth",
    content_encoding: "aes128gcm",
    attempt: 1,
    payload: {
      store_id: "store-1",
      store_name: "Ótica Centro",
      report_date: "2026-09-09",
      revenue_cents: 476000,
      prospections: 12,
      converted_prospections: 4,
      conversion_rate: 33.3,
      url: "./?module=attendances",
    },
  }));

  assert(payload.title === "Resumo diário · Ótica Centro", "titulo incorreto");
  assert(payload.body.includes("4.760,00"), "faturamento ausente");
  assert(payload.body.includes("12 prospecções"), "prospeccoes ausentes");
  assert(payload.body.includes("33,3% de conversão"), "conversao ausente");
  assert(payload.data.storeId === "store-1", "loja ausente");
});

Deno.test("worker recusa chamada sem o segredo do agendador", async () => {
  const response = await handleRequest(new Request("https://example.test", { method: "POST" }));
  assert(response.status === 401, `status inesperado: ${response.status}`);
});
