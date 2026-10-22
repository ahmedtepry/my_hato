// Worker: sends queued emails (orders -> sales mailbox, repairs -> service mailbox).
// Triggered every minute by pg_cron (see migration 0007). Requires header x-cron-secret.
// Provider: Resend HTTP API (RESEND_API_KEY, EMAIL_FROM). Without a key, nothing is
// marked as sent — rows stay queued/failed with a clear error.
import { isCronAuthorized, json, serviceClient } from "../_shared/util.ts";
import { renderOrderNew, renderRepairNew, renderRepairResponse, type Rendered } from "../_shared/email_templates.ts";

async function sendViaResend(to: string, r: Rendered): Promise<{ ok: boolean; id?: string; error?: string }> {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("EMAIL_FROM"); // e.g. "My Hatō <orders@yourdomain.com>" (verified domain)
  if (!key || !from) return { ok: false, error: "EMAIL_PROVIDER_NOT_CONFIGURED" };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [to], subject: r.subject, html: r.html, text: r.text }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { ok: false, error: `HTTP ${res.status}: ${body?.message ?? "send failed"}` };
  return { ok: true, id: body?.id };
}

Deno.serve(async (req) => {
  if (!isCronAuthorized(req)) return json(req, 401, { error: "unauthorized" });
  const db = serviceClient();
  await db.rpc("requeue_stuck_emails");
  const { data: batch, error } = await db.rpc("claim_email_batch", { p_limit: 20 });
  if (error) return json(req, 500, { error: "claim_failed" });

  const results: Array<{ id: string; ok: boolean; error?: string }> = [];
  for (const row of batch ?? []) {
    try {
      const { data, error: rErr } = await db.rpc("email_render_data", { p_kind: row.kind, p_payload: row.payload });
      if (rErr || !data) throw new Error("render_data_missing");
      const rendered = row.kind === "order_new" ? renderOrderNew(data)
        : row.kind === "repair_new" ? renderRepairNew(data)
        : row.kind === "repair_customer_response" ? renderRepairResponse(data)
        : null;
      if (!rendered) throw new Error(`unknown kind ${row.kind}`);
      const sent = await sendViaResend(row.to_email, rendered);
      await db.rpc("complete_email", { p_id: row.id, p_ok: sent.ok, p_provider_id: sent.id ?? null, p_error: sent.error ?? null });
      results.push({ id: row.id, ok: sent.ok, error: sent.error });
    } catch (err) {
      await db.rpc("complete_email", { p_id: row.id, p_ok: false, p_provider_id: null, p_error: String(err) });
      results.push({ id: row.id, ok: false, error: "exception" });
    }
  }
  // Log ids/status only — no customer data in logs.
  console.log(JSON.stringify({ processed: results.length, sent: results.filter((r) => r.ok).length }));
  return json(req, 200, { processed: results.length, results });
});
