-- 0064: owner-controlled permission for "remember my username on this device" at the cashier's shift opening.
-- Only the USERNAME is ever remembered (on that computer); the password is always typed. The owner can switch this off per role or per person.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('pos.remember_login','pos','يحفظ اسم المستخدم على الجهاز','Remember username on the device','عند فتح الوردية يقدر يحفظ اسم المستخدم على الجهاز ده (الباسورد مبيتحفظش أبدًا)','When opening a shift he may keep his username on this device (the password is never saved)',false,false,66)
on conflict (permission) do nothing;

insert into public.role_permissions (role, permission) values
  ('owner','pos.remember_login'),('manager','pos.remember_login'),('cashier','pos.remember_login'),('sales','pos.remember_login')
on conflict do nothing;
