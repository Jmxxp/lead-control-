import { hmacSha256Hex, sha256Hex, verifyMetaSignature } from "./crypto.ts";

Deno.test("sha256 permanece deterministico", async () => {
  const digest = await sha256Hex("whatsapp");
  if (
    digest !==
      "ec8202b6f9fb16f9e26b66367afa4e037752f3c09a18cefab426165e06a424b1"
  ) {
    throw new Error(`Digest inesperado: ${digest}`);
  }
});

Deno.test("appsecret_proof usa HMAC SHA-256", async () => {
  const proof = await hmacSha256Hex("app-secret-de-teste", "whatsapp");
  if (
    proof !==
      "5547f84645ff946cb3afe1caaee50898a5f3dd75f8739d0529193a53390a96b5"
  ) {
    throw new Error(`App secret proof inesperado: ${proof}`);
  }
});

Deno.test("assinatura HMAC do webhook aceita somente o corpo exato", async () => {
  const secret = "app-secret-de-teste";
  const raw = new TextEncoder().encode(
    '{"object":"whatsapp_business_account"}',
  );
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, Uint8Array.from(raw).buffer),
  );
  const hex = Array.from(
    signature,
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  if (!await verifyMetaSignature(raw, `sha256=${hex}`, secret)) {
    throw new Error("Assinatura valida foi recusada.");
  }
  const changed = new TextEncoder().encode('{"object":"alterado"}');
  if (await verifyMetaSignature(changed, `sha256=${hex}`, secret)) {
    throw new Error("Corpo adulterado foi aceito.");
  }
});
