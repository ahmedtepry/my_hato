// Minimal Paymob (Egypt) client for Edge Functions. Secrets never leave the server.
export class PaymobError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}

export const paymobBase = () => (Deno.env.get("PAYMOB_API_BASE") ?? "https://accept.paymob.com").replace(/\/$/, "");
export const checkoutBase = () => Deno.env.get("PAYMOB_CHECKOUT_BASE") ?? "https://eg.checkout.paymob.com/";

export function missingPaymobSecrets(): string[] {
  return ["PAYMOB_SECRET_KEY", "PAYMOB_PUBLIC_KEY", "PAYMOB_HMAC_SECRET", "PAYMOB_INTEGRATION_IDS"].filter((k) => !Deno.env.get(k));
}

export function integrationIds(envName = "PAYMOB_INTEGRATION_IDS"): number[] {
  return (Deno.env.get(envName) ?? "").split(",").map((s) => parseInt(s.trim(), 10)).filter((n) => Number.isInteger(n) && n > 0);
}

export function checkoutUrl(clientSecret: string): string {
  const pk = Deno.env.get("PAYMOB_PUBLIC_KEY") ?? "";
  return `${checkoutBase()}?publicKey=${encodeURIComponent(pk)}&clientSecret=${encodeURIComponent(clientSecret)}`;
}

/** Calls Paymob with the secret key ("Authorization: Token <secret>"). */
export async function paymob<T = Record<string, unknown>>(path: string, body: unknown, auth: "secret" | "none" = "secret"): Promise<T> {
  const secret = Deno.env.get("PAYMOB_SECRET_KEY");
  if (auth === "secret" && !secret) throw new PaymobError(503, "PROVIDER_NOT_CONFIGURED", "PAYMOB_SECRET_KEY is not set");
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (auth === "secret") headers.Authorization = `Token ${secret}`;
  const res = await fetch(`${paymobBase()}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    // keep only a short code, never echo request data into logs
    const code = typeof json?.detail === "string" ? "paymob_" + res.status : (json?.code ?? `paymob_${res.status}`);
    throw new PaymobError(res.status, String(code), "Paymob request failed");
  }
  return json as T;
}
