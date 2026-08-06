import { constantTimeEqual, redactSecrets, sha256Hex } from "./crypto.ts";

Deno.test("SHA-256 permanece deterministico", async () => {
  const digest = await sha256Hex("marketing");
  if (
    digest !==
      "e2a530e251d3675034d23f5c5f87f54ec3182a088ba7d13350824794f8e6b76e"
  ) {
    throw new Error(`Digest inesperado: ${digest}`);
  }
});

Deno.test("comparacao constante rejeita segredo diferente", () => {
  if (!constantTimeEqual("segredo", "segredo")) {
    throw new Error("Igual rejeitado.");
  }
  if (constantTimeEqual("segredo", "alterado")) {
    throw new Error("Diferente aceito.");
  }
});

Deno.test("logs removem tokens e client secret", () => {
  const redacted = redactSecrets({
    access_token: "nao-pode-vazar",
    nested: { client_secret: "nem-este", account_id: "123" },
  }) as Record<string, unknown>;
  const serialized = JSON.stringify(redacted);
  if (
    serialized.includes("nao-pode-vazar") || serialized.includes("nem-este")
  ) {
    throw new Error("Segredo vazou no log.");
  }
  if (!serialized.includes("123")) {
    throw new Error("Campo publico foi removido.");
  }
});
