// Called by the build pipeline (never by the app): uploads a new Windows (.exe) or Android (.apk) build to the public "app-updates" bucket and registers it.
// Protected by a shared secret whose SHA-256 is stored in app_update_keys. Two steps:
//   { action: "prepare", platform, build }                  -> a signed upload URL for the installer file
//   { action: "publish", platform, build, sha256, notes, url } -> checks the file is there and registers the build
// Apps download from `url` (GitHub Releases: free, no download limit). The Supabase copy is only for apps older than
// that and for a GitHub outage, so after each publish every older file of that platform is deleted from Storage
// (the Free plan has 1 GB; 4.7 GB of old installers got the project restricted in Nov 2026).
import { corsHeaders, json, serviceClient, sha256Hex } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });
  const got = req.headers.get("x-push-secret") ?? "";
  const db = serviceClient();
  if (got.length < 32) return json(req, 401, { error: "unauthorized" });
  const { data: key } = await db.from("app_update_keys").select("key_hash").eq("key_hash", await sha256Hex(got)).maybeSingle();
  if (!key) return json(req, 401, { error: "unauthorized" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  // Big model files the Windows team app downloads on first use of Face ID (kept out of the installer: uploads over 50 MB are refused).
  if (body.action === "prepare_asset") {
    const name = String(body.name ?? "");
    if (!["face_detection_yunet_2023mar.onnx", "face_recognition_sface_2021dec.onnx"].includes(name)) return json(req, 400, { error: "invalid_input" });
    const path = `face/${name}`;
    const { data, error } = await db.storage.from("app-updates").createSignedUploadUrl(path, { upsert: true });
    if (error || !data) return json(req, 400, { error: "prepare_failed", detail: error?.message });
    return json(req, 200, { ok: true, path, url: data.signedUrl, token: data.token });
  }
  const platform = String(body.platform ?? "windows");
  const build = Number(body.build);
  if (!["windows", "android", "android_owner"].includes(platform) || !Number.isInteger(build) || build < 1 || build > 10000000) return json(req, 400, { error: "invalid_input" });
  const fileName = platform === "android" ? `MyHato-${build}.apk` : platform === "android_owner" ? `MyHatoOwner-${build}.apk` : `MyHatoTeam-Setup-${build}.exe`;
  const path = `${platform}/${fileName}`;

  if (body.action === "prepare") {
    const { data, error } = await db.storage.from("app-updates").createSignedUploadUrl(path, { upsert: true });
    if (error || !data) return json(req, 400, { error: "prepare_failed", detail: error?.message });
    return json(req, 200, { ok: true, path, url: data.signedUrl, token: data.token });
  }
  if (body.action === "publish") {
    const sha256 = String(body.sha256 ?? "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(sha256)) return json(req, 400, { error: "invalid_sha256" });
    const { data: files } = await db.storage.from("app-updates").list(platform, { search: fileName });
    const f = (files ?? []).find((x) => x.name === fileName);
    if (!f) return json(req, 400, { error: "file_missing" });
    const size = Number(f.metadata?.size ?? 0) || null;
    const url = typeof body.url === "string" && body.url.startsWith("https://github.com/ahmedtepry/my_hato/releases/download/") ? body.url : null;
    const { error } = await db.from("app_releases").upsert(
      { platform, build, path, sha256, size_bytes: size, notes: String(body.notes ?? "").slice(0, 300) || null, url },
      { onConflict: "platform,build" },
    );
    if (error) return json(req, 400, { error: "register_failed", detail: error.message });
    // keep only this build's file on Storage
    const { data: all } = await db.storage.from("app-updates").list(platform, { limit: 1000 });
    const old = (all ?? []).map((x) => `${platform}/${x.name}`).filter((p) => p !== path);
    let removed = 0;
    if (old.length) {
      const { data: gone } = await db.storage.from("app-updates").remove(old);
      removed = gone?.length ?? 0;
    }
    return json(req, 200, { ok: true, build, path, url, removed });
  }
  return json(req, 400, { error: "unknown_action" });
});
