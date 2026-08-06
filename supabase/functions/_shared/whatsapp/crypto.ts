export async function sha256Hex(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string"
    ? new TextEncoder().encode(value)
    : value;
  const normalized = Uint8Array.from(bytes);
  const digest = await crypto.subtle.digest("SHA-256", normalized.buffer);
  return bytesToHex(new Uint8Array(digest));
}

export async function hmacSha256Hex(
  secret: string,
  value: string | Uint8Array,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = typeof value === "string"
    ? new TextEncoder().encode(value)
    : Uint8Array.from(value);
  const signature = await crypto.subtle.sign("HMAC", key, bytes);
  return bytesToHex(new Uint8Array(signature));
}

export async function verifyMetaSignature(
  rawBody: Uint8Array,
  signatureHeader: string,
  appSecret: string,
): Promise<boolean> {
  if (!signatureHeader.startsWith("sha256=") || !appSecret) return false;
  const supplied = signatureHeader.slice(7).toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(supplied)) return false;
  const expected = await hmacSha256Hex(appSecret, rawBody);
  return constantTimeEqual(expected, supplied);
}

export function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}
