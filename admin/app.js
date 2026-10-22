// My Hatō — Admin dashboard (vanilla JS, no build step).
// Security model: this page only holds the publishable anon key. Every read is
// filtered by RLS and every write goes through permission-checked SQL functions
// or RLS-guarded tables. Hiding a button here is UX, never the security boundary.
import { createClient } from "./vendor.js";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config.js";
import { STR, ORDER_STATUS, REPAIR_ACTIONS } from "./i18n.js";

const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true } });
const app = document.getElementById("app");

const S = {
  lang: safeGet("admin_lang") === "en" ? "en" : "ar",
  user: null, roles: [], perms: [], labels: {}, repairTransitions: [], orderTransitions: [], channel: null,
};

// ---------------------------------------------------------------- helpers
function safeGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function safeSet(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } }
const t = (k) => STR[S.lang][k] ?? STR.ar[k] ?? k;
const can = (p) => S.perms.includes(p);
const esc = (v) => String(v ?? "").replace(/[&<>"'`]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;", "`": "&#96;" }[c]));
const pick = (row, f) => esc(row?.[`${f}_${S.lang}`] ?? row?.[`${f}_ar`] ?? "");
function money(minor) {
  if (minor == null) return "—";
  const p = Math.trunc(minor / 100), c = Math.abs(minor % 100);
  const s = p.toLocaleString("en-US") + (c ? "." + String(c).padStart(2, "0") : "");
  return S.lang === "ar" ? `${s} ج.م` : `EGP ${s}`;
}
function parseEgp(input) { // -> integer piasters, no floats
  const m = String(input ?? "").trim().replace(/,/g, "").match(/^(\d{1,9})(?:\.(\d{1,2}))?$/);
  return m ? parseInt(m[1], 10) * 100 + parseInt((m[2] ?? "").padEnd(2, "0") || "0", 10) : null;
}
const egpInput = (minor) => (minor == null ? "" : (minor % 100 ? (minor / 100).toFixed(2) : String(minor / 100)));
function fmtDate(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString(S.lang === "ar" ? "ar-EG" : "en-GB", { timeZone: "Africa/Cairo", dateStyle: "medium", timeStyle: "short" });
}
const toLocalInput = (iso) => (iso ? new Date(new Date(iso).getTime() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16) : "");
const fromLocalInput = (v) => (v ? new Date(v).toISOString() : null);
let toastTimer;
function toast(msg, err = false) {
  const el = document.getElementById("toast");
  el.textContent = msg; el.className = "show" + (err ? " err" : "");
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (el.className = ""), 3500);
}
function errMsg(e) {
  const m = e?.message || String(e);
  if (/FORBIDDEN|permission denied|42501|row-level security/i.test(m) || e?.code === "42501") return t("forbidden");
  const known = ["INVALID_TRANSITION", "APPROVAL_REQUIRED", "CANCEL_REASON_REQUIRED", "NOTE_REQUIRED", "QUOTE_NOT_PENDING", "USE_QUOTE_WORKFLOW", "INVALID_AMOUNT", "NOT_A_TECHNICIAN"];
  const k = known.find((x) => m.includes(x));
  return k ? `${k}` : (S.lang === "ar" ? "حصل خطأ، حاول تاني." : "Something went wrong.");
}
async function run(fn, okMsg = t("saved")) {
  try { const r = await fn(); if (okMsg) toast(okMsg); return r; } catch (e) { console.warn(e?.code); toast(errMsg(e), true); throw e; }
}
function chip(text, cls = "") { return `<span class="chip ${cls}">${esc(text)}</span>`; }
function orderChip(s) { const o = ORDER_STATUS[s]; return chip(o ? o[S.lang] : s, o?.c ?? ""); }
function repairLabel(s) { const l = S.labels[s]; return l ? (S.lang === "ar" ? l.label_ar : l.label_en) : s; }
function repairChip(s) {
  const c = ["delivered", "repair_completed", "ready_for_pickup"].includes(s) ? "ok" : ["cancelled", "unrepairable"].includes(s) ? "bad" : ["awaiting_approval", "waiting_for_parts"].includes(s) ? "warn" : "";
  return chip(repairLabel(s), c);
}
function modal(html) {
  return new Promise((resolve) => {
    const bg = document.createElement("div");
    bg.className = "modal-bg";
    bg.innerHTML = `<div class="modal">${html}</div>`;
    document.body.appendChild(bg);
    const close = (v) => { bg.remove(); resolve(v); };
    bg.addEventListener("click", (e) => { if (e.target === bg) close(null); });
    bg.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => close(null)));
    const form = bg.querySelector("form");
    if (form) form.addEventListener("submit", (e) => { e.preventDefault(); close(Object.fromEntries(new FormData(form))); });
    bg.querySelector("input,textarea,select")?.focus();
  });
}
const confirmBox = async (msg) =>
  (await modal(`<form><p>${esc(msg)}</p><div class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary" name="ok" value="1">${t("confirm")}</button></div></form>`)) != null;
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const on = (sel, ev, fn, root = document) => $$(sel, root).forEach((el) => el.addEventListener(ev, fn));

function applyLang() {
  document.documentElement.lang = S.lang;
  document.documentElement.dir = S.lang === "ar" ? "rtl" : "ltr";
}

// ---------------------------------------------------------------- boot / auth
async function boot() {
  applyLang();
  const { data } = await db.auth.getSession();
  db.auth.onAuthStateChange((_e, session) => {
    const had = !!S.user; S.user = session?.user ?? null;
    if (had !== !!S.user) start();
  });
  S.user = data.session?.user ?? null;
  window.addEventListener("hashchange", render);
  await start();
}

async function start() {
  if (!S.user) return renderLogin();
  const { data: ctx, error } = await db.rpc("my_staff_context");
  S.roles = ctx?.roles ?? []; S.perms = ctx?.permissions ?? [];
  if (error || !S.roles.length) { renderLogin(t("notStaff")); return; }
  const [labels, rt, ot] = await Promise.all([
    db.from("repair_status_labels").select("*"),
    db.from("repair_transitions").select("*"),
    db.from("order_transitions").select("*"),
  ]);
  S.labels = Object.fromEntries((labels.data ?? []).map((l) => [l.status, l]));
  S.repairTransitions = rt.data ?? []; S.orderTransitions = ot.data ?? [];
  subscribeLive();
  render();
}

function renderLogin(msg = "") {
  app.innerHTML = `<div class="login"><div class="card">
    <div class="logo">My<b>Hatō</b></div><div class="slogan">YOUR PHONE. OUR PRIORITY.</div>
    ${msg ? `<p class="chip bad">${esc(msg)}</p>` : ""}
    <form id="lf"><label>${t("email")}</label><input name="email" type="email" class="ltr" required autocomplete="username" />
    <label>${t("password")}</label><input name="password" type="password" required autocomplete="current-password" />
    <p><button class="btn primary" style="width:100%">${t("login")}</button></p></form>
    <div class="row"><button class="btn sm" id="lang">${t("lang")}</button>${S.user ? `<span class="spacer"></span><button class="btn sm" id="lo">${t("logout")}</button>` : ""}</div>
  </div></div>`;
  $("#lf").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    const { error } = await db.auth.signInWithPassword({ email: f.email, password: f.password });
    if (error) toast(S.lang === "ar" ? "بيانات الدخول غير صحيحة" : "Invalid credentials", true);
  });
  $("#lang").onclick = () => { S.lang = S.lang === "ar" ? "en" : "ar"; safeSet("admin_lang", S.lang); applyLang(); renderLogin(msg); };
  $("#lo")?.addEventListener("click", () => db.auth.signOut());
}

function subscribeLive() {
  if (S.channel) db.removeChannel(S.channel);
  S.channel = db.channel("admin-live")
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "order_status_history" }, (p) => {
      if (p.new?.to_status === "pending_confirmation" && !p.new?.from_status) toast(S.lang === "ar" ? "🛒 طلب جديد وصل" : "🛒 New order received");
      if (/^#\/(orders)?$/.test(location.hash || "#/")) render();
    })
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "repair_status_history" }, (p) => {
      if (p.new?.to_status === "pickup_requested" && !p.new?.from_status) toast(S.lang === "ar" ? "🔧 طلب صيانة جديد" : "🔧 New repair request");
      if (/^#\/(repairs)?$/.test(location.hash || "#/")) render();
    })
    .subscribe();
}

// ---------------------------------------------------------------- shell
const NAV = [
  ["#/", "dashboard", "📊", null],
  ["#/orders", "orders", "🧾", "orders.view"],
  ["#/repairs", "repairs", "🔧", "repairs.view"],
  ["#/products", "products", "📱", "products.manage"],
  ["#/categories", "categories", "🗂️", "products.manage"],
  ["#/banners", "banners", "🖼️", "banners.manage"],
  ["#/branches", "branches", "🏬", "settings.manage"],
  ["#/customers", "customers", "👥", "customers.view"],
  ["#/staff", "staff", "🛡️", "staff.manage"],
  ["#/payments", "payments", "💳", "orders.view"],
  ["#/payment-settings", "paymentSettings", "🏦", "settings.manage"],
  ["#/admin-card", "adminCard", "🪪", "settings.manage"],
  ["#/emails", "emails", "✉️", "orders.view"],
  ["#/settings", "settings", "⚙️", "settings.manage"],
  ["#/audit", "audit", "📜", "audit.view"],
];

function shell(title, body, extra = "") {
  const hash = location.hash || "#/";
  app.innerHTML = `<div class="layout">
    <aside class="side" id="side"><div class="brand">My<b>Hatō</b></div><nav>
      ${NAV.filter(([, , , p]) => !p || can(p)).map(([h, k, i]) => `<a href="${h}" class="${(h === "#/" ? hash === "#/" || hash === "" : hash.startsWith(h)) ? "active" : ""}">${i} ${t(k)}</a>`).join("")}
    </nav><div class="me">${esc(S.user.email)}<br>${S.roles.map((r) => esc(t(r === "sales" ? "salesRole" : r === "technician" ? "technicianRole" : r))).join("، ")}</div>
    <div class="row" style="padding:12px"><button class="btn sm" id="lang">${t("lang")}</button><button class="btn sm" id="lo">${t("logout")}</button></div></aside>
    <main class="main"><div class="topbar"><button class="btn sm menu-btn" id="menu">☰</button><h1>${esc(title)}</h1>${extra}</div><div id="page">${body}</div></main></div>`;
  $("#lang").onclick = () => { S.lang = S.lang === "ar" ? "en" : "ar"; safeSet("admin_lang", S.lang); applyLang(); render(); };
  $("#lo").onclick = () => db.auth.signOut();
  $("#menu").onclick = () => $("#side").classList.toggle("open");
}

async function render() {
  if (!S.user || !S.roles.length) return;
  const h = (location.hash || "#/").slice(1);
  const parts = h.split("/").filter(Boolean);
  try {
    switch (parts[0] ?? "") {
      case "": return await pageDashboard();
      case "orders": return parts[1] ? await pageOrder(parts[1]) : await pageOrders();
      case "repairs": return parts[1] ? await pageRepair(parts[1]) : await pageRepairs();
      case "products": return parts[1] ? await pageProduct(parts[1]) : await pageProducts();
      case "categories": return await pageCategories();
      case "banners": return await pageBanners();
      case "branches": return await pageBranches();
      case "customers": return await pageCustomers();
      case "staff": return await pageStaff();
      case "emails": return await pageEmails();
      case "payments": return await pagePayments();
      case "payment-settings": return await pagePaymentSettings();
      case "admin-card": return await pageAdminCard();
      case "settings": return await pageSettings();
      case "audit": return await pageAudit();
      default: location.hash = "#/";
    }
  } catch (e) {
    shell("⚠️", `<div class="card empty">${esc(errMsg(e))}</div>`);
  }
}

// ---------------------------------------------------------------- dashboard
async function pageDashboard() {
  const [{ data: s, error }, low, recent] = await Promise.all([
    db.rpc("staff_dashboard_stats"),
    can("products.manage") ? db.from("products").select("id, sku, name_ar, name_en, stock_quantity").eq("status", "published").order("stock_quantity").limit(8) : { data: [] },
    can("audit.view") ? db.from("audit_logs").select("*").order("created_at", { ascending: false }).limit(10) : { data: [] },
  ]);
  if (error) throw error;
  const stat = (k, v, alert = false, href = "") => `<a class="card stat ${alert ? "alert" : ""}" ${href ? `href="${href}"` : ""}><div class="n">${esc(v)}</div><div class="l">${t(k)}</div></a>`;
  shell(t("dashboard"), `
    <div class="grid stats">
      ${stat("totalOrders", s.total_orders, false, "#/orders")}${stat("newToday", s.new_orders_today, false, "#/orders")}
      ${stat("pending", s.pending_orders, s.pending_orders > 0, "#/orders?status=pending_confirmation")}${stat("completed", s.completed_orders)}
      ${stat("sales", money(s.total_sales_minor))}${stat("activeRepairs", s.active_repairs, false, "#/repairs")}
      ${stat("awaitingApproval", s.repairs_awaiting_approval, s.repairs_awaiting_approval > 0, "#/repairs?status=awaiting_approval")}
      ${stat("readyPickup", s.repairs_ready, false, "#/repairs?status=ready_for_pickup")}
      ${stat("lowStock", s.low_stock, s.low_stock > 0, "#/products")}${stat("failedEmails", s.failed_emails, s.failed_emails > 0, "#/emails")}
    </div>
    <div class="grid two" style="margin-top:14px">
      ${can("products.manage") ? `<div class="card"><h3>${t("lowStockList")}</h3><table>${(low.data ?? []).map((p) => `<tr class="click" data-href="#/products/${p.id}"><td>${pick(p, "name")}<br><small class="muted">${esc(p.sku)}</small></td><td>${p.stock_quantity <= 0 ? chip(p.stock_quantity, "bad") : chip(p.stock_quantity, p.stock_quantity <= 5 ? "warn" : "")}</td></tr>`).join("") || `<tr><td class="muted">${t("noData")}</td></tr>`}</table></div>` : ""}
      ${can("audit.view") ? `<div class="card"><h3>${t("recent")}</h3><ul class="timeline">${(recent.data ?? []).map((a) => `<li><b>${esc(a.action)}</b> ${esc(a.entity_type)}<br><small>${fmtDate(a.created_at)}</small></li>`).join("") || `<li class="muted">${t("noData")}</li>`}</ul></div>` : ""}
    </div>`);
  on("tr[data-href]", "click", (e) => (location.hash = e.currentTarget.dataset.href));
}

// ---------------------------------------------------------------- orders
function hashParams() { return new URLSearchParams((location.hash.split("?")[1]) ?? ""); }

async function pageOrders() {
  const p = hashParams(); const status = p.get("status") ?? ""; const q = p.get("q") ?? "";
  let query = db.from("orders").select("id, reference, customer_name, customer_phone, total_minor, status, fulfillment, created_at").order("created_at", { ascending: false }).limit(100);
  if (status) query = query.eq("status", status);
  if (q) query = query.or(`reference.ilike.*${q.replace(/[^\w\-+]/g, "")}*,customer_phone.ilike.*${q.replace(/[^\d+]/g, "")}*`);
  const { data, error } = await query; if (error) throw error;
  shell(t("orders"), `
    <div class="card"><form class="row" id="flt"><select name="status" style="max-width:220px"><option value="">${t("all")}</option>
      ${Object.entries(ORDER_STATUS).map(([k, v]) => `<option value="${k}" ${k === status ? "selected" : ""}>${v[S.lang]}</option>`).join("")}</select>
      <input name="q" placeholder="${t("search")}" value="${esc(q)}" style="max-width:260px" /><button class="btn">🔍</button></form>
    <div class="table-wrap"><table><thead><tr><th>${t("reference")}</th><th>${t("customer")}</th><th>${t("fulfillment")}</th><th>${t("total")}</th><th>${t("status")}</th><th>${t("date")}</th></tr></thead><tbody>
    ${(data ?? []).map((o) => `<tr class="click" data-href="#/orders/${o.id}"><td><b>${esc(o.reference)}</b></td><td>${esc(o.customer_name)}<br><small class="muted ltr">${esc(o.customer_phone)}</small></td>
      <td>${o.fulfillment === "pickup" ? t("pickup") : t("delivery")}</td><td>${money(o.total_minor)}</td><td>${orderChip(o.status)}</td><td>${fmtDate(o.created_at)}</td></tr>`).join("") || `<tr><td colspan="6" class="empty">${t("noData")}</td></tr>`}
    </tbody></table></div></div>`);
  $("#flt").addEventListener("submit", (e) => { e.preventDefault(); const f = new FormData(e.target); location.hash = `#/orders?status=${encodeURIComponent(f.get("status"))}&q=${encodeURIComponent(f.get("q"))}`; });
  on("tr[data-href]", "click", (e) => (location.hash = e.currentTarget.dataset.href));
}

async function pageOrder(id) {
  const { data: o, error } = await db.from("orders").select("*, order_items(*), order_status_history(*), branches(*)").eq("id", id).single();
  if (error) throw error;
  const emails = await db.from("email_outbox").select("kind, to_email, status, attempts, last_error, sent_at").eq("related_id", id);
  const hist = (o.order_status_history ?? []).sort((a, b) => a.created_at.localeCompare(b.created_at));
  const next = S.orderTransitions.filter((x) => x.from_status === o.status && (!x.fulfillment || x.fulfillment === o.fulfillment)).map((x) => x.to_status);
  const a = o.delivery_address;
  shell(`${t("orders")} ${o.reference}`, `
    <div class="grid two">
      <div class="card"><div class="row"><h3 style="margin:0">${esc(o.reference)}</h3><span class="spacer"></span>${orderChip(o.status)}</div>
        <dl class="kv" style="margin-top:12px">
          <dt>${t("date")}</dt><dd>${fmtDate(o.created_at)}</dd>
          <dt>${t("customer")}</dt><dd>${esc(o.customer_name)}</dd>
          <dt>${t("phone")}</dt><dd class="ltr">${esc(o.customer_phone)}</dd>
          <dt>${t("email")}</dt><dd>${esc(o.customer_email ?? "—")}</dd>
          <dt>${t("fulfillment")}</dt><dd>${o.fulfillment === "pickup" ? `${t("pickup")} — ${pick(o.branches, "name")}<br><small>${pick(o.branches, "address")}</small>` : `${t("delivery")}<br><small>${esc([a?.recipient_name, a?.phone, a?.governorate, a?.city, a?.street, a?.building, a?.landmark].filter(Boolean).join(" — "))}</small>`}</dd>
          ${o.delivery_notes ? `<dt>${t("note")}</dt><dd>${esc(o.delivery_notes)}</dd>` : ""}
          <dt>${t("payment")}</dt><dd>${o.payment_method === "cash_on_delivery" ? t("cod") : t("payBranch")} — ${esc(o.payment_status)}</dd>
          <dt>${t("emails")}</dt><dd>${(emails.data ?? []).map((e) => `${chip(e.status, e.status === "sent" ? "ok" : e.status === "failed" ? "bad" : "warn")} <small>${esc(e.to_email)}</small>`).join("<br>") || "—"}</dd>
        </dl></div>
      <div class="card"><h3>${t("actions")}</h3>
        ${can("orders.manage") ? (next.length ? `<div class="actions">${next.map((s) => `<button class="btn ${s === "cancelled" ? "danger" : "primary"}" data-to="${s}">${ORDER_STATUS[s][S.lang]}</button>`).join("")}</div>` : `<p class="muted">${t("noAllowed")}</p>`) : ""}
        <h3 style="margin-top:18px">${t("timeline")}</h3>
        <ul class="timeline">${hist.map((h) => `<li><b>${ORDER_STATUS[h.to_status]?.[S.lang] ?? esc(h.to_status)}</b>${h.note ? ` — ${esc(h.note)}` : ""}<br><small>${fmtDate(h.created_at)}</small></li>`).join("")}</ul></div>
    </div>
    <div class="card" style="margin-top:14px"><h3>${t("items")}</h3><div class="table-wrap"><table>
      <thead><tr><th>${t("name")}</th><th>${t("sku")}</th><th>×</th><th>${t("price")}</th><th>${t("total")}</th></tr></thead><tbody>
      ${(o.order_items ?? []).map((i) => `<tr><td>${pick(i, "name")}${i.variant_name_ar ? ` — ${pick(i, "variant_name")}` : ""}</td><td>${esc(i.sku)}</td><td>${i.quantity}</td><td>${money(i.unit_price_minor)}</td><td>${money(i.line_total_minor)}</td></tr>`).join("")}
      </tbody></table></div>
      <dl class="kv" style="max-width:360px;margin-top:12px;margin-inline-start:auto">
        <dt>${t("subtotal")}</dt><dd>${money(o.subtotal_minor + o.discount_minor)}</dd><dt>${t("discount")}</dt><dd>- ${money(o.discount_minor)}</dd>
        <dt>${t("fee")}</dt><dd>${money(o.delivery_fee_minor)}</dd><dt>${t("total")}</dt><dd style="font-size:18px">${money(o.total_minor)}</dd></dl></div>
    <p><a class="btn" href="#/orders">← ${t("back")}</a></p>`);
  on("[data-to]", "click", async (e) => {
    const to = e.currentTarget.dataset.to;
    let note = null;
    if (to === "cancelled") { const r = await modal(`<form><label>${t("cancelReason")}</label><textarea name="note" required></textarea><p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn danger">${t("confirm")}</button></p></form>`); if (!r) return; note = r.note; }
    else if (!(await confirmBox(`${t("transitionTo")}: ${ORDER_STATUS[to][S.lang]}`))) return;
    await run(() => db.rpc("staff_update_order_status", { p_order_id: id, p_to: to, p_note: note }).then(({ error }) => { if (error) throw error; }));
    render();
  });
}

// ---------------------------------------------------------------- repairs
async function pageRepairs() {
  const p = hashParams(); const status = p.get("status") ?? ""; const q = p.get("q") ?? "";
  let query = db.from("repair_requests").select("id, reference, contact_name, contact_phone, device_brand, device_model, status, estimated_cost_minor, assigned_technician_id, updated_at, callback_requested").order("updated_at", { ascending: false }).limit(100);
  if (status) query = query.eq("status", status);
  if (q) query = query.or(`reference.ilike.*${q.replace(/[^\w\-]/g, "")}*,contact_phone.ilike.*${q.replace(/[^\d+]/g, "")}*`);
  const { data, error } = await query; if (error) throw error;
  shell(t("repairs"), `
    <div class="card"><form class="row" id="flt"><select name="status" style="max-width:240px"><option value="">${t("all")}</option>
      ${Object.values(S.labels).sort((a, b) => a.sort_order - b.sort_order).map((l) => `<option value="${l.status}" ${l.status === status ? "selected" : ""}>${esc(repairLabel(l.status))}</option>`).join("")}</select>
      <input name="q" placeholder="${t("search")}" value="${esc(q)}" style="max-width:260px" /><button class="btn">🔍</button></form>
    <div class="table-wrap"><table><thead><tr><th>${t("reference")}</th><th>${t("customer")}</th><th>${t("device")}</th><th>${t("estCost")}</th><th>${t("status")}</th><th>${t("date")}</th></tr></thead><tbody>
    ${(data ?? []).map((r) => `<tr class="click" data-href="#/repairs/${r.id}"><td><b>${esc(r.reference)}</b>${r.callback_requested ? " 📞" : ""}${r.assigned_technician_id === S.user.id ? " 👤" : ""}</td>
      <td>${esc(r.contact_name)}<br><small class="muted ltr">${esc(r.contact_phone)}</small></td><td>${esc(r.device_brand)} ${esc(r.device_model)}</td>
      <td>${money(r.estimated_cost_minor)}</td><td>${repairChip(r.status)}</td><td>${fmtDate(r.updated_at)}</td></tr>`).join("") || `<tr><td colspan="6" class="empty">${t("noData")}</td></tr>`}
    </tbody></table></div></div>`);
  $("#flt").addEventListener("submit", (e) => { e.preventDefault(); const f = new FormData(e.target); location.hash = `#/repairs?status=${encodeURIComponent(f.get("status"))}&q=${encodeURIComponent(f.get("q"))}`; });
  on("tr[data-href]", "click", (e) => (location.hash = e.currentTarget.dataset.href));
}

async function pageRepair(id) {
  const { data: r, error } = await db.rpc("staff_get_repair", { p_repair_id: id });
  if (error) throw error;
  const canUpdate = can("repairs.manage") || (can("repairs.update_assigned") && r.assigned_technician_id === S.user.id);
  const next = S.repairTransitions.filter((x) => x.from_status === r.status).map((x) => x.to_status).filter((s) => !["awaiting_approval", "repair_approved"].includes(s));
  const pendingQuote = (r.quotes ?? []).find((q) => q.status === "pending");
  const photos = await Promise.all((r.attachments ?? []).map(async (a) => {
    const { data } = await db.storage.from("repair-photos").createSignedUrl(a.storage_path, 300);
    return { url: data?.signedUrl, internal: a.is_internal };
  }));
  let techs = [];
  if (can("repairs.manage")) techs = (await db.rpc("staff_list_technicians")).data ?? [];
  const pa = r.pickup_address;
  const approval = (r.approvals ?? [])[0];
  shell(`${t("repairs")} ${r.reference}`, `
    <div class="grid two">
      <div class="card"><div class="row"><h3 style="margin:0">${esc(r.reference)}</h3><span class="spacer"></span>${repairChip(r.status)}</div>
        <dl class="kv" style="margin-top:12px">
          <dt>${t("customer")}</dt><dd>${esc(r.contact_name)}${r.customer?.phone_verified ? " " + chip(t("verified"), "ok") : ""}</dd>
          <dt>${t("phone")}</dt><dd class="ltr">${esc(r.contact_phone)}${r.customer?.phone && r.customer.phone !== r.contact_phone ? ` / ${esc(r.customer.phone)}` : ""}</dd>
          <dt>${t("email")}</dt><dd>${esc(r.customer?.email ?? "—")}</dd>
          <dt>${t("device")}</dt><dd>${esc(r.device_brand)} ${esc(r.device_model)}</dd>
          <dt>${t("imei")}</dt><dd class="ltr">${esc(r.imei_or_serial ?? "—")}</dd>
          <dt>${t("fault")}</dt><dd>${esc(r.problem_description)}</dd>
          <dt>${t("pickupAddr")}</dt><dd>${pa ? esc([pa.recipient_name, pa.phone, pa.governorate, pa.city, pa.street, pa.building, pa.landmark].filter(Boolean).join(" — ")) : "🏬 " + (S.lang === "ar" ? "تسليم في الفرع" : "Drop-off at branch")}</dd>
          <dt>${t("appointment")}</dt><dd>${r.callback_requested ? "📞 " + t("callback") : fmtDate(r.preferred_pickup_at)}${r.scheduled_pickup_at ? `<br>✅ ${fmtDate(r.scheduled_pickup_at)}` : ""}</dd>
          <dt>${t("received")}</dt><dd>${fmtDate(r.received_at)}</dd>
          <dt>${t("estCost")}</dt><dd>${money(r.estimated_cost_minor)}</dd>
          <dt>${t("apprCost")}</dt><dd>${money(r.approved_cost_minor)}</dd>
          <dt>${t("approval")}</dt><dd>${pendingQuote ? chip(S.lang === "ar" ? "في الانتظار" : "Pending", "warn") : approval ? chip(approval.decision === "approved" ? t("approved") : t("rejected"), approval.decision === "approved" ? "ok" : "bad") + ` <small>${esc(approval.via)} — ${money(approval.quoted_amount_minor)} — ${fmtDate(approval.created_at)}</small>` : "—"}</dd>
          <dt>${t("technician")}</dt><dd>${esc(techs.find((x) => x.user_id === r.assigned_technician_id)?.full_name ?? (r.assigned_technician_id ? "✔" : "—"))}</dd>
          <dt>${t("expected")}</dt><dd>${fmtDate(r.expected_completion_at)}</dd>
          ${r.cancel_reason ? `<dt>${t("cancelReason")}</dt><dd>${esc(r.cancel_reason)}</dd>` : ""}
        </dl>
        ${photos.length ? `<h4>${t("photos")}</h4><div class="photos">${photos.map((p) => `<a href="${esc(p.url)}" target="_blank" rel="noopener"><img src="${esc(p.url)}" alt="" />${p.internal ? "🔒" : ""}</a>`).join("")}</div>` : ""}
      </div>
      <div class="card"><h3>${t("actions")}</h3>
        ${canUpdate ? `
          ${next.length ? `<div class="actions">${next.map((s) => `<button class="btn ${["cancelled", "unrepairable"].includes(s) ? "danger" : "primary"}" data-to="${s}">${esc(REPAIR_ACTIONS[s]?.[S.lang] ?? repairLabel(s))}</button>`).join("")}</div>` : `<p class="muted">${t("noAllowed")}</p>`}
          ${["diagnosis_completed", "awaiting_approval", "repair_in_progress", "waiting_for_parts", "initial_inspection"].includes(r.status) ? `<p><button class="btn success" id="quote">💰 ${t("setQuote")}</button></p>` : `<p class="muted"><small>${t("useQuote")}</small></p>`}
          ${pendingQuote && can("repairs.manage") ? `<p><button class="btn" id="decide">☎️ ${t("recordDecision")}</button></p>` : ""}
          ${can("repairs.manage") ? `<label>${t("assign")}</label><div class="row"><select id="tech"><option value="">—</option>${techs.map((x) => `<option value="${x.user_id}" ${x.user_id === r.assigned_technician_id ? "selected" : ""}>${esc(x.full_name ?? x.email)}</option>`).join("")}</select><button class="btn" id="assign">${t("save")}</button></div>` : ""}
          <form id="det" style="margin-top:12px">
            <label>${t("diagnosis")}</label><textarea name="diagnosis">${esc(r.diagnosis ?? "")}</textarea>
            <label>${t("customerNotes")}</label><textarea name="customer_notes">${esc(r.customer_notes ?? "")}</textarea>
            <div class="card internal" style="padding:10px;margin-top:10px"><label>🔒 ${t("internalNotes")}</label><textarea name="internal_notes">${esc(r.internal_notes ?? "")}</textarea></div>
            <div class="grid two"><div><label>${t("expected")}</label><input type="datetime-local" name="expected_completion_at" value="${toLocalInput(r.expected_completion_at)}" /></div>
            <div><label>${t("appointment")}</label><input type="datetime-local" name="scheduled_pickup_at" value="${toLocalInput(r.scheduled_pickup_at)}" /></div></div>
            <label>${t("imei")}</label><input name="imei_or_serial" class="ltr" value="${esc(r.imei_or_serial ?? "")}" />
            <label>${t("qc")}</label><input name="qc_result" value="${esc(r.qc_result ?? "")}" />
            <label>${t("warranty")}</label><input name="warranty_terms" value="${esc(r.warranty_terms ?? "")}" />
            <p><button class="btn primary">${t("saveDetails")}</button></p>
          </form>` : `<p class="muted">${t("forbidden")}</p>`}
      </div>
    </div>
    <div class="grid two" style="margin-top:14px">
      <div class="card"><h3>${t("history")}</h3><ul class="timeline">${(r.history ?? []).map((h) => `<li><b>${esc(repairLabel(h.to_status))}</b><br>${esc(S.lang === "ar" ? h.customer_message_ar : h.customer_message_en)}<br><small>${fmtDate(h.created_at)}</small></li>`).join("")}</ul>
        <h4>💰</h4><table>${(r.quotes ?? []).map((q) => `<tr><td>${money(q.amount_minor)}</td><td>${chip(q.status, q.status === "approved" ? "ok" : q.status === "rejected" ? "bad" : q.status === "pending" ? "warn" : "muted")}</td><td><small>${esc(q.description ?? "")}</small></td><td><small>${fmtDate(q.created_at)}</small></td></tr>`).join("") || `<tr><td class="muted">—</td></tr>`}</table></div>
      <div class="card"><h3>${t("notifications")}</h3><ul class="timeline">${(r.notifications ?? []).map((n) => `<li>${esc(n.title_ar)}<br><small>${fmtDate(n.created_at)} — ${(n.deliveries ?? []).map((d) => `${esc(d.channel)}: ${esc(d.status)}`).join(" · ")}${n.read_at ? " — 👁️" : ""}</small></li>`).join("") || `<li class="muted">—</li>`}</ul>
        <h4>${t("emails")}</h4>${(r.emails ?? []).map((e) => `<div>${chip(e.status, e.status === "sent" ? "ok" : e.status === "failed" ? "bad" : "warn")} ${esc(e.kind)} → <small>${esc(e.to)}</small></div>`).join("") || "—"}</div>
    </div>
    <p><a class="btn" href="#/repairs">← ${t("back")}</a></p>`);

  on("[data-to]", "click", async (e) => {
    const to = e.currentTarget.dataset.to;
    const needReason = to === "cancelled";
    const res = await modal(`<form><p><b>${t("transitionTo")}:</b> ${esc(repairLabel(to))}</p>
      <label>${needReason ? t("cancelReason") : t("customerNotes") + " (" + (S.lang === "ar" ? "اختياري" : "optional") + ")"}</label>
      <textarea name="note" ${needReason ? "required" : ""}></textarea>
      <p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("confirm")}</button></p></form>`);
    if (!res) return;
    await run(() => db.rpc("staff_update_repair_status", { p_repair_id: id, p_to: to, p_customer_note: res.note || null }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  $("#quote")?.addEventListener("click", async () => {
    const res = await modal(`<form><h3>${t("setQuote")}</h3><label>${t("amountEgp")}</label><input name="amount" inputmode="decimal" class="ltr" required value="${egpInput(r.estimated_cost_minor)}" />
      <label>${t("quoteDesc")}</label><textarea name="desc"></textarea><label>${t("diagnosis")}</label><textarea name="diag">${esc(r.diagnosis ?? "")}</textarea>
      <p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("confirm")}</button></p></form>`);
    if (!res) return;
    const amount = parseEgp(res.amount);
    if (amount == null) return toast("INVALID_AMOUNT", true);
    await run(() => db.rpc("staff_create_repair_quote", { p_repair_id: id, p_amount_minor: amount, p_description: res.desc || null, p_diagnosis: res.diag || null }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  $("#decide")?.addEventListener("click", async () => {
    const res = await modal(`<form><h3>${t("recordDecision")}</h3><p>${money(pendingQuote.amount_minor)}</p>
      <label>${t("status")}</label><select name="decision"><option value="approved">${t("approved")}</option><option value="rejected">${t("rejected")}</option></select>
      <label>${t("note")}</label><textarea name="note" required placeholder="${esc(t("noteRequired"))}"></textarea>
      <p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("confirm")}</button></p></form>`);
    if (!res) return;
    await run(() => db.rpc("staff_record_quote_decision", { p_quote_id: pendingQuote.id, p_decision: res.decision, p_note: res.note }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  $("#assign")?.addEventListener("click", async () => {
    const tech = $("#tech").value; if (!tech) return;
    await run(() => db.rpc("staff_assign_technician", { p_repair_id: id, p_technician_id: tech }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  $("#det")?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    const fields = {
      diagnosis: f.diagnosis, customer_notes: f.customer_notes, internal_notes: f.internal_notes,
      expected_completion_at: fromLocalInput(f.expected_completion_at), scheduled_pickup_at: fromLocalInput(f.scheduled_pickup_at),
      imei_or_serial: f.imei_or_serial, qc_result: f.qc_result, warranty_terms: f.warranty_terms,
    };
    await run(() => db.rpc("staff_update_repair_details", { p_repair_id: id, p_fields: fields }).then(({ error }) => { if (error) throw error; }));
    render();
  });
}

// ---------------------------------------------------------------- products
async function pageProducts() {
  const p = hashParams(); const q = (p.get("q") ?? "").replace(/[^\w\s؀-ۿ\-]/g, "");
  let query = db.from("products").select("id, sku, name_ar, name_en, price_minor, compare_at_price_minor, stock_quantity, status, is_featured, categories(name_ar,name_en)").order("updated_at", { ascending: false }).limit(200);
  if (q) query = query.or(`name_ar.ilike.*${q}*,name_en.ilike.*${q}*,sku.ilike.*${q}*`);
  const { data, error } = await query; if (error) throw error;
  shell(t("products"), `
    <div class="card"><form class="row" id="flt"><input name="q" placeholder="${t("search")}" value="${esc(q)}" style="max-width:300px" /><button class="btn">🔍</button></form>
    <div class="table-wrap"><table><thead><tr><th>${t("name")}</th><th>${t("category")}</th><th>${t("price")}</th><th>${t("stock")}</th><th>${t("status")}</th></tr></thead><tbody>
    ${(data ?? []).map((x) => `<tr class="click" data-href="#/products/${x.id}"><td><b>${pick(x, "name")}</b>${x.is_featured ? " ⭐" : ""}<br><small class="muted">${esc(x.sku)}</small></td><td>${pick(x.categories, "name")}</td>
      <td>${money(x.price_minor)}${x.compare_at_price_minor ? `<br><small class="muted"><s>${money(x.compare_at_price_minor)}</s></small>` : ""}</td>
      <td>${x.stock_quantity <= 0 ? chip(x.stock_quantity, "bad") : x.stock_quantity <= 5 ? chip(x.stock_quantity, "warn") : esc(x.stock_quantity)}</td>
      <td>${chip(t(x.status), x.status === "published" ? "ok" : "muted")}</td></tr>`).join("") || `<tr><td colspan="5" class="empty">${t("noData")}</td></tr>`}
    </tbody></table></div></div>`, `<a class="btn primary" href="#/products/new">＋ ${t("newProduct")}</a>`);
  $("#flt").addEventListener("submit", (e) => { e.preventDefault(); location.hash = `#/products?q=${encodeURIComponent(new FormData(e.target).get("q"))}`; });
  on("tr[data-href]", "click", (e) => (location.hash = e.currentTarget.dataset.href));
}

function slugify(s) { return String(s).toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "p-" + Date.now(); }
function safeFileName(name) { return String(name).toLowerCase().replace(/[^a-z0-9.]+/g, "_").slice(-60); }
const ALLOWED_IMG = ["image/jpeg", "image/png", "image/webp"];

async function pageProduct(id) {
  const isNew = id === "new";
  const [cats, brands] = await Promise.all([db.from("categories").select("id, kind, name_ar, name_en").order("sort_order"), db.from("brands").select("id, name_ar, name_en").order("sort_order")]);
  let p = { status: "draft", keywords: [] };
  if (!isNew) {
    const r = await db.from("products").select("*, product_images(*), product_360_assets(*), product_specifications(*), product_variants(*)").eq("id", id).single();
    if (r.error) throw r.error; p = r.data;
  }
  const imgUrl = (b, path) => db.storage.from(b).getPublicUrl(path).data.publicUrl;
  const sel = (list, cur) => (list ?? []).map((x) => `<option value="${x.id}" ${x.id === cur ? "selected" : ""}>${pick(x, "name")}${x.kind ? ` (${t(x.kind)})` : ""}</option>`).join("");
  shell(isNew ? t("newProduct") : pick(p, "name"), `
    <form id="pf" class="card">
      <div class="grid two">
        <div><label>${t("nameAr")}</label><input name="name_ar" required value="${esc(p.name_ar)}" /></div>
        <div><label>${t("nameEn")}</label><input name="name_en" required class="ltr" value="${esc(p.name_en)}" /></div>
        <div><label>${t("sku")}</label><input name="sku" required class="ltr" value="${esc(p.sku)}" /></div>
        <div><label>${t("model")}</label><input name="model" class="ltr" value="${esc(p.model)}" /></div>
        <div><label>${t("category")}</label><select name="category_id" required><option value=""></option>${sel(cats.data, p.category_id)}</select></div>
        <div><label>${t("brand")}</label><select name="brand_id"><option value=""></option>${sel(brands.data, p.brand_id)}</select></div>
        <div><label>${t("price")}</label><input name="price" required inputmode="decimal" class="ltr" value="${egpInput(p.price_minor)}" /></div>
        <div><label>${t("comparePrice")}</label><input name="compare" inputmode="decimal" class="ltr" value="${egpInput(p.compare_at_price_minor)}" /></div>
        ${isNew ? `<div><label>${t("stock")}</label><input name="stock" type="number" min="0" value="0" /></div>` : ""}
        <div><label>${t("status")}</label><select name="status">${["draft", "published", "archived"].map((s) => `<option value="${s}" ${p.status === s ? "selected" : ""}>${t(s)}</option>`).join("")}</select></div>
      </div>
      <label>${t("descAr")}</label><textarea name="description_ar">${esc(p.description_ar)}</textarea>
      <label>${t("descEn")}</label><textarea name="description_en" class="ltr">${esc(p.description_en)}</textarea>
      <div class="grid two"><div><label>${t("warrantyAr")}</label><input name="warranty_ar" value="${esc(p.warranty_ar)}" /></div><div><label>${t("warrantyEn")}</label><input name="warranty_en" class="ltr" value="${esc(p.warranty_en)}" /></div></div>
      <label>${t("keywords")}</label><input name="keywords" value="${esc((p.keywords ?? []).join(", "))}" />
      <div class="switch"><input type="checkbox" name="is_featured" id="feat" ${p.is_featured ? "checked" : ""} /><label for="feat" style="margin:0">⭐ ${t("featured")}</label></div>
      <p><button class="btn primary">${t("save")}</button> <a class="btn" href="#/products">${t("back")}</a></p>
    </form>
    ${isNew ? "" : `
    <div class="grid two" style="margin-top:14px">
      <div class="card"><h3>${t("adjustStock")} — ${esc(p.stock_quantity)}</h3>
        <form id="sf" class="row"><input name="delta" type="number" required style="max-width:120px" placeholder="+10" /><select name="reason" style="max-width:160px"><option value="restock">${t("restock")}</option><option value="manual_adjust">${t("manual")}</option><option value="correction">${t("correction")}</option></select><input name="note" placeholder="${t("note")}" style="max-width:200px" /><button class="btn primary">${t("save")}</button></form>
        <details style="margin-top:10px"><summary>${t("movements")}</summary><div id="mv" class="muted">…</div></details></div>
      <div class="card"><h3>${t("images")}</h3><div class="thumbs">${(p.product_images ?? []).sort((a, b) => a.sort_order - b.sort_order).map((im) => `<figure><img src="${esc(imgUrl("product-images", im.storage_path))}" alt="" /><button class="btn sm danger" data-delimg="${im.id}" data-path="${esc(im.storage_path)}">✕</button></figure>`).join("")}</div>
        <p><input type="file" id="imgs" accept="image/jpeg,image/png,image/webp" multiple /></p>
        <h3>${t("frames360")} (${(p.product_360_assets ?? []).length})</h3>
        <p><input type="file" id="frames" accept="image/jpeg,image/png,image/webp" multiple /> ${(p.product_360_assets ?? []).length ? `<button class="btn sm danger" id="clear360">${t("delete")}</button>` : ""}</p></div>
      <div class="card"><h3>${t("specs")}</h3><table>${(p.product_specifications ?? []).sort((a, b) => a.sort_order - b.sort_order).map((s) => `<tr><td>${pick(s, "label")}</td><td>${pick(s, "value")}</td><td><button class="btn sm danger" data-delspec="${s.id}">✕</button></td></tr>`).join("")}</table>
        <form id="spf" class="grid two"><input name="label_ar" placeholder="${t("name")} (ع)" required /><input name="value_ar" placeholder="… (ع)" required /><input name="label_en" class="ltr" placeholder="Label (EN)" required /><input name="value_en" class="ltr" placeholder="Value (EN)" required /><button class="btn">${t("add")}</button></form></div>
      <div class="card"><h3>${t("variants")}</h3><table>${(p.product_variants ?? []).map((v) => `<tr><td>${v.color_hex ? `<span style="display:inline-block;width:14px;height:14px;border-radius:50%;background:${esc(/^#[0-9a-f]{6}$/i.test(v.color_hex) ? v.color_hex : "#ccc")}"></span> ` : ""}${pick(v, "name")}<br><small>${esc(v.sku)}</small></td><td>${money(v.price_minor ?? p.price_minor)}</td><td>${esc(v.stock_quantity)}</td><td><button class="btn sm" data-vstock="${v.id}">±</button> <button class="btn sm danger" data-delvar="${v.id}">✕</button></td></tr>`).join("")}</table>
        <form id="vf" class="grid two"><input name="name_ar" placeholder="${t("nameAr")}" required /><input name="name_en" class="ltr" placeholder="${t("nameEn")}" required /><input name="sku" class="ltr" placeholder="SKU" required /><input name="color_hex" class="ltr" placeholder="#0B2D5B" pattern="#[0-9A-Fa-f]{6}" /><input name="price" class="ltr" placeholder="${t("price")}" inputmode="decimal" /><input name="stock" type="number" min="0" placeholder="${t("stock")}" /><button class="btn">${t("add")}</button></form></div>
    </div>`}`);

  $("#pf").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    const price = parseEgp(f.price), compare = f.compare ? parseEgp(f.compare) : null;
    if (price == null || (f.compare && compare == null)) return toast("INVALID_AMOUNT", true);
    const row = {
      name_ar: f.name_ar.trim(), name_en: f.name_en.trim(), sku: f.sku.trim(), model: f.model || null, category_id: f.category_id, brand_id: f.brand_id || null,
      price_minor: price, compare_at_price_minor: compare && compare > price ? compare : null, status: f.status,
      description_ar: f.description_ar || null, description_en: f.description_en || null, warranty_ar: f.warranty_ar || null, warranty_en: f.warranty_en || null,
      keywords: f.keywords.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean), is_featured: !!f.is_featured,
    };
    if (isNew) {
      row.slug = slugify(row.name_en) + "-" + Math.random().toString(36).slice(2, 6);
      row.stock_quantity = Math.max(0, parseInt(f.stock || "0", 10));
      const r = await run(() => db.from("products").insert(row).select("id").single().then(({ data, error }) => { if (error) throw error; return data; }));
      location.hash = `#/products/${r.id}`;
    } else {
      await run(() => db.from("products").update(row).eq("id", id).then(({ error }) => { if (error) throw error; }));
      render();
    }
  });
  if (isNew) return;

  db.from("inventory_movements").select("delta, reason, note, created_at, variant_id").eq("product_id", id).order("created_at", { ascending: false }).limit(30).then(({ data }) => {
    const el = $("#mv"); if (el) el.innerHTML = (data ?? []).map((m) => `<div>${m.delta > 0 ? "+" : ""}${esc(m.delta)} — ${esc(m.reason)} ${m.note ? "— " + esc(m.note) : ""} <small>${fmtDate(m.created_at)}</small></div>`).join("") || t("noData");
  });
  $("#sf").addEventListener("submit", async (e) => {
    e.preventDefault(); const f = Object.fromEntries(new FormData(e.target)); const d = parseInt(f.delta, 10); if (!d) return;
    await run(() => db.rpc("staff_adjust_stock", { p_product_id: id, p_variant_id: null, p_delta: d, p_reason: f.reason, p_note: f.note || null }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  $("#imgs").addEventListener("change", async (e) => {
    const files = [...e.target.files].filter((f) => ALLOWED_IMG.includes(f.type) && f.size <= 5 * 1024 * 1024);
    let order = (p.product_images ?? []).length;
    await run(async () => {
      for (const file of files) {
        const path = `${id}/${Date.now()}_${safeFileName(file.name)}`;
        const up = await db.storage.from("product-images").upload(path, file, { contentType: file.type, upsert: false });
        if (up.error) throw up.error;
        const ins = await db.from("product_images").insert({ product_id: id, storage_path: path, sort_order: order++ });
        if (ins.error) throw ins.error;
      }
    });
    render();
  });
  $("#frames").addEventListener("change", async (e) => {
    const files = [...e.target.files].filter((f) => ALLOWED_IMG.includes(f.type) && f.size <= 3 * 1024 * 1024).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    if (files.length < 12 && !(await confirmBox(S.lang === "ar" ? "أقل من 12 صورة — مش هيظهر كعرض 360° في التطبيق. تكمل؟" : "Fewer than 12 frames — the app will not show a 360° view. Continue?"))) return;
    await run(async () => {
      const start = (p.product_360_assets ?? []).length;
      for (let i = 0; i < files.length; i++) {
        const path = `${id}/f${String(start + i).padStart(3, "0")}_${Date.now()}.${files[i].type.split("/")[1]}`;
        const up = await db.storage.from("product-360").upload(path, files[i], { contentType: files[i].type });
        if (up.error) throw up.error;
        const ins = await db.from("product_360_assets").insert({ product_id: id, storage_path: path, frame_index: start + i });
        if (ins.error) throw ins.error;
      }
    });
    render();
  });
  $("#clear360")?.addEventListener("click", async () => {
    if (!(await confirmBox(t("confirmQ")))) return;
    const paths = (p.product_360_assets ?? []).map((a) => a.storage_path);
    await run(async () => {
      if (paths.length) await db.storage.from("product-360").remove(paths);
      const { error } = await db.from("product_360_assets").delete().eq("product_id", id); if (error) throw error;
    });
    render();
  });
  on("[data-delimg]", "click", async (e) => {
    const { delimg, path } = e.currentTarget.dataset;
    if (!(await confirmBox(t("confirmQ")))) return;
    await run(async () => { await db.storage.from("product-images").remove([path]); const { error } = await db.from("product_images").delete().eq("id", delimg); if (error) throw error; });
    render();
  });
  $("#spf").addEventListener("submit", async (e) => {
    e.preventDefault(); const f = Object.fromEntries(new FormData(e.target));
    await run(() => db.from("product_specifications").insert({ ...f, product_id: id, sort_order: (p.product_specifications ?? []).length }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  on("[data-delspec]", "click", async (e) => { await run(() => db.from("product_specifications").delete().eq("id", e.currentTarget.dataset.delspec).then(({ error }) => { if (error) throw error; })); render(); });
  $("#vf").addEventListener("submit", async (e) => {
    e.preventDefault(); const f = Object.fromEntries(new FormData(e.target));
    const vp = f.price ? parseEgp(f.price) : null; if (f.price && vp == null) return toast("INVALID_AMOUNT", true);
    await run(() => db.from("product_variants").insert({ product_id: id, name_ar: f.name_ar, name_en: f.name_en, sku: f.sku, color_hex: f.color_hex || null, price_minor: vp, stock_quantity: Math.max(0, parseInt(f.stock || "0", 10)), sort_order: (p.product_variants ?? []).length }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  on("[data-delvar]", "click", async (e) => {
    if (!(await confirmBox(t("confirmQ")))) return;
    // deactivate rather than delete (keeps order history references intact)
    await run(() => db.from("product_variants").update({ is_active: false }).eq("id", e.currentTarget.dataset.delvar).then(({ error }) => { if (error) throw error; }));
    render();
  });
  on("[data-vstock]", "click", async (e) => {
    const vid = e.currentTarget.dataset.vstock;
    const r = await modal(`<form><h3>${t("adjustStock")}</h3><label>${t("delta")}</label><input name="delta" type="number" required /><label>${t("reason")}</label><select name="reason"><option value="restock">${t("restock")}</option><option value="manual_adjust">${t("manual")}</option><option value="correction">${t("correction")}</option></select><p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("save")}</button></p></form>`);
    if (!r || !parseInt(r.delta, 10)) return;
    await run(() => db.rpc("staff_adjust_stock", { p_product_id: id, p_variant_id: vid, p_delta: parseInt(r.delta, 10), p_reason: r.reason, p_note: null }).then(({ error }) => { if (error) throw error; }));
    render();
  });
}

// ---------------------------------------------------------------- simple CRUD pages
function crudTable(rows, cols, idAttr) {
  return `<div class="table-wrap"><table><thead><tr>${cols.map((c) => `<th>${esc(c[1])}</th>`).join("")}<th></th></tr></thead><tbody>
    ${rows.map((r) => `<tr>${cols.map((c) => `<td>${c[2] ? c[2](r) : esc(r[c[0]])}</td>`).join("")}<td><button class="btn sm" data-${idAttr}="${r.id}">${t("edit")}</button></td></tr>`).join("") || `<tr><td class="empty" colspan="${cols.length + 1}">${t("noData")}</td></tr>`}
  </tbody></table></div>`;
}

async function editRow(table, row, fields) {
  const html = `<form><h3>${row?.id ? t("edit") : t("add")}</h3>${fields.map(([k, label, type = "text", opts]) =>
    type === "select" ? `<label>${esc(label)}</label><select name="${k}">${opts.map((o) => `<option value="${esc(o[0])}" ${String(row?.[k] ?? "") === String(o[0]) ? "selected" : ""}>${esc(o[1])}</option>`).join("")}</select>`
    : type === "check" ? `<div class="switch"><input type="checkbox" name="${k}" id="f_${k}" ${row?.[k] ?? true ? "checked" : ""}/><label for="f_${k}" style="margin:0">${esc(label)}</label></div>`
    : type === "money" ? `<label>${esc(label)}</label><input name="${k}" class="ltr" inputmode="decimal" value="${egpInput(row?.[k])}" required />`
    : type === "file" ? `<label>${esc(label)}</label><input type="file" name="${k}" accept="image/jpeg,image/png,image/webp" ${row?.id ? "" : "required"} />`
    : `<label>${esc(label)}</label><input name="${k}" type="${type}" value="${esc(row?.[k] ?? "")}" ${["slug", "link_value", "phone"].includes(k) ? 'class="ltr"' : ""} />`).join("")}
    <p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("save")}</button></p></form>`;
  // FormData from modal loses File objects -> collect manually
  return new Promise((resolve) => {
    const bg = document.createElement("div"); bg.className = "modal-bg"; bg.innerHTML = `<div class="modal">${html}</div>`; document.body.appendChild(bg);
    const close = (v) => { bg.remove(); resolve(v); };
    bg.querySelector("[data-close]").onclick = () => close(null);
    bg.querySelector("form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const fd = new FormData(e.target); const out = {};
      for (const [k, , type] of fields) {
        if (type === "check") out[k] = fd.get(k) === "on";
        else if (type === "money") { const v = parseEgp(fd.get(k)); if (v == null) return toast("INVALID_AMOUNT", true); out[k] = v; }
        else if (type === "number") out[k] = parseInt(fd.get(k) || "0", 10);
        else if (type === "file") { const f = fd.get(k); if (f && f.size) out[k] = f; }
        else out[k] = (fd.get(k) ?? "").toString().trim() || null;
      }
      close(out);
    });
  });
}

async function pageCategories() {
  const [c, b] = await Promise.all([db.from("categories").select("*").order("kind").order("sort_order"), db.from("brands").select("*").order("sort_order")]);
  const catFields = [["name_ar", t("nameAr")], ["name_en", t("nameEn")], ["slug", t("slug")], ["kind", t("kind"), "select", [["phones", t("phones")], ["accessories", t("accessories")], ["used", t("used")]]], ["sort_order", t("order"), "number"], ["is_active", t("active"), "check"]];
  const brandFields = [["name_ar", t("nameAr")], ["name_en", t("nameEn")], ["slug", t("slug")], ["sort_order", t("order"), "number"], ["is_active", t("active"), "check"]];
  shell(t("categories"), `<div class="grid two">
    <div class="card"><div class="row"><h3>${t("categories")}</h3><span class="spacer"></span><button class="btn sm primary" id="addc">＋</button></div>
      ${crudTable(c.data ?? [], [["name_ar", t("name"), (r) => pick(r, "name")], ["kind", t("kind"), (r) => chip(t(r.kind), r.kind === "used" ? "warn" : "")], ["is_active", t("active"), (r) => (r.is_active ? "✅" : "—")]], "cid")}</div>
    <div class="card"><div class="row"><h3>${t("brand")}</h3><span class="spacer"></span><button class="btn sm primary" id="addb">＋</button></div>
      ${crudTable(b.data ?? [], [["name_ar", t("name"), (r) => pick(r, "name")], ["is_active", t("active"), (r) => (r.is_active ? "✅" : "—")]], "bid")}</div></div>`);
  const save = async (table, row, fields) => {
    const v = await editRow(table, row, fields); if (!v) return;
    if (!v.slug) v.slug = slugify(v.name_en ?? "");
    await run(() => (row?.id ? db.from(table).update(v).eq("id", row.id) : db.from(table).insert(v)).then(({ error }) => { if (error) throw error; }));
    render();
  };
  $("#addc").onclick = () => save("categories", { kind: "phones", is_active: true, sort_order: 0 }, catFields);
  $("#addb").onclick = () => save("brands", { is_active: true, sort_order: 0 }, brandFields);
  on("[data-cid]", "click", (e) => save("categories", (c.data ?? []).find((x) => x.id === e.currentTarget.dataset.cid), catFields));
  on("[data-bid]", "click", (e) => save("brands", (b.data ?? []).find((x) => x.id === e.currentTarget.dataset.bid), brandFields));
}

async function pageBanners() {
  const { data } = await db.from("banners").select("*").order("sort_order");
  const fields = [["title_ar", t("titleAr")], ["title_en", t("titleEn")], ["image", t("upload"), "file"], ["link_type", t("link"), "select", [["", "—"], ["product", "product"], ["category", "category"], ["repair", "repair"]]], ["link_value", "ID"], ["sort_order", t("order"), "number"], ["is_active", t("active"), "check"]];
  const url = (p) => db.storage.from("banners").getPublicUrl(p).data.publicUrl;
  shell(t("banners"), `<div class="card">${crudTable(data ?? [], [["image_path", "", (r) => `<img src="${esc(url(r.image_path))}" style="width:140px;height:60px;object-fit:cover;border-radius:8px" alt="">`], ["title_ar", t("name"), (r) => pick(r, "title")], ["is_active", t("active"), (r) => (r.is_active ? "✅" : "—")]], "bn")}</div>`, `<button class="btn primary" id="add">＋ ${t("add")}</button>`);
  const save = async (row) => {
    const v = await editRow("banners", row, fields); if (!v) return;
    await run(async () => {
      if (v.image) {
        if (!ALLOWED_IMG.includes(v.image.type) || v.image.size > 5 * 1024 * 1024) throw new Error("invalid file");
        const path = `${Date.now()}_${safeFileName(v.image.name)}`;
        const up = await db.storage.from("banners").upload(path, v.image, { contentType: v.image.type }); if (up.error) throw up.error;
        v.image_path = path;
      }
      delete v.image; if (!v.link_type) v.link_type = null;
      const { error } = row?.id ? await db.from("banners").update(v).eq("id", row.id) : await db.from("banners").insert(v);
      if (error) throw error;
    });
    render();
  };
  $("#add").onclick = () => save({ is_active: true, sort_order: 0 });
  on("[data-bn]", "click", (e) => save((data ?? []).find((x) => x.id === e.currentTarget.dataset.bn)));
}

async function pageBranches() {
  const [b, z] = await Promise.all([db.from("branches").select("*"), db.from("delivery_zones").select("*").order("governorate")]);
  const bf = [["name_ar", t("nameAr")], ["name_en", t("nameEn")], ["address_ar", t("addressAr")], ["address_en", t("addressEn")], ["phone", t("phone")], ["hours_ar", t("hoursAr")], ["hours_en", t("hoursEn")], ["pickup_instructions_ar", "📝 AR"], ["pickup_instructions_en", "📝 EN"], ["is_active", t("active"), "check"]];
  const zf = [["governorate", t("governorate")], ["fee_minor", t("feeEgp"), "money"], ["eta_ar", t("eta") + " (ع)"], ["eta_en", t("eta") + " (EN)"], ["is_active", t("active"), "check"]];
  shell(t("branches"), `<div class="grid two">
    <div class="card"><div class="row"><h3>${t("branches")}</h3><span class="spacer"></span><button class="btn sm primary" id="addb">＋</button></div>${crudTable(b.data ?? [], [["name_ar", t("name"), (r) => pick(r, "name")], ["phone", t("phone")]], "br")}</div>
    <div class="card"><div class="row"><h3>${t("fee")}</h3><span class="spacer"></span><button class="btn sm primary" id="addz">＋</button></div>${crudTable(z.data ?? [], [["governorate", t("governorate")], ["fee_minor", t("feeEgp"), (r) => money(r.fee_minor)]], "zn")}</div></div>`);
  const save = async (table, row, fields) => {
    const v = await editRow(table, row, fields); if (!v) return;
    await run(() => (row?.id ? db.from(table).update(v).eq("id", row.id) : db.from(table).insert(v)).then(({ error }) => { if (error) throw error; }));
    render();
  };
  $("#addb").onclick = () => save("branches", { is_active: true }, bf);
  $("#addz").onclick = () => save("delivery_zones", { is_active: true }, zf);
  on("[data-br]", "click", (e) => save("branches", (b.data ?? []).find((x) => x.id === e.currentTarget.dataset.br), bf));
  on("[data-zn]", "click", (e) => save("delivery_zones", (z.data ?? []).find((x) => x.id === e.currentTarget.dataset.zn), zf));
}

async function pageCustomers() {
  const q = (hashParams().get("q") ?? "").replace(/[^\w\s@.+\-؀-ۿ]/g, "");
  let query = db.from("profiles").select("id, full_name, phone, phone_verified, email, created_at, deletion_requested_at").order("created_at", { ascending: false }).limit(200);
  if (q) query = query.or(`full_name.ilike.*${q}*,phone.ilike.*${q}*,email.ilike.*${q}*`);
  const [{ data, error }, support] = await Promise.all([query, can("support.manage") ? db.from("customer_support_requests").select("*").order("created_at", { ascending: false }).limit(50) : { data: [] }]);
  if (error) throw error;
  shell(t("customers"), `
    <div class="card"><form class="row" id="flt"><input name="q" value="${esc(q)}" placeholder="${t("search")}" style="max-width:300px" /><button class="btn">🔍</button></form>
    <div class="table-wrap"><table><thead><tr><th>${t("name")}</th><th>${t("phone")}</th><th>${t("email")}</th><th>${t("date")}</th></tr></thead><tbody>
    ${(data ?? []).map((c) => `<tr><td>${esc(c.full_name ?? "—")}${c.deletion_requested_at ? " " + chip(t("deletionRequests"), "bad") : ""}</td><td class="ltr">${esc(c.phone ?? "—")} ${c.phone_verified ? "✅" : ""}</td><td>${esc(c.email ?? "—")}</td><td>${fmtDate(c.created_at)}</td></tr>`).join("") || `<tr><td colspan="4" class="empty">${t("noData")}</td></tr>`}
    </tbody></table></div></div>
    ${can("support.manage") ? `<div class="card" style="margin-top:14px"><h3>${t("support_requests")}</h3><table>${(support.data ?? []).map((s) => `<tr><td><b>${esc(s.subject)}</b><br>${esc(s.message)}</td><td>${chip(s.status, s.status === "closed" ? "muted" : "warn")}</td><td><small>${fmtDate(s.created_at)}</small></td><td>${s.status !== "closed" ? `<button class="btn sm" data-close-sr="${s.id}">✔</button>` : ""}</td></tr>`).join("") || `<tr><td class="muted">${t("noData")}</td></tr>`}</table></div>` : ""}`);
  $("#flt").addEventListener("submit", (e) => { e.preventDefault(); location.hash = `#/customers?q=${encodeURIComponent(new FormData(e.target).get("q"))}`; });
  on("[data-close-sr]", "click", async (e) => { await run(() => db.from("customer_support_requests").update({ status: "closed" }).eq("id", e.currentTarget.dataset.closeSr).then(({ error }) => { if (error) throw error; })); render(); });
}

const ROLE_OPTS = () => [["technician", t("technicianRole")], ["sales", t("salesRole")], ["manager", t("manager")], ["support", t("support")], ["owner", t("owner")]];

async function pageStaff() {
  const { data, error } = await db.rpc("staff_list_staff"); if (error) throw error;
  shell(t("staff"), `<div class="card"><div class="table-wrap"><table><thead><tr><th>${t("name")}</th><th>${t("email")}</th><th>${t("roles")}</th><th></th></tr></thead><tbody>
    ${(data ?? []).map((s) => `<tr><td>${esc(s.full_name ?? "—")}</td><td>${esc(s.email ?? "—")}</td><td>${(s.roles ?? []).map((r) => `${chip(ROLE_OPTS().find((o) => o[0] === r)?.[1] ?? r)} ${s.user_id !== S.user.id || r !== "owner" ? `<button class="btn sm danger" data-revoke="${s.user_id}" data-role="${esc(r)}">✕</button>` : ""}`).join(" ")}</td>
      <td><button class="btn sm" data-grant="${s.user_id}">＋ ${t("role")}</button></td></tr>`).join("")}
    </tbody></table></div></div>`, `<button class="btn primary" id="inv">＋ ${t("invite")}</button>`);
  $("#inv").onclick = async () => {
    const r = await modal(`<form><h3>${t("invite")}</h3><label>${t("name")}</label><input name="full_name" /><label>${t("email")}</label><input name="email" type="email" class="ltr" required />
      <label>${t("role")}</label><select name="role">${ROLE_OPTS().map((o) => `<option value="${o[0]}">${esc(o[1])}</option>`).join("")}</select>
      <p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("confirm")}</button></p></form>`);
    if (!r) return;
    await run(async () => { const { error } = await db.functions.invoke("admin-invite-staff", { body: r }); if (error) throw error; });
    render();
  };
  on("[data-grant]", "click", async (e) => {
    const uid = e.currentTarget.dataset.grant;
    const r = await modal(`<form><label>${t("role")}</label><select name="role">${ROLE_OPTS().map((o) => `<option value="${o[0]}">${esc(o[1])}</option>`).join("")}</select><p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn primary">${t("confirm")}</button></p></form>`);
    if (!r) return;
    await run(() => db.rpc("staff_set_role", { p_user_id: uid, p_role: r.role, p_grant: true }).then(({ error }) => { if (error) throw error; }));
    render();
  });
  on("[data-revoke]", "click", async (e) => {
    const { revoke, role } = e.currentTarget.dataset;
    if (!(await confirmBox(t("confirmQ")))) return;
    await run(() => db.rpc("staff_set_role", { p_user_id: revoke, p_role: role, p_grant: false }).then(({ error }) => { if (error) throw error; }));
    render();
  });
}

async function pageEmails() {
  const { data, error } = await db.from("email_outbox").select("id, kind, to_email, status, attempts, last_error, created_at, sent_at, related_type, related_id").order("created_at", { ascending: false }).limit(100);
  if (error) throw error;
  shell(t("emails"), `<div class="card"><p class="muted">${S.lang === "ar" ? "الطلبات ← myhatosales@gmail.com · الصيانة ← myhatoservice@gmail.com (قابلة للتعديل من الإعدادات)" : "Orders → myhatosales@gmail.com · Repairs → myhatoservice@gmail.com (editable in Settings)"}</p>
    <div class="table-wrap"><table><thead><tr><th>${t("kindCol")}</th><th>${t("to")}</th><th>${t("status")}</th><th>${t("attempts")}</th><th>${t("lastError")}</th><th>${t("date")}</th></tr></thead><tbody>
    ${(data ?? []).map((e) => `<tr class="${e.related_type === "order" || e.related_type === "repair" ? "click" : ""}" data-href="${e.related_type === "order" ? `#/orders/${e.related_id}` : e.related_type === "repair" ? `#/repairs/${e.related_id}` : ""}">
      <td>${esc(e.kind)}</td><td>${esc(e.to_email)}</td><td>${chip(e.status, e.status === "sent" ? "ok" : e.status === "failed" ? "bad" : "warn")}</td><td>${esc(e.attempts)}</td><td><small>${esc(e.last_error ?? "")}</small></td><td>${fmtDate(e.sent_at ?? e.created_at)}</td></tr>`).join("") || `<tr><td colspan="6" class="empty">${t("noData")}</td></tr>`}
    </tbody></table></div></div>`);
  on("tr[data-href]", "click", (e) => { if (e.currentTarget.dataset.href) location.hash = e.currentTarget.dataset.href; });
}

async function pageSettings() {
  const { data, error } = await db.from("application_settings").select("*"); if (error) throw error;
  const v = Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
  shell(t("settings"), `<form id="st" class="card" style="max-width:640px">
    <div class="switch"><input type="checkbox" id="used" name="used_devices_enabled" ${v.used_devices_enabled === true ? "checked" : ""}/><label for="used" style="margin:0"><b>${t("usedEnabled")}</b></label></div>
    <div class="switch"><input type="checkbox" id="ra" name="repair_requires_approval" ${v.repair_requires_approval !== false ? "checked" : ""}/><label for="ra" style="margin:0">${t("requireApproval")}</label></div>
    <label>${t("ordersEmail")}</label><input name="orders_notification_email" type="email" class="ltr" value="${esc(v.orders_notification_email ?? "")}" required />
    <label>${t("repairsEmail")}</label><input name="repair_notification_email" type="email" class="ltr" value="${esc(v.repair_notification_email ?? "")}" required />
    <label>${t("defaultFee")}</label><input name="default_delivery_fee_minor" class="ltr" inputmode="decimal" value="${egpInput(v.default_delivery_fee_minor)}" />
    <label>${t("freeThreshold")}</label><input name="free_delivery_threshold_minor" class="ltr" inputmode="decimal" value="${egpInput(v.free_delivery_threshold_minor)}" />
    <label>${t("lowStockThreshold")}</label><input name="low_stock_threshold" type="number" min="0" value="${esc(v.low_stock_threshold ?? 5)}" />
    <p><button class="btn primary">${t("save")}</button></p></form>`);
  $("#st").addEventListener("submit", async (e) => {
    e.preventDefault(); const fd = new FormData(e.target);
    const fee = parseEgp(fd.get("default_delivery_fee_minor") || "0"), free = parseEgp(fd.get("free_delivery_threshold_minor") || "0");
    if (fee == null || free == null) return toast("INVALID_AMOUNT", true);
    const updates = {
      used_devices_enabled: fd.get("used_devices_enabled") === "on",
      repair_requires_approval: fd.get("repair_requires_approval") === "on",
      orders_notification_email: String(fd.get("orders_notification_email")).trim(),
      repair_notification_email: String(fd.get("repair_notification_email")).trim(),
      default_delivery_fee_minor: fee, free_delivery_threshold_minor: free,
      low_stock_threshold: Math.max(0, parseInt(fd.get("low_stock_threshold") || "5", 10)),
    };
    await run(async () => {
      for (const [key, value] of Object.entries(updates)) {
        const { error } = await db.from("application_settings").update({ value, updated_by: S.user.id, updated_at: new Date().toISOString() }).eq("key", key);
        if (error) throw error;
      }
    });
    render();
  });
}

async function pageAudit() {
  const { data, error } = await db.from("audit_logs").select("*").order("created_at", { ascending: false }).limit(200); if (error) throw error;
  shell(t("audit"), `<div class="card"><div class="table-wrap"><table><thead><tr><th>${t("date")}</th><th>${t("action")}</th><th>${t("details")}</th><th>${t("actor")}</th></tr></thead><tbody>
    ${(data ?? []).map((a) => `<tr><td>${fmtDate(a.created_at)}</td><td><b>${esc(a.action)}</b><br><small>${esc(a.entity_type)} ${esc(a.entity_id ?? "")}</small></td><td><small class="ltr">${esc(JSON.stringify(a.details))}</small></td><td><small>${esc(a.actor_id ?? "system")}</small></td></tr>`).join("") || `<tr><td colspan="4" class="empty">${t("noData")}</td></tr>`}
  </tbody></table></div></div>`);
}

// ---------------------------------------------------------------- payments
const PAY_STATUS = {
  pending: ["في الانتظار", "Pending", "warn"], processing: ["قيد المعالجة", "Processing", "warn"], succeeded: ["ناجحة", "Succeeded", "ok"],
  failed: ["فشلت", "Failed", "bad"], cancelled: ["ملغاة", "Cancelled", "muted"], refunded: ["مستردة", "Refunded", "muted"],
  partially_refunded: ["مستردة جزئيًا", "Partially refunded", "warn"],
};
const payChip = (s) => chip(PAY_STATUS[s]?.[S.lang === "ar" ? 0 : 1] ?? s, PAY_STATUS[s]?.[2] ?? "");
async function invokeFn(name, body) {
  const { data, error } = await db.functions.invoke(name, { body });
  if (error) {
    let code = "error";
    try { code = (await error.context?.json())?.error ?? code; } catch { /* ignore */ }
    throw new Error(code);
  }
  return data;
}

async function pagePayments() {
  const status = hashParams().get("status") ?? "";
  let q = db.from("payments").select("id, amount_minor, currency, status, payment_method_type, card_brand, card_last4, refunded_minor, provider_transaction_id, created_at, orders(id, reference, customer_name)").order("created_at", { ascending: false }).limit(200);
  if (status) q = q.eq("status", status);
  const [{ data, error }, settings] = await Promise.all([q, can("settings.manage") ? db.from("payment_settings").select("refunds_enabled").eq("id", 1).maybeSingle() : { data: null }]);
  if (error) throw error;
  const refundsOn = settings.data?.refunds_enabled === true;
  const METHOD_NAMES = { apple_pay: "Apple Pay", google_pay: "Google Pay", wallet: S.lang === "ar" ? "محفظة" : "Wallet" };
  const method = (p) => [METHOD_NAMES[p.payment_method_type] ?? null,
    p.card_brand ? `${p.card_brand} •••• ${p.card_last4 ?? ""}` : null].filter(Boolean).join(" · ") || "—";
  shell(t("payments"), `<div class="card"><form class="row" id="flt"><select name="status" style="max-width:220px"><option value="">${t("all")}</option>
    ${Object.entries(PAY_STATUS).map(([k, v]) => `<option value="${k}" ${k === status ? "selected" : ""}>${v[S.lang === "ar" ? 0 : 1]}</option>`).join("")}</select><button class="btn">🔍</button></form>
    <p class="muted"><small>${S.lang === "ar" ? "الحالات دي جاية من Paymob عن طريق Callback موثّق بـ HMAC — مفيش عملية بتتسجل ناجحة من غير تأكيد." : "Statuses come from HMAC-verified Paymob callbacks — nothing is marked paid without confirmation."}</small></p>
    <div class="table-wrap"><table><thead><tr><th>${t("reference")}</th><th>${t("customer")}</th><th>${t("total")}</th><th>${t("method")}</th><th>${t("status")}</th><th>${t("txId")}</th><th>${t("date")}</th><th></th></tr></thead><tbody>
    ${(data ?? []).map((p) => `<tr><td><a href="#/orders/${p.orders?.id}">${esc(p.orders?.reference ?? "")}</a></td><td>${esc(p.orders?.customer_name ?? "")}</td>
      <td>${money(p.amount_minor)} <small class="muted">${esc(p.currency)}</small>${p.refunded_minor ? `<br><small>↩ ${money(p.refunded_minor)}</small>` : ""}</td>
      <td>${esc(method(p))}</td><td>${payChip(p.status)}</td><td><small class="ltr">${esc(p.provider_transaction_id ?? "—")}</small></td><td>${fmtDate(p.created_at)}</td>
      <td>${can("orders.manage") && refundsOn && ["succeeded", "partially_refunded"].includes(p.status) ? `<button class="btn sm danger" data-refund="${p.id}" data-max="${p.amount_minor - p.refunded_minor}">${t("refund")}</button>` : ""}</td></tr>`).join("") || `<tr><td colspan="8" class="empty">${t("noData")}</td></tr>`}
    </tbody></table></div></div>`);
  $("#flt").addEventListener("submit", (e) => { e.preventDefault(); location.hash = `#/payments?status=${encodeURIComponent(new FormData(e.target).get("status"))}`; });
  on("[data-refund]", "click", async (e) => {
    const { refund, max } = e.currentTarget.dataset;
    const r = await modal(`<form><h3>${t("refund")}</h3><label>${t("refundAmount")}</label><input name="amount" class="ltr" inputmode="decimal" required value="${egpInput(Number(max))}" />
      <p class="row"><span class="spacer"></span><button type="button" class="btn" data-close>${t("cancel")}</button><button class="btn danger">${t("confirm")}</button></p></form>`);
    if (!r) return;
    const amount = parseEgp(r.amount);
    if (amount == null || amount <= 0 || amount > Number(max)) return toast("INVALID_AMOUNT", true);
    await run(() => invokeFn("payments-admin", { action: "refund", payment_id: refund, amount_minor: amount }), t("refundRequested"));
    render();
  });
}

async function pagePaymentSettings() {
  const { data: s, error } = await db.from("payment_settings").select("*").eq("id", 1).single();
  if (error) throw error;
  const ps = s.provider_status ?? {};
  const yes = (b) => (b ? chip("✓", "ok") : chip("✗", "bad"));
  shell(t("paymentSettings"), `
    <div class="grid two">
      <div class="card"><h3>${t("provider")}: Paymob (EG) ${s.is_configured ? chip(t("configured"), "ok") : chip(t("notConfigured"), "warn")}</h3>
        <dl class="kv">
          <dt>${t("merchantId")}</dt><dd class="ltr">${esc(s.merchant_account_id ?? "—")}</dd>
          <dt>${t("apiKeyValid")}</dt><dd>${yes(ps.api_key_valid)}</dd>
          ${ps.company ? `<dt>${t("company")}</dt><dd>${esc(ps.company)}</dd>` : ""}
          <dt>${t("integrations")}</dt><dd class="ltr">${(ps.integration_ids ?? []).map((i) => chip(String(i), "ok")).join(" ") || "—"}</dd>
          <dt>${t("adminCardIntegration")}</dt><dd class="ltr">${esc(ps.admin_card_integration ?? "—")}</dd>
          ${ps.missing_secrets ? `<dt>${t("missingSecrets")}</dt><dd>${ps.missing_secrets.map((m) => chip(m, "bad")).join(" ")}</dd>` : ""}
          ${ps.livemode === false ? `<dt>Mode</dt><dd>${chip("TEST", "warn")}</dd>` : ""}
          <dt>${t("lastCheck")}</dt><dd>${fmtDate(s.verified_at)}</dd>
        </dl>
        <p class="row"><button class="btn" id="verify">🔄 ${t("verifyProvider")}</button></p>
        <hr style="border:none;border-top:1px solid var(--border)">
        <h4>${t("paymentStatus")}: ${s.online_payments_enabled ? chip(t("enabledOnline"), "ok") : chip(t("disabledOnline"), "muted")}</h4>
        <p><button class="btn ${s.online_payments_enabled ? "danger" : "primary"}" id="toggle" ${!s.is_configured && !s.online_payments_enabled ? "disabled" : ""}>${s.online_payments_enabled ? t("disableOnline") : t("enableOnline")}</button></p>
      </div>
      <form class="card" id="psf"><h3>🏦 ${t("paymentSettings")}</h3>
        <p class="chip warn" style="white-space:normal;display:block;line-height:1.6">${t("ibanNote")}</p>
        <label>${t("merchantIban")}</label><input name="merchant_iban" class="ltr" value="${esc(s.merchant_iban ?? "")}" placeholder="EG.." pattern="[A-Za-z]{2}[0-9]{2}[A-Za-z0-9 ]{10,32}" />
        <label>${t("holder")}</label><input name="account_holder_name" value="${esc(s.account_holder_name ?? "")}" />
        <label>${t("bankName")}</label><input name="bank_name" value="${esc(s.bank_name ?? "")}" />
        <div class="grid two"><div><label>${t("settlementCurrency")}</label><select name="settlement_currency">${["EGP", "USD"].map((c) => `<option ${s.settlement_currency === c ? "selected" : ""}>${c}</option>`).join("")}</select></div>
        <div><label>${t("settlementSchedule")}</label><select name="settlement_schedule">${["daily", "weekly", "monthly", "manual"].map((c) => `<option ${s.settlement_schedule === c ? "selected" : ""}>${c}</option>`).join("")}</select></div></div>
        <div class="switch"><input type="checkbox" id="ref" name="refunds_enabled" ${s.refunds_enabled ? "checked" : ""}/><label for="ref" style="margin:0">${t("refundStatus")}: ${t("refundsEnabled")}</label></div>
        <p><button class="btn primary">${t("save")}</button></p>
      </form>
    </div>`);
  $("#verify").onclick = async () => { await run(() => invokeFn("payments-admin", { action: "verify" }), null); render(); };
  $("#toggle").onclick = async () => {
    if (!(await confirmBox(t("confirmQ")))) return;
    await run(() => invokeFn("payments-admin", { action: "set_online", enabled: !s.online_payments_enabled }));
    render();
  };
  $("#psf").addEventListener("submit", async (e) => {
    e.preventDefault(); const f = Object.fromEntries(new FormData(e.target));
    const iban = String(f.merchant_iban ?? "").replace(/\s+/g, "").toUpperCase();
    await run(() => db.from("payment_settings").update({
      merchant_iban: iban || null, account_holder_name: f.account_holder_name?.trim() || null, bank_name: f.bank_name?.trim() || null,
      settlement_currency: f.settlement_currency, settlement_schedule: f.settlement_schedule, refunds_enabled: f.refunds_enabled === "on", updated_by: S.user.id,
    }).eq("id", 1).then(({ error }) => { if (error) throw error; }));
    render();
  });
}

async function pageAdminCard() {
  const { data: c, error } = await db.from("admin_payment_method").select("*").eq("id", 1).single();
  if (error) throw error;
  const active = c.status === "active";
  shell(t("adminCard"), `<div class="card" style="max-width:620px">
    <p class="muted">${t("adminCardNote")}</p>
    <dl class="kv">
      <dt>${t("cardStatus")}</dt><dd>${chip(t("st_" + c.status), active ? "ok" : c.status === "pending" ? "warn" : "muted")}</dd>
      <dt>Provider ID</dt><dd class="ltr"><small>${esc(c.provider_payment_method_id ?? "—")}</small></dd>
      <dt>${t("method")}</dt><dd class="ltr">${c.brand ? `${esc(c.brand)} •••• ${esc(c.last4 ?? "")} ${c.expiry_month ? `(${String(c.expiry_month).padStart(2, "0")}/${c.expiry_year})` : ""}` : "—"}</dd>
      <dt>${t("lastCheck")}</dt><dd>${fmtDate(c.updated_at)}</dd>
    </dl>
    <div class="actions" style="margin-top:14px">
      ${active ? `<button class="btn primary" id="add">${t("changeCard")}</button><button class="btn danger" id="rm">${t("removeCard")}</button>`
               : `<button class="btn primary" id="add">${t("addAdminCard")}</button>`}
    </div></div>`);
  $("#add").onclick = async () => {
    let setup;
    try { setup = await invokeFn("payments-admin", { action: "admin_card_setup" }); } catch (e) { return toast(e.message === "PROVIDER_NOT_CONFIGURED" ? t("notConfigured") : errMsg(e), true); }
    if (!/^https:\/\//.test(String(setup?.checkout_url ?? ""))) return toast(t("notConfigured"), true);
    // Card details are entered only on Paymob's own page; the HMAC-verified callback activates the card here.
    window.open(setup.checkout_url, "_blank", "noopener");
    toast(t("st_pending")); setTimeout(render, 4000);
  };
  $("#rm")?.addEventListener("click", async () => {
    if (!(await confirmBox(t("confirmQ")))) return;
    await run(() => invokeFn("payments-admin", { action: "admin_card_remove" }));
    render();
  });
}

boot().catch((e) => { app.innerHTML = `<div class="boot">⚠️ ${esc(e?.message ?? e)}</div>`; });
