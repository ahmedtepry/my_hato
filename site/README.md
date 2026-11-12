# myhato.com: customer site

A single page (`www/`) with products, product pages and a "download the app" button.
- Products, categories and the latest Android build are read live from Supabase with the public (publishable) key.
  If the connection fails, it shows the copy saved in `snapshot.json`.
- The download button always points to the newest APK in the public `app-updates` bucket (build-apk.yml uploads it).
- Rebuild after editing `src.html`: `python3 site/build.py`

Hosting: upload the `www/` folder to any static host (Cloudflare Pages, Netlify, Vercel), then point the
myhato.com DNS records to that host.
