-- 0096: (1) permissions whose group was 'team' were never listed in the permissions screen -> regroup them so they show.
--       (2) new group "اختصارات": 15 placeholder permissions (inert = not active yet, switching them on has no effect until each one is built).
update public.permission_catalog set grp = 'stock' where permission in ('stock.view','stock.allocate','stock.transfer','stock.receive','stock.others');
update public.permission_catalog set grp = 'extras' where permission in ('contest.manage','features.manage','wheel.manage');

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('shortcut.goods_receipt', 'shortcuts', 'يستلم بضاعة من المورد', 'Receive goods from a supplier', 'يسجّل وصول بضاعة جديدة ويزوّد المخزن', 'Records new goods arriving and adds them to stock', false, true, 1),
 ('shortcut.stocktake', 'shortcuts', 'يعمل جرد للمخزن', 'Run a stocktake', 'يعدّ المخزن فعليًا ويقارنه بالنظام ويسجّل الفرق', 'Counts the real stock and compares it with the system', false, true, 2),
 ('shortcut.price_edit', 'shortcuts', 'يعدّل أسعار المنتجات', 'Edit product prices', 'يغيّر سعر البيع من غير ما يفتح باقي بيانات المنتج', 'Changes the selling price without touching the rest of the product', true, true, 3),
 ('shortcut.branch_profit', 'shortcuts', 'يشوف أرباح فرعه بس', 'See his own branch profit', 'أرباح فرعه من غير باقي الفروع', 'Profit of his branch only', true, true, 4),
 ('shortcut.online_refund', 'shortcuts', 'يوافق على استرجاع الأونلاين', 'Approve online refunds', 'يوافق أو يرفض طلبات استرجاع الطلبات الأونلاين', 'Approves or rejects online order refunds', true, true, 5),
 ('shortcut.points_adjust', 'shortcuts', 'يعدّل نقاط عميل (بحد يومي)', 'Adjust customer points (daily cap)', 'يزوّد أو ينقّص نقاط عميل لحد رقم محدد في اليوم', 'Adds or removes points up to a daily limit', true, true, 6),
 ('shortcut.message_customer', 'shortcuts', 'يبعت رسالة لعميل واحد', 'Message a single customer', 'رسالة مباشرة لعميل بعينه', 'A direct message to one customer', false, true, 7),
 ('shortcut.broadcast', 'shortcuts', 'يبعت رسالة لكل العملاء', 'Broadcast to all customers', 'إشعار جماعي لكل العملاء أو مجموعة منهم', 'A mass notification to all or a group of customers', true, true, 8),
 ('shortcut.block_customer', 'shortcuts', 'يوقف حساب عميل', 'Block a customer', 'يمنع عميل من الطلب أو دخول البرنامج', 'Stops a customer from ordering or signing in', true, true, 9),
 ('shortcut.hide_contact', 'shortcuts', 'يخفي بيانات تواصل العميل', 'Hide customer contact data', 'الموظف يشوف الطلب من غير رقم العميل وعنوانه', 'The employee sees the order without phone and address', true, true, 10),
 ('shortcut.export', 'shortcuts', 'يحمّل البيانات (إكسل)', 'Export data (Excel)', 'تحميل المبيعات والمنتجات والعملا كملف', 'Download sales, products and customers as a file', true, true, 11),
 ('shortcut.restore_deleted', 'shortcuts', 'يسترجع المحذوف', 'Restore deleted items', 'يرجّع منتج أو طلب اتمسح بالغلط', 'Brings back a product or order deleted by mistake', true, true, 12),
 ('shortcut.branch_log', 'shortcuts', 'يشوف سجل نشاط فرعه', 'See his branch activity log', 'اللي حصل في فرعه بس', 'What happened in his branch only', false, true, 13),
 ('shortcut.schedule', 'shortcuts', 'يعمل جدول مواعيد الموظفين', 'Plan staff schedules', 'يوزّع الورديات على الموظفين', 'Assigns shifts to employees', false, true, 14),
 ('shortcut.attendance', 'shortcuts', 'يتابع الحضور والانصراف', 'Track attendance', 'يشوف مين حضر وأتأخر', 'Sees who came and who was late', false, true, 15)
on conflict (permission) do update set grp = excluded.grp, name_ar = excluded.name_ar, name_en = excluded.name_en,
  desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = excluded.sensitive, inert = excluded.inert, sort = excluded.sort;

insert into public.permission_ui_text (key, ar, en) values
 ('grp_stock', 'المخزن', 'Stock'),
 ('grp_extras', 'المسابقات والمزايا', 'Contests and features'),
 ('grp_shortcuts', 'اختصارات', 'Shortcuts')
on conflict (key) do update set ar = excluded.ar, en = excluded.en;
