// Worker: delivers queued push notifications through Firebase Cloud Messaging (HTTP v1).
// Triggered by pg_cron with x-cron-secret. If FCM is not configured, deliveries are
// marked "skipped_not_configured" — never "delivered". In-app notifications always work.
import { isCronAuthorized, json, serviceClient } from "../_shared/util.ts";

async function googleAccessToken(sa: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const enc = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const unsigned = `${enc({ alg: "RS256", typ: "JWT" })}.${enc({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  })}`;
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)));
  const jwt = `${unsigned}.${btoa(String.fromCharCode(...sig)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error("google_token_failed");
  return body.access_token;
}

Deno.serve(async (req) => {
  if (!isCronAuthorized(req)) return json(req, 401, { error: "unauthorized" });
  const db = serviceClient();
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  const { data: batch, error } = await db.rpc("claim_push_batch", { p_limit: 50 });
  if (error) return json(req, 500, { error: "claim_failed" });
  if (!batch?.length) return json(req, 200, { processed: 0 });

  if (!raw) {
    for (const b of batch) await db.rpc("complete_push", { p_log_id: b.log_id, p_status: "skipped_not_configured", p_error: "FCM not configured" });
    return json(req, 200, { processed: batch.length, status: "skipped_not_configured" });
  }

  const sa = JSON.parse(raw);
  const token = await googleAccessToken(sa);
  let delivered = 0;
  for (const b of batch) {
    const tokens = (b.tokens ?? []) as Array<{ token: string; locale: string }>;
    if (!tokens.length) { await db.rpc("complete_push", { p_log_id: b.log_id, p_status: "failed", p_error: "no device token" }); continue; }
    let anyOk = false; let lastErr = "";
    for (const t of tokens) {
      const en = t.locale === "en";
      const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message: {
          token: t.token,
          notification: { title: en ? b.title_en : b.title_ar, body: en ? b.body_en : b.body_ar },
          data: { deep_link: b.deep_link ?? "", notification_id: b.notification_id },
          android: { priority: "high", notification: { channel_id: "myhato_updates" } },
        } }),
      });
      if (res.ok) anyOk = true;
      else {
        lastErr = `HTTP ${res.status}`;
        if (res.status === 404 || res.status === 400) await db.from("device_tokens").delete().eq("token", t.token); // stale token
      }
    }
    // "sent" = accepted by FCM; FCM does not confirm on-device delivery.
    await db.rpc("complete_push", { p_log_id: b.log_id, p_status: anyOk ? "sent" : "failed", p_error: anyOk ? null : lastErr });
    if (anyOk) delivered++;
  }
  return json(req, 200, { processed: batch.length, accepted_by_fcm: delivered });
});
