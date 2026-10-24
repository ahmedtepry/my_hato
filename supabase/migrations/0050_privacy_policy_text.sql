-- 0050: the privacy policy lives in the database, in Arabic and English.
-- The app shows the text for the customer's language and re-reads it whenever the page is opened or pulled to refresh,
-- so the wording can be changed without releasing a new APK:
--   update application_settings set value = to_jsonb('...new text...'::text) where key = 'legal_privacy_ar';
-- Text format: '# ' main title, '## ' section heading, '- ' bullet, anything else is a paragraph.

insert into public.application_settings (key, value, description) values
 ('legal_privacy_ar', to_jsonb($t$# سياسة الخصوصية – My Hatō
آخر تحديث: 24 أكتوبر 2026

## 1. مقدمة
نحن في My Hatō نحترم خصوصية المستخدمين ونلتزم بحماية البيانات الشخصية التي يتم جمعها من خلال التطبيق واستخدامها وفقًا لهذه السياسة.

باستخدام التطبيق، فإنك توافق على الممارسات الموضحة في سياسة الخصوصية هذه.

## 2. البيانات التي نجمعها
قد يجمع التطبيق البيانات التالية حسب الخدمات التي يستخدمها العميل:
- الاسم.
- رقم الهاتف.
- البريد الإلكتروني عند استخدامه للتسجيل.
- بيانات الحساب وتسجيل الدخول.
- عنوان التوصيل وموقعك، إذا اخترت التوصيل.
- تفاصيل الطلبات والمنتجات التي يطلبها العميل.
- بيانات الاستخدام اللازمة لتشغيل التطبيق وتحسين خدماته.

إذا أتاح التطبيق تسجيل الدخول باستخدام Google أو Facebook، فقد نتلقى بعض بيانات الحساب الأساسية التي تسمح بها خدمة تسجيل الدخول.

## 3. كيفية استخدام البيانات
نستخدم البيانات للأغراض التالية:
- إنشاء حساب العميل وإدارته.
- استقبال الطلبات ومتابعتها.
- التواصل مع العميل بشأن الطلبات.
- توصيل المنتجات إلى العنوان المحدد عند اختيار التوصيل.
- تقديم الدعم الفني وخدمة العملاء.
- حماية التطبيق.
- تحسين أداء التطبيق وتجربة المستخدم.

## 4. مشاركة البيانات
لا نبيع البيانات الشخصية للمستخدمين.

قد تتم مشاركة البيانات الضرورية فقط مع الموظفين أو مندوب التوصيل أو مزودي الخدمات التقنية، بالقدر اللازم لتنفيذ الطلبات وتشغيل التطبيق، أو عندما يكون ذلك مطلوبًا بموجب القانون.

## 5. تخزين البيانات وحمايتها
نتخذ تدابير تقنية وتنظيمية مناسبة لحماية البيانات من الوصول غير المصرح به أو الفقد أو التعديل.

قد تُخزن بعض البيانات باستخدام خدمات قواعد البيانات أو تسجيل الدخول التي يعتمد عليها التطبيق، مثل Supabase أو Google أو Facebook، بحسب الخدمات المفعلة فعليًا.

## 6. الموقع الجغرافي
عند طلب توصيل، نطلب منك تحديد موقعك على الخريطة أو كتابته بنفسك، حتى يصل المندوب إليك بسهولة.

لا نستخدم موقعك إلا لتنفيذ التوصيل، وحسب الإذن الذي تمنحه. يمكنك اختيار كتابة الموقع بدلًا من استخدام الإذن، ويمكنك إلغاء إذن الموقع من إعدادات جهازك في أي وقت.

## 7. سياسة الدفع النقدي
يعتمد تطبيق My Hatō على الدفع النقدي فقط، ولا يوفر حاليًا الدفع الإلكتروني أو الدفع بالبطاقات البنكية من خلال التطبيق.

تتم عملية تحصيل قيمة الطلب بإحدى الطريقتين:
- الاستلام من الفرع: يدفع العميل قيمة الطلب نقدًا عند استلام المنتجات من الفرع.
- التوصيل: يقوم مندوب التوصيل بتحصيل قيمة الطلب نقدًا من العميل عند تسليم المنتجات.

تُوضح قيمة الطلب ورسوم التوصيل، إن وجدت، قبل تأكيد الطلب.

## 8. الاحتفاظ بالبيانات
نحتفظ بالبيانات للمدة اللازمة لتشغيل الحساب وتنفيذ الطلبات وتقديم الدعم والوفاء بالالتزامات القانونية، ثم نحذفها عندما لا تعود هناك حاجة للاحتفاظ بها.

## 9. حذف الحساب والبيانات
يمكن للمستخدم طلب حذف حسابه من داخل التطبيق عبر خيار حذف الحساب، إذا كان متاحًا في نسخة التطبيق المستخدمة.

قد يؤدي حذف الحساب إلى إزالة البيانات المرتبطة به، مع الاحتفاظ ببعض السجلات عند الضرورة للامتثال للقانون.

## 10. التعديلات على السياسة
قد نقوم بتحديث سياسة الخصوصية من وقت لآخر. سيتم نشر النسخة المحدثة داخل التطبيق.

## 11. التواصل
للاستفسارات المتعلقة بالخصوصية أو البيانات الشخصية، تواصل معنا عبر رقم الدعم الموضح أسفل هذه الصفحة.

باستخدام تطبيق My Hatō، يقر المستخدم بأنه اطلع على سياسة الخصوصية هذه.$t$::text), 'Privacy policy shown to Arabic users'),
 ('legal_privacy_en', to_jsonb($t$# Privacy Policy – My Hatō
Last updated: 24 October 2026

## 1. Introduction
At My Hatō we respect users' privacy and are committed to protecting the personal data collected through the app and using it in line with this policy.

By using the app, you agree to the practices described in this Privacy Policy.

## 2. Data we collect
Depending on the services the customer uses, the app may collect:
- Name.
- Phone number.
- Email address when used to sign up.
- Account and sign-in data.
- Delivery address and your location, if you choose delivery.
- Details of the orders and products the customer requests.
- Usage data needed to run the app and improve its services.

If the app offers sign-in with Google or Facebook, we may receive some basic account data that the sign-in service allows.

## 3. How we use data
We use data to:
- Create and manage the customer's account.
- Receive and follow up on orders.
- Contact the customer about orders.
- Deliver products to the chosen address when delivery is selected.
- Provide technical support and customer service.
- Protect the app.
- Improve the app's performance and the user experience.

## 4. Sharing data
We do not sell users' personal data.

Only the necessary data may be shared with staff, the delivery courier or technical service providers, as far as needed to fulfil orders and run the app, or where required by law.

## 5. Storing and protecting data
We take appropriate technical and organisational measures to protect data from unauthorised access, loss or alteration.

Some data may be stored using the database or sign-in services the app relies on, such as Supabase, Google or Facebook, depending on the services actually enabled.

## 6. Location
When you request delivery, we ask you to mark your location on the map or type it yourself, so the courier can reach you easily.

We use your location only to carry out the delivery, and according to the permission you give. You can type your location instead of using the permission, and you can turn off location permission in your device settings at any time.

## 7. Cash payment policy
My Hatō relies on cash payment only and does not currently offer online payment or bank card payment through the app.

The order amount is collected in one of two ways:
- Branch pickup: the customer pays the order amount in cash when collecting the products from the branch.
- Delivery: the delivery courier collects the order amount in cash from the customer when handing over the products.

The order amount and the delivery fee, if any, are shown before the order is confirmed.

## 8. Keeping data
We keep data for as long as needed to run the account, fulfil orders, provide support and meet legal obligations, then delete it when there is no longer a need to keep it.

## 9. Deleting your account and data
A user may request deletion of their account from inside the app through the delete account option, where it is available in the version of the app being used.

Deleting an account may remove the data linked to it, while keeping some records where necessary to comply with the law.

## 10. Changes to this policy
We may update this Privacy Policy from time to time. The updated version will be published inside the app.

## 11. Contact
For questions about privacy or personal data, contact us through the support number shown at the bottom of this page.

By using the My Hatō app, the user confirms that they have read this Privacy Policy.$t$::text), 'Privacy policy shown to English users')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- customers (and visitors) may read these two keys
alter policy settings_public_read on public.application_settings
  using (key in ('default_currency','default_delivery_fee_minor','free_delivery_threshold_minor',
                 'enabled_payment_methods','repair_requires_approval','supported_locales','used_devices_enabled',
                 'legal_privacy_ar','legal_privacy_en') or public.is_staff());
