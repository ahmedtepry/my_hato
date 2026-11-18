// Nightly upkeep that keeps the project inside the Free plan. Called only by pg_cron (key in Vault, checked by maintenance_key_ok).
// Old photos are removed through the Storage API (an SQL delete would leave the files behind and they would keep counting),
// then the rows that pointed to them are cleared, old logs are pruned and today's usage is recorded (alert to the owner at 70% / 90%).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const key = req.headers.get("x-maintenance-key") ?? "";
  const { data: ok } = await db.rpc("maintenance_key_ok", { p_key: key });
  if (ok !== true) return reply(401, { error: "unauthorized" });

  let files = 0, bytes = 0;
  const byReason: Record<string, number> = {};
  const errors: string[] = [];
  // a few rounds so a big backlog is cleared in one night without one huge request
  for (let round = 0; round < 5; round++) {
    const { data: cand, error } = await db.rpc("storage_cleanup_candidates", { p_limit: 500 });
    if (error) { errors.push(error.message); break; }
    const rows = (cand ?? []) as { bucket: string; path: string; bytes: number; reason: string }[];
    if (!rows.length) break;
    const buckets = new Map<string, typeof rows>();
    for (const r of rows) buckets.set(r.bucket, [...(buckets.get(r.bucket) ?? []), r]);
    let removedThisRound = 0;
    for (const [bucket, list] of buckets) {
      for (let i = 0; i < list.length; i += 100) {
        const chunk = list.slice(i, i + 100);
        const { data: gone, error: rmErr } = await db.storage.from(bucket).remove(chunk.map((c) => c.path));
        if (rmErr) { errors.push(`${bucket}: ${rmErr.message}`); continue; }
        const done = new Set((gone ?? []).map((g: { name: string }) => g.name));
        // the Storage API returns only what it removed; a path that was already gone is cleared too
        const paths = chunk.map((c) => c.path);
        await db.rpc("storage_cleanup_done", { p_bucket: bucket, p_paths: paths });
        for (const c of chunk) {
          if (done.has(c.path)) { files++; bytes += Number(c.bytes) || 0; removedThisRound++; byReason[c.reason] = (byReason[c.reason] ?? 0) + 1; }
        }
      }
    }
    if (removedThisRound === 0) break;
  }
  const { data: pruned } = await db.rpc("prune_logs");
  const { data: usage } = await db.rpc("usage_check");
  await db.rpc("maintenance_record", { p_files: files, p_bytes: bytes, p_rows: Number(pruned) || 0, p_details: { by_reason: byReason, errors, usage } });
  return reply(200, { ok: true, files, bytes, rows_pruned: pruned, usage, errors });
});
