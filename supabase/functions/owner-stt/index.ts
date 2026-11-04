import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Speech to text for the owner's secretary call: the app records the owner (WAV, base64), Gemini (free key) writes down what he said
// in Egyptian Arabic. Owner only. This replaces the phone's own recognizer, which is unreliable on some phones.

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8" } });

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

  let body: { audio?: string };
  try { body = await req.json(); } catch { return reply(400, { error: "invalid_body" }); }
  const audio = String(body.audio ?? "");
  if (audio.length < 1000 || audio.length > 4_000_000) return reply(400, { error: "bad_audio" });

  const prompt = "ده تسجيل صوتي لمالك محل موبايلات مصري بيكلم السكرتيرة بتاعته. اكتب الكلام ده بالظبط زي ما اتقال بالعربية (لهجة مصرية، بحروف عربي، والأرقام بالأرقام الإنجليزية). لو فيه أسماء منتجات أو أرقام أوردرات زي MH-261030-1014 اكتبها زي ما هي. لو مفيش كلام مفهوم رجّع الكلمة EMPTY بس. رجّع النص فقط من غير أي شرح.";
  const models = ["gemini-2.5-flash-lite", "gemini-flash-lite-latest", "gemini-2.5-flash"];
  for (const model of models) {
    try {
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: "POST",
        headers: { "x-goog-api-key": key, "content-type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ inlineData: { mimeType: "audio/wav", data: audio } }, { text: prompt }] }],
          generationConfig: { maxOutputTokens: 400, temperature: 0, thinkingConfig: { thinkingBudget: 0 } },
        }),
        signal: AbortSignal.timeout(20000),
      });
      if (!r.ok) {
        console.error("stt", model, r.status, (await r.text()).slice(0, 300));
        continue;
      }
      const j = await r.json();
      const text = String(j.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text ?? "").join("") ?? "").trim();
      return reply(200, { text: text === "EMPTY" ? "" : text });
    } catch (e) {
      console.error("stt fetch", model, String(e).slice(0, 150));
    }
  }
  return reply(502, { error: "stt_failed" });
});
