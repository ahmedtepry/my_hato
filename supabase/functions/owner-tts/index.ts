import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Text-to-speech for the owner's secretary call. Uses the SAME free Gemini key (GEMINI_API_KEY): a natural Egyptian-Arabic female voice.
// Owner only. Returns a WAV (base64). The app falls back to the phone's own voice if this fails.

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8" } });

const b64ToBytes = (b: string) => Uint8Array.from(atob(b), (c) => c.charCodeAt(0));
function bytesToB64(u: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
  return btoa(s);
}
function wav(pcm: Uint8Array, rate: number): Uint8Array {
  const h = new DataView(new ArrayBuffer(44));
  const w = (o: number, t: string) => { for (let i = 0; i < t.length; i++) h.setUint8(o + i, t.charCodeAt(i)); };
  w(0, "RIFF"); h.setUint32(4, 36 + pcm.length, true); w(8, "WAVE"); w(12, "fmt ");
  h.setUint32(16, 16, true); h.setUint16(20, 1, true); h.setUint16(22, 1, true);
  h.setUint32(24, rate, true); h.setUint32(28, rate * 2, true); h.setUint16(32, 2, true); h.setUint16(34, 16, true);
  w(36, "data"); h.setUint32(40, pcm.length, true);
  const out = new Uint8Array(44 + pcm.length);
  out.set(new Uint8Array(h.buffer), 0); out.set(pcm, 44);
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });
  const url = Deno.env.get("SUPABASE_URL")!;
  const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } }, auth: { persistSession: false, autoRefreshToken: false } });
  const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: who } = await user.auth.getUser();
  const uid = who?.user?.id;
  if (!uid) return reply(401, { error: "unauthorized" });
  const { data: isOwner } = await svc.from("user_roles").select("user_id").eq("user_id", uid).eq("role", "owner").limit(1);
  if (!isOwner?.length) return reply(403, { error: "owner_only" });
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return reply(503, { error: "no_ai_key" });

  let body: { text?: string };
  try { body = await req.json(); } catch { return reply(400, { error: "invalid_body" }); }
  const text = String(body.text ?? "").trim().slice(0, 900);
  if (!text) return reply(400, { error: "empty" });

  const voice = Deno.env.get("GEMINI_TTS_VOICE") ?? "Aoede";
  const style = "اقرئي النص التالي بصوت بنت مصرية شابة، بلهجة مصرية عامية طبيعية جداً، بنبرة دافئة وواثقة وسرعة عادية، من غير تردد ولا تقطيع ولا مبالغة:\n";
  const models = [Deno.env.get("GEMINI_TTS_MODEL") ?? "gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"];
  let last = 0;
  for (const model of models) {
    try {
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: "POST",
        headers: { "x-goog-api-key": key, "content-type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: style + text }] }],
          generationConfig: { responseModalities: ["AUDIO"], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } } },
        }),
        signal: AbortSignal.timeout(30000),
      });
      if (!r.ok) {
        last = r.status;
        console.error("tts", model, r.status, (await r.text()).slice(0, 300));
        continue;
      }
      const j = await r.json();
      const inline = j.candidates?.[0]?.content?.parts?.find((p: { inlineData?: unknown }) => p.inlineData)?.inlineData as { data: string; mimeType?: string } | undefined;
      if (!inline?.data) { console.error("tts no audio", model, JSON.stringify(j).slice(0, 300)); continue; }
      const rate = Number(/rate=(\d+)/.exec(inline.mimeType ?? "")?.[1]) || 24000;
      return reply(200, { audio: bytesToB64(wav(b64ToBytes(inline.data), rate)), mime: "audio/wav" });
    } catch (e) {
      console.error("tts fetch", model, String(e).slice(0, 150));
    }
  }
  return reply(502, { error: last === 429 ? "ai_busy" : "tts_failed" });
});
