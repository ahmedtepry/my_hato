// Copy to config.js and fill in. Only the PUBLISHABLE anon key goes here —
// the dashboard runs in the browser. All admin power comes from the signed-in
// staff user's role, enforced in Postgres (RLS + permission-checked functions).
// NEVER put the service_role key in this file.
export const SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co";
export const SUPABASE_ANON_KEY = "YOUR_PUBLISHABLE_ANON_KEY";
