#!/usr/bin/env python3
"""Builds the two pages Google Play asks for: www/privacy.html (privacy policy, Arabic + English, from the text the
owner keeps in the app: application_settings legal_privacy_ar / legal_privacy_en, saved in legal.json) and
www/delete-account.html (how to delete your account and data). Run: python3 site/legal.py"""
import html, json, pathlib, re

here = pathlib.Path(__file__).parent
legal = json.loads((here / "legal.json").read_text(encoding="utf-8"))

def md(text: str) -> str:
    out, inlist = [], False
    for line in text.splitlines():
        line = line.rstrip()
        if line.startswith("- "):
            if not inlist:
                out.append("<ul>"); inlist = True
            out.append(f"<li>{html.escape(line[2:])}</li>"); continue
        if inlist:
            out.append("</ul>"); inlist = False
        if not line:
            continue
        if line.startswith("## "):
            out.append(f"<h2>{html.escape(line[3:])}</h2>")
        elif line.startswith("# "):
            out.append(f"<h1>{html.escape(line[2:])}</h1>")
        else:
            out.append(f"<p>{html.escape(line)}</p>")
    if inlist:
        out.append("</ul>")
    return "\n".join(out)

CSS = """
:root{--bg:#F3F7FC;--surface:#fff;--ink:#0D1B2E;--muted:#5A6B82;--line:#DCE6F2;--navy:#0A2A52;--wave:#BFE6FF;--blue:#1F7FD6}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#06152A;--surface:#0C2240;--ink:#E7F0FA;--muted:#9DB1CB;--line:#1C3A60;--blue:#4FA8F5;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#06152A;--surface:#0C2240;--ink:#E7F0FA;--muted:#9DB1CB;--line:#1C3A60;--blue:#4FA8F5;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:'Tajawal','Poppins',system-ui,'Segoe UI',Arial,sans-serif;font-size:17px;line-height:1.75}
header{background:var(--navy);color:#fff}
header .w{display:flex;align-items:center;gap:12px;padding-block:14px}
header img{width:36px;height:36px;border-radius:10px}
header b{font-family:'Poppins','Tajawal',sans-serif;font-size:20px}
header b span{color:var(--wave)}
header a{color:inherit;text-decoration:none;display:flex;align-items:center;gap:10px}
header nav{margin-inline-start:auto;display:flex;gap:8px}
header nav a{border:1px solid rgba(255,255,255,.25);border-radius:10px;padding:6px 12px;font-size:15px}
.w{max-width:780px;margin:0 auto;padding-inline:16px}
main .w{padding-block:28px 60px}
section{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:22px 24px;margin-bottom:22px}
h1{font-size:28px;line-height:1.3;margin:0 0 8px}
h2{font-size:20px;margin:26px 0 6px}
p,li{color:var(--ink)}
.muted{color:var(--muted)}
ol.steps{padding-inline-start:22px}
ol.steps li{margin-bottom:8px}
.en{direction:ltr;text-align:left;font-family:'Poppins','Tajawal',system-ui,sans-serif;font-size:16px}
footer{color:var(--muted);text-align:center;font-size:14px;padding:20px 16px 40px}
footer a{color:var(--blue)}
"""

def page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<link rel="icon" href="icon-96.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;500;700;800&family=Poppins:wght@400;600;700&display=swap">
<style>{CSS}</style>
</head>
<body>
<header><div class="w"><a href="./"><img src="icon-96.png" alt=""><b>My <span>Hatō</span></b></a>
<nav><a href="privacy.html">الخصوصية</a><a href="delete-account.html">حذف الحساب</a></nav></div></header>
<main><div class="w">
{body}
</div></main>
<footer>My Hatō · <a href="privacy.html">Privacy policy</a> · <a href="delete-account.html">Delete account</a></footer>
</body>
</html>
"""

privacy = page("سياسة الخصوصية – My Hatō",
               f"<section>{md(legal['ar'])}</section>\n<section class=\"en\" lang=\"en\" dir=\"ltr\">{md(legal['en'])}</section>")

contact_ar = legal.get("contact_ar", "")
contact_en = legal.get("contact_en", "")
delete = page("حذف الحساب – My Hatō", f"""
<section>
<h1>حذف حسابك وبياناتك من My Hatō</h1>
<p class="muted">الصفحة دي بتشرح إزاي تطلب حذف حسابك في تطبيق My Hatō والبيانات المرتبطة بيه.</p>
<h2>من داخل التطبيق (الأسرع)</h2>
<ol class="steps">
<li>افتح تطبيق My Hatō وادخل على حسابك.</li>
<li>روح لصفحة «حسابي».</li>
<li>دوس «طلب حذف الحساب» وأكّد.</li>
</ol>
<h2>من غير التطبيق</h2>
<p>لو مش قادر تفتح التطبيق، ابعتلنا طلب حذف من رقم الموبايل أو الإيميل المسجّل بيه الحساب{(': ' + html.escape(contact_ar)) if contact_ar else '، عن طريق رقم الدعم الموجود في التطبيق'}. اكتب في الطلب «حذف حسابي» واسمك ورقمك.</p>
<h2>إيه اللي بيتمسح</h2>
<ul>
<li>بيانات الحساب: الاسم ورقم الموبايل والإيميل وبيانات الدخول.</li>
<li>العناوين والموقع المحفوظ.</li>
<li>النقاط والهدايا والمفضلة.</li>
</ul>
<h2>إيه اللي ممكن يفضل ولمدة قد إيه</h2>
<p>الفواتير وسجلات الطلبات اللي القانون بيلزمنا نحتفظ بيها لأغراض محاسبية وضريبية، بتفضل من غير ما تبقى مربوطة بحساب تقدر تدخل عليه، وبتتمسح بعد انتهاء المدة القانونية. الطلب بيتنفّذ خلال 30 يوم بحد أقصى.</p>
</section>
<section class="en" lang="en" dir="ltr">
<h1>Delete your My Hatō account and data</h1>
<p class="muted">This page explains how to request deletion of your My Hatō account and the data linked to it.</p>
<h2>In the app (fastest)</h2>
<ol class="steps">
<li>Open the My Hatō app and sign in.</li>
<li>Go to "My account".</li>
<li>Tap "Request account deletion" and confirm.</li>
</ol>
<h2>Without the app</h2>
<p>If you cannot open the app, send us a deletion request from the phone number or email registered on the account{(': ' + html.escape(contact_en)) if contact_en else ', through the support number shown in the app'}. Write "Delete my account" with your name and number.</p>
<h2>What is deleted</h2>
<ul>
<li>Account data: name, phone number, email and sign-in data.</li>
<li>Saved addresses and location.</li>
<li>Points, gifts and favourites.</li>
</ul>
<h2>What may be kept, and for how long</h2>
<p>Invoices and order records that the law requires us to keep for accounting and tax purposes are kept without being linked to an account you can sign in to, and are deleted when the legal period ends. Requests are completed within 30 days at most.</p>
</section>
""")

(here / "www" / "privacy.html").write_text(privacy, encoding="utf-8")
(here / "www" / "delete-account.html").write_text(delete, encoding="utf-8")
print("wrote www/privacy.html and www/delete-account.html")
