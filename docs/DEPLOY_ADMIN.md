# Admin dashboard deployment

The dashboard is static files (`admin/`): `index.html`, `app.js`, `i18n.js`, `vendor.js`, `styles.css`, and your `config.js`.

1. `cp admin/config.example.js admin/config.js` and fill in the project URL + **publishable** anon key.
2. Host on any static HTTPS host (Cloudflare Pages, Netlify, Vercel, Firebase Hosting, S3+CloudFront).
3. Add these response headers (example for Netlify `_headers` / Cloudflare Pages `_headers`):
```
/*
  Content-Security-Policy: default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; style-src 'self' https://fonts.googleapis.com 'unsafe-inline'; font-src https://fonts.gstatic.com; img-src 'self' data: blob: https://*.supabase.co; connect-src 'self' https://*.supabase.co wss://*.supabase.co; frame-ancestors 'none'; base-uri 'self'
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  X-Robots-Tag: noindex
```
4. Set Edge Function secret `ADMIN_ALLOWED_ORIGINS=https://admin.your-domain.com` and `ADMIN_DASHBOARD_URL` to the same.
5. Add the dashboard URL to Supabase Auth → URL configuration → Redirect URLs (staff invite links land there).

Access: only users with a row in `user_roles` can use it; everything they do is limited by their role in the database.
