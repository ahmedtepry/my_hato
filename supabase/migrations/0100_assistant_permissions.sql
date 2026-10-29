-- 0100: "المساعد الآلي": three switches the owner can give to a role or to one person. Not built yet (inert = no effect), so nobody holds them but the owner,
-- who has everything. When each mode is built, the permission is what lets someone turn it on.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('assistant.accountant', 'assistant', 'يفعّل المحاسب الآلي', 'Turn on the automatic accountant',
  'يشغّل وضع المحاسب الآلي: يجمع المبيعات والعمولات والمخزن في شيتات إكسل مترتبة بالشهر والفرع والموظف',
  'Turns on the automatic accountant: collects sales, commissions and stock into Excel sheets sorted by month, branch and employee', true, true, 1),
 ('assistant.support', 'assistant', 'يفعّل روبوت خدمة العملاء', 'Turn on the customer-service robot',
  'يشغّل الروبوت اللي بيتابع الطلبات والصيانة ويرد على الأسئلة المتكررة وينبّه الموظف',
  'Turns on the robot that follows orders and repairs, answers common questions and alerts the team', true, true, 2),
 ('assistant.cashier', 'assistant', 'يفعّل مساعد الكاشير', 'Turn on the cashier assistant',
  'يشغّل مساعد الكاشير: تنبيه لما المنتج يخلص، وإضافات مقترحة للبيع، وملخص الوردية',
  'Turns on the cashier assistant: low-stock alerts, suggested add-ons and the shift summary', false, true, 3)
on conflict (permission) do update set grp = excluded.grp, name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar,
  desc_en = excluded.desc_en, sensitive = excluded.sensitive, inert = excluded.inert, sort = excluded.sort;
insert into public.permission_ui_text (key, ar, en) values ('grp_assistant', 'المساعد الآلي', 'Automatic assistant')
on conflict (key) do update set ar = excluded.ar, en = excluded.en;
