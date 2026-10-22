// Email templates. Orders -> myhatosales@gmail.com, repairs -> myhatoservice@gmail.com
// (recipients come from application_settings, resolved when the email is queued).
import { cairoTime, egp, escapeHtml as e } from "./format.ts";

export interface Rendered { subject: string; html: string; text: string }

const shell = (title: string, body: string) => `<!doctype html><html dir="rtl" lang="ar"><body style="margin:0;background:#F7F8FC;font-family:Tahoma,Arial,sans-serif;color:#0B1630">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px">
<table width="620" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:14px;overflow:hidden">
<tr><td style="background:#0B1630;color:#fff;padding:18px 24px;font-size:20px;font-weight:bold">My Hatō <span style="color:#246BFD">●</span> <span style="font-size:13px;font-weight:normal;letter-spacing:2px">YOUR PHONE. OUR PRIORITY.</span></td></tr>
<tr><td style="padding:24px"><h2 style="margin:0 0 16px;color:#0B1630">${e(title)}</h2>${body}</td></tr>
</table></td></tr></table></body></html>`;

const row = (k: string, v: string) =>
  `<tr><td style="padding:6px 0;color:#667085;width:170px;vertical-align:top">${e(k)}</td><td style="padding:6px 0;font-weight:bold">${v}</td></tr>`;

function addr(a: Record<string, string> | null | undefined): string {
  if (!a) return "—";
  return e([a.recipient_name, a.phone, a.governorate, a.city, a.street, a.building, a.landmark].filter(Boolean).join(" — "));
}

const adminLink = (path: string) => {
  const base = Deno.env.get("ADMIN_DASHBOARD_URL") ?? "";
  return base ? `<p style="margin-top:20px"><a href="${e(base + path)}" style="background:#246BFD;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none">فتح في لوحة التحكم</a></p>` : "";
};

// deno-lint-ignore no-explicit-any
export function renderOrderNew(o: any): Rendered {
  const items = (o.items ?? []) as any[];
  const lines = items.map((i) => `<tr>
    <td style="padding:8px;border-bottom:1px solid #eee">${e(i.name_ar)}${i.variant_name_ar ? " — " + e(i.variant_name_ar) : ""}<br><span style="color:#667085;font-size:12px">${e(i.sku)}</span></td>
    <td style="padding:8px;border-bottom:1px solid #eee;text-align:center">${i.quantity}</td>
    <td style="padding:8px;border-bottom:1px solid #eee">${egp(i.unit_price_minor)}</td>
    <td style="padding:8px;border-bottom:1px solid #eee">${egp(i.line_total_minor)}</td></tr>`).join("");
  const fulfil = o.fulfillment === "pickup"
    ? `استلام من الفرع — ${e(o.branch?.name_ar)} (${e(o.branch?.address_ar)})`
    : `توصيل للمنزل — ${addr(o.delivery_address)}`;
  const body = `<table width="100%">${[
      row("رقم الطلب", e(o.reference)),
      row("التاريخ", e(cairoTime(o.created_at))),
      row("العميل", e(o.customer_name)),
      row("الموبايل", e(o.customer_phone)),
      row("الإيميل", e(o.customer_email ?? "—")),
      row("طريقة الاستلام", fulfil),
      row("الدفع", o.payment_method === "cash_on_delivery" ? "الدفع عند الاستلام" : "الدفع في الفرع"),
      o.delivery_notes ? row("ملاحظات التوصيل", e(o.delivery_notes)) : "",
    ].join("")}</table>
    <table width="100%" style="margin-top:16px;border-collapse:collapse;font-size:14px">
      <tr style="background:#F7F8FC"><th style="padding:8px;text-align:right">المنتج</th><th style="padding:8px">الكمية</th><th style="padding:8px;text-align:right">السعر</th><th style="padding:8px;text-align:right">الإجمالي</th></tr>
      ${lines}</table>
    <table width="100%" style="margin-top:12px">${[
      row("الإجمالي الفرعي", egp(o.subtotal_minor)),
      row("الخصم", egp(o.discount_minor)),
      row("رسوم التوصيل", egp(o.delivery_fee_minor)),
      row("الإجمالي المطلوب", `<span style="color:#246BFD;font-size:18px">${egp(o.total_minor)}</span>`),
    ].join("")}</table>${adminLink(`/#/orders/${o.id}`)}`;
  const text = [
    `طلب جديد ${o.reference}`, `العميل: ${o.customer_name} — ${o.customer_phone}`,
    `الاستلام: ${o.fulfillment === "pickup" ? "من الفرع " + (o.branch?.name_ar ?? "") : "توصيل"}`,
    ...items.map((i) => `- ${i.name_ar} (${i.sku}) × ${i.quantity} = ${egp(i.line_total_minor)}`),
    `الإجمالي: ${egp(o.total_minor)}`,
  ].join("\n");
  return { subject: `🛒 طلب جديد ${o.reference} — ${egp(o.total_minor)}`, html: shell(`طلب جديد ${o.reference}`, body), text };
}

// deno-lint-ignore no-explicit-any
export function renderRepairNew(r: any): Rendered {
  const where = r.pickup_address ? `استلام من العميل — ${addr(r.pickup_address)}` : `العميل هيسلّم الجهاز في الفرع — ${e(r.branch?.name_ar)}`;
  const body = `<table width="100%">${[
      row("رقم طلب الصيانة", e(r.reference)),
      row("التاريخ", e(cairoTime(r.created_at))),
      row("العميل", e(r.contact_name)),
      row("الموبايل", e(r.contact_phone)),
      row("الجهاز", e(`${r.device_brand} ${r.device_model}`)),
      row("IMEI / Serial", e(r.imei_or_serial ?? "—")),
      row("وصف العطل", e(r.problem_description)),
      row("الاستلام", where),
      row("الموعد المفضل", e(cairoTime(r.preferred_pickup_at))),
      row("طلب اتصال", r.callback_requested ? "نعم — العميل عايز مكالمة" : "لا"),
      row("صور مرفقة", String(r.photo_count ?? 0)),
    ].join("")}</table>${adminLink(`/#/repairs/${r.id}`)}`;
  const text = `طلب صيانة جديد ${r.reference}\n${r.contact_name} — ${r.contact_phone}\n${r.device_brand} ${r.device_model}\n${r.problem_description}`;
  return { subject: `🔧 طلب صيانة جديد ${r.reference} — ${r.device_brand} ${r.device_model}`, html: shell(`طلب صيانة جديد ${r.reference}`, body), text };
}

// deno-lint-ignore no-explicit-any
export function renderRepairResponse(r: any): Rendered {
  const approved = r.decision === "approved";
  const title = approved ? `✅ العميل وافق على تكلفة الصيانة ${r.reference}` : `❌ العميل رفض تكلفة الصيانة ${r.reference}`;
  const body = `<table width="100%">${[
      row("رقم الطلب", e(r.reference)),
      row("العميل", `${e(r.contact_name)} — ${e(r.contact_phone)}`),
      row("الجهاز", e(`${r.device_brand} ${r.device_model}`)),
      row("التكلفة", egp(r.quote?.amount_minor)),
      row("القرار", approved ? "موافقة — ابدأ الإصلاح" : "رفض — رتّب إرجاع الجهاز"),
      row("طريقة التسجيل", r.via === "customer_app" ? "من تطبيق العميل" : "سجّلها موظف (مكالمة)"),
    ].join("")}</table>${adminLink(`/#/repairs/${r.id}`)}`;
  return { subject: title, html: shell(title, body), text: `${title}\n${egp(r.quote?.amount_minor)}` };
}
