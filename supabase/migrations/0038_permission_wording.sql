-- 0038: all wording of the owner permissions screen lives in the database.
-- Change a label with a plain UPDATE; the app shows it after a pull-to-refresh (no new APK needed).
--   * permission_catalog   name / explanation of every permission (Arabic + English)
--   * permission_ui_text   every other sentence on the screen
--   * staff_permissions_overview() also returns 'catalog' and 'strings'
-- Safe to re-run: existing rows are kept, so later edits are not overwritten.

create table if not exists public.permission_catalog (
  permission text primary key,
  grp text not null default 'other',
  name_ar text not null,
  name_en text not null,
  desc_ar text,
  desc_en text,
  sensitive boolean not null default false,
  inert boolean not null default false,
  sort int not null default 100
);
create table if not exists public.permission_ui_text (
  key text primary key,
  ar text not null,
  en text not null
);
alter table public.permission_catalog enable row level security;
alter table public.permission_ui_text enable row level security;
drop policy if exists pc_select on public.permission_catalog;
drop policy if exists put_select on public.permission_ui_text;
create policy pc_select on public.permission_catalog for select to authenticated using (public.has_permission('permissions.manage'));
create policy put_select on public.permission_ui_text for select to authenticated using (public.has_permission('permissions.manage'));
revoke all on public.permission_catalog from anon;
revoke all on public.permission_ui_text from anon;
revoke insert, update, delete on public.permission_catalog from authenticated;
revoke insert, update, delete on public.permission_ui_text from authenticated;

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('orders.view', 'orders', 'يشوف الطلبات', 'View orders', 'يشوفها بس ومايغيّرش فيها', 'Can look but not change', false, false, 10),
  ('orders.manage', 'orders', 'يتحكم في الطلبات', 'Handle orders', 'يغيّر حالة الطلب ويوافق أو يرفض الإلغاء ويعمل أكواد الخصم', 'Change status, approve cancellations, manage discount codes', false, false, 20),
  ('customers.view', 'orders', 'يشوف بيانات العملاء', 'View customers', null, null, false, false, 30),
  ('support.manage', 'orders', 'يقبل أو يرفض الحسابات الجديدة', 'Approve new accounts', 'ويرد على طلبات الدعم', 'And answers support requests', false, false, 40),
  ('customers.review', 'orders', 'مراجعة العملاء الجداد', 'Review new customers', null, null, false, true, 50),
  ('cancel_requests.decide', 'orders', 'يوافق على إلغاء الطلبات', 'Decide cancellations', null, null, false, true, 60),
  ('coupons.manage', 'orders', 'يعمل أكواد الخصم', 'Manage discount codes', null, null, false, true, 70),
  ('notifications.broadcast', 'orders', 'يبعت إشعارات لكل العملاء', 'Send notifications to all customers', null, null, false, true, 80),
  ('products.manage', 'products', 'يعدّل المنتجات والأسعار والتقييمات', 'Edit products, prices and reviews', null, null, false, false, 10),
  ('inventory.manage', 'products', 'يعدّل المخزون', 'Edit stock', null, null, false, false, 20),
  ('banners.manage', 'products', 'يعدّل الصور الإعلانية', 'Edit banners', 'الصور اللي بتظهر في الصفحة الرئيسية', 'The pictures on the home page', false, false, 30),
  ('reviews.moderate', 'products', 'يراجع تقييمات العملاء', 'Moderate reviews', null, null, false, true, 40),
  ('repairs.view', 'repairs', 'يشوف طلبات الصيانة', 'View repairs', null, null, false, false, 10),
  ('repairs.manage', 'repairs', 'يتحكم في كل طلبات الصيانة', 'Handle all repairs', 'حتى اللي مش مسلّمة له، وقطع الغيار', 'Even ones not assigned to him, and parts', false, false, 20),
  ('repairs.update_assigned', 'repairs', 'يحدّث الصيانة اللي اتسلمتله بس', 'Update only his assigned repairs', null, null, false, false, 30),
  ('audit.view', 'system', 'يشوف سجل اللي حصل في النظام', 'View the activity log', null, null, false, false, 10),
  ('audit.export', 'system', 'يحمّل سجل النظام', 'Download the activity log', null, null, false, true, 20),
  ('settings.manage', 'system', 'يغيّر إعدادات المتجر والدفع', 'Change store and payment settings', null, null, true, false, 30),
  ('staff.manage', 'system', 'يدير الفريق', 'Manage the team', 'يضيف ويشيل أعضاء ويغيّر أدوارهم', 'Add and remove members and change roles', true, false, 40),
  ('payments.manage', 'system', 'يدير الدفع والاسترداد', 'Manage payments and refunds', null, null, true, true, 50),
  ('roles.assign', 'system', 'يغيّر أدوار الناس', 'Change people roles', null, null, true, true, 60),
  ('branches.manage', 'system', 'يعدّل الفروع ومناطق التوصيل', 'Edit branches and delivery zones', null, null, false, true, 70)
on conflict (permission) do nothing;

insert into public.permission_ui_text (key, ar, en) values
  ('title', 'صلاحيات الفريق', 'Team permissions'),
  ('refresh', 'تحديث', 'Refresh'),
  ('tab_roles', 'كل دور', 'By role'),
  ('tab_accounts', 'حساب بعينه', 'One account'),
  ('hint_roles', 'اختار الدور وشغّل أو اقفل أي حاجة. التغيير بيتطبق على كل اللي في الدور ده.', 'Pick a role and switch things on or off. It applies to everyone in that role.'),
  ('hint_accounts', 'اختار شخص، وتقدر تسمح له بحاجة زيادة أو تمنعه من حاجة، من غير ما تغيّر دوره كله.', 'Pick a person to allow or block single things without changing the whole role.'),
  ('owner_note', 'المالك عنده كل حاجة وثابت، عشان متقفلش على نفسك بالغلط.', 'The owner always has everything, so you cannot lock yourself out.'),
  ('grp_orders', 'الطلبات والعملاء', 'Orders and customers'),
  ('grp_products', 'المنتجات', 'Products'),
  ('grp_repairs', 'الصيانة', 'Repairs'),
  ('grp_system', 'النظام', 'System'),
  ('grp_other', 'أخرى', 'Other'),
  ('opt_deny', 'ممنوع', 'Blocked'),
  ('opt_role', 'زي دوره', 'Same as role'),
  ('opt_grant', 'مسموح', 'Allowed'),
  ('can_yes', 'يقدر يعمل ده', 'Can do this'),
  ('can_no', 'مايقدرش يعمل ده', 'Cannot do this'),
  ('note_role_yes', 'زي دوره، ودوره بيسمح بيه', 'Follows the role, which allows it'),
  ('note_role_no', 'زي دوره، ودوره مبيسمحش بيه', 'Follows the role, which does not allow it'),
  ('note_deny', 'ممنوع منه حتى لو دوره بيسمح', 'Blocked even if the role allows it'),
  ('note_grant', 'مسموح له بيه حتى لو دوره مبيسمحش', 'Allowed even if the role does not'),
  ('soon_title', 'حاجات جاية قريب', 'Coming soon'),
  ('soon_sub', 'لسه مش شغالة، تشغيلها دلوقتي مالوش تأثير', 'Not active yet, switching them on has no effect'),
  ('sensitive', 'حساسة', 'Sensitive'),
  ('sensitive_warn', 'صلاحية حساسة، اتأكد قبل ما تكمل.', 'This is a sensitive permission, please double-check.'),
  ('saved', 'اتحفظ', 'Saved'),
  ('confirm_give_role', 'تسمح بـ «{perm}» لـ {role}؟', 'Allow "{perm}" for {role}?'),
  ('confirm_take_role', 'تمنع «{perm}» عن {role}؟', 'Block "{perm}" for {role}?'),
  ('confirm_give_user', 'تسمح بـ «{perm}» للحساب ده؟', 'Allow "{perm}" for this account?'),
  ('affects', 'ده هيأثر على {n} حساب دلوقتي.', 'This affects {n} account(s) right now.'),
  ('cancel', 'إلغاء', 'Cancel'),
  ('confirm', 'تأكيد', 'Confirm'),
  ('no_staff', 'مفيش حد في الفريق غير المالك', 'No team members besides the owner'),
  ('exceptions', '{n} استثناء', '{n} exceptions')
on conflict (key) do nothing;

create or replace function public.staff_permissions_overview()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_permission('permissions.manage');
  return jsonb_build_object(
    'permissions', (select coalesce(jsonb_agg(p order by p), '[]') from (select distinct permission as p from public.role_permissions) s),
    'roles', (select coalesce(jsonb_object_agg(role, perms), '{}') from (
                select role::text as role, jsonb_agg(permission order by permission) as perms
                  from public.role_permissions group by role) r),
    'overrides', (select coalesce(jsonb_agg(jsonb_build_object(
                    'user_id', o.user_id, 'name', coalesce(nullif(p.full_name,''), p.email),
                    'permission', o.permission, 'effect', o.effect, 'note', o.note, 'created_at', o.created_at)
                    order by o.created_at), '[]')
                    from public.user_permission_overrides o left join public.profiles p on p.id = o.user_id),
    'catalog', (select coalesce(jsonb_object_agg(c.permission, jsonb_build_object(
                    'grp', c.grp, 'name_ar', c.name_ar, 'name_en', c.name_en, 'desc_ar', c.desc_ar, 'desc_en', c.desc_en,
                    'sensitive', c.sensitive, 'inert', c.inert, 'sort', c.sort)), '{}'::jsonb)
                    from public.permission_catalog c),
    'strings', (select coalesce(jsonb_object_agg(t.key, jsonb_build_object('ar', t.ar, 'en', t.en)), '{}'::jsonb)
                    from public.permission_ui_text t)
  );
end $$;
revoke all on function public.staff_permissions_overview() from public, anon;
grant execute on function public.staff_permissions_overview() to authenticated;
