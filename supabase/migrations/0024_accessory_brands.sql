-- 0024 Common accessory brands (products pick a brand in the admin console; more can be added there).
insert into public.brands(slug, name_ar, name_en, sort_order) values
  ('anker','أنكر','Anker',10), ('baseus','باسيوس','Baseus',11), ('ugreen','يوجرين','UGREEN',12),
  ('joyroom','جوي روم','Joyroom',13), ('spigen','سبيجن','Spigen',14), ('oraimo','أورايمو','Oraimo',15),
  ('hoco','هوكو','Hoco',16), ('ldnio','ال دي نيو','LDNIO',17), ('remax','ريماكس','Remax',18),
  ('jbl','جي بي ال','JBL',19), ('realme','ريلمي','Realme',20), ('honor','هونر','Honor',21),
  ('infinix','إنفينكس','Infinix',22), ('tecno','تكنو','Tecno',23), ('nokia','نوكيا','Nokia',24),
  ('my-hato','My Hatō','My Hatō',90), ('generic','بدون ماركة معروفة','Generic',99)
on conflict (slug) do nothing;
