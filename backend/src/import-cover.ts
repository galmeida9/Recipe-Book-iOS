import { lookup } from "node:dns/promises";
import { AppError, invariant } from "./contracts.js";
import { sanitizeCoverJPEG } from "./images.js";

type Resolver = (hostname: string) => Promise<{ address: string; family: number }[]>;
function publicAddress(address: string, family: number): boolean {
  if (family === 6) {
    const first = Number.parseInt(address.split(":")[0]!, 16);
    return first >= 0x2000 && first <= 0x3fff && !address.toLowerCase().startsWith("2001:db8:");
  }
  const [a, b, c] = address.split(".").map(Number);
  return a !== undefined && b !== undefined && c !== undefined && a > 0 && a < 224 && a !== 10 && a !== 127 &&
    !(a === 100 && b >= 64 && b <= 127) && !(a === 169 && b === 254) && !(a === 172 && b >= 16 && b <= 31) &&
    !(a === 192 && (b === 168 || b === 0 || (b === 0 && c === 2))) &&
    !(a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) && !(a === 203 && b === 0 && c === 113);
}
export async function downloadInstagramCover(raw: string, transport: typeof fetch = fetch,
  resolve: Resolver = hostname => lookup(hostname, { all: true })): Promise<Buffer> {
  let url: URL;
  try { url = new URL(raw); }
  catch { throw new AppError(422, "thumbnail_unavailable", "The video thumbnail URL was invalid."); }
  invariant(url.protocol === "https:" && !url.username && !url.password && !url.port && !url.hash &&
    (url.hostname.endsWith(".cdninstagram.com") || url.hostname.endsWith(".fbcdn.net")),
  422, "thumbnail_unavailable", "The thumbnail did not use an approved Instagram image host.");
  let addresses: Awaited<ReturnType<Resolver>>;
  try { addresses = await resolve(url.hostname); }
  catch { throw new AppError(502, "thumbnail_unavailable", "The thumbnail host was unavailable."); }
  invariant(addresses.length > 0 && addresses.every(item => publicAddress(item.address, item.family)),
    422, "thumbnail_unavailable", "The thumbnail host did not resolve to public addresses.");
  let response: Response;
  try { response = await transport(url, { redirect: "error", signal: AbortSignal.timeout(20_000), headers: { Accept: "image/jpeg" } }); }
  catch { throw new AppError(502, "thumbnail_unavailable", "The video thumbnail could not be downloaded safely."); }
  invariant(response.ok && response.body && response.headers.get("content-type")?.split(";")[0] === "image/jpeg" &&
    Number(response.headers.get("content-length") ?? 0) <= 2_097_152,
  422, "thumbnail_unavailable", "The thumbnail was unavailable, unsupported, or too large.");
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const part = await reader.read();
      if (part.done) break;
      size += part.value.length;
      invariant(size <= 2_097_152, 422, "thumbnail_unavailable", "The thumbnail exceeded 2 MiB.");
      chunks.push(part.value);
    }
  } finally { await reader.cancel(); }
  return sanitizeCoverJPEG(Buffer.concat(chunks), true);
}
