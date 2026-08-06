import type { JsonObject } from "./types.ts";

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

export function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

export function redactSecrets(value: unknown, depth = 0): unknown {
  if (depth > 12) return "[TRUNCATED]";
  if (Array.isArray(value)) {
    return value.map((item) => redactSecrets(item, depth + 1));
  }
  if (!value || typeof value !== "object") return value;
  const result: JsonObject = {};
  for (const [key, item] of Object.entries(value as JsonObject)) {
    if (
      /(?:access|refresh|developer|client)[_-]?token|client[_-]?secret|app[_-]?secret|authorization|credential/i
        .test(key)
    ) {
      result[key] = "[REDACTED]";
    } else {
      result[key] = redactSecrets(item, depth + 1);
    }
  }
  return result;
}

export function randomToken(byteLength = 32): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}
