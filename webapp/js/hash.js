// Content hashing — same role as ContentHash.swift (§5 note 5): change detection and
// cache keys. SHA-256 via the browser's native SubtleCrypto, no dependency needed.
export async function sha256Hex(bytesOrString) {
  const data = typeof bytesOrString === "string"
    ? new TextEncoder().encode(bytesOrString)
    : bytesOrString;
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
