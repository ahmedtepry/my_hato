-- 0050: the privacy policy lives in the database, in Arabic and English.
-- The app shows the text for the customer's language and re-reads it whenever the page is opened or pulled to refresh,
-- so the wording can be changed without releasing a new APK:
--   update application_settings set value = to_jsonb('...new text...'::text) where key = 'legal_privacy_ar';
-- Text format: '# ' main title, '## ' section heading, '- ' bullet, anything else is a paragraph.

insert into public.application_settings (key, value, description) values
 ('legal_privacy_ar', to_jsonb($t$# سياسة الخصوصية – My Hatō
آخر تحديث: 24 أكتوبر 2026

توضح سياسة الخصوصية هذه كيفية جمع واستخدام وحماية المعلومات عند استخدام تطبيق My Hatō، المتخصص في بيع الهواتف المحمولة والإكسسوارات وتقديم خدمات الصيانة.

## 1. المعلومات التي نجمعها
قد يجمع التطبيق، حسب الخدمات التي تستخدمها، المعلومات التالية:
- بيانات الحساب: الاسم، البريد الإلكتروني، ورقم الهاتف عند تقديمه.
- بيانات الطلبات: المنتجات المطلوبة، الأسعار، العناوين، وحالة الطلب.
- بيانات الصيانة: نوع الجهاز، وصف العطل، تفاصيل الإصلاح والصور التي يرسلها العميل.
- بيانات الدفع: حالة العملية وقيمتها ومعرّف المعاملة. وقد تتم معالجة بيانات البطاقة بواسطة مزود الدفع المعتمد.
- البيانات الفنية الضرورية لتشغيل التطبيق وحمايته، وفقًا للأذونات والممارسات الفعلية للتطبيق.

لا نجمع بيانات أكثر مما نحتاج إليه لتقديم خدماتنا، ولا نطلب كلمات المرور البنكية أو رموز التحقق الخاصة ببطاقات الدفع.

## 2. كيفية استخدام المعلومات
نستخدم المعلومات من أجل:
- إنشاء الحسابات وتسجيل الدخول وإدارتها.
- معالجة الطلبات والمدفوعات ومتابعة عمليات التوصيل.
- تقديم خدمات الصيانة والتواصل مع العملاء.
- معالجة الشكاوى وطلبات الاسترجاع والاسترداد.
- حماية الحسابات وتحسين أداء التطبيق.

## 3. تسجيل الدخول
قد يتيح التطبيق تسجيل الدخول باستخدام البريد الإلكتروني أو رقم الهاتف أو خدمات تسجيل الدخول التابعة لأطراف خارجية، مثل Google أو Facebook، إذا كانت هذه الخيارات مفعّلة.

تخضع البيانات التي تتم معالجتها من خلال تلك الخدمات لسياساتها الخاصة، بالإضافة إلى هذه السياسة فيما يتعلق باستخدامها داخل My Hatō.

## 4. المدفوعات
قد يستخدم التطبيق مزودي خدمات دفع معتمدين لمعالجة المدفوعات الإلكترونية. وتخضع بيانات الدفع التي يجمعها هؤلاء المزودون لسياساتهم وشروطهم.

تتم معالجة بيانات البطاقة عبر مزود الدفع المعتمد.

## 5. حماية المعلومات
نتخذ تدابير تقنية وتنظيمية مناسبة لحماية المعلومات من الوصول غير المصرح به أو التعديل أو الإفصاح أو الفقدان.

تقتصر صلاحية الوصول إلى بيانات العملاء على الأشخاص المخولين الذين يحتاجون إليها لأداء مهامهم، وفقًا للصلاحيات المطبقة في النظام.

## 6. مشاركة المعلومات
لا نبيع البيانات الشخصية للعملاء. وقد تتم مشاركة المعلومات بالقدر الضروري مع مزودي الاستضافة وقواعد البيانات والدفع والتوصيل، أو عند وجود التزام قانوني بذلك.

ويخضع أي تعامل مع مزودي الخدمات للضوابط المناسبة لحماية البيانات.

## 7. الاحتفاظ بالبيانات
نحتفظ بالمعلومات فقط للمدة اللازمة لتقديم الخدمات وتحقيق الأغراض الموضحة في هذه السياسة، أو للمدة التي تقتضيها الالتزامات القانونية وحماية حسابك.

## 8. حذف الحساب والبيانات
يمكن للمستخدم طلب حذف حسابه والبيانات المرتبطة به من خلال خيار حذف الحساب داخل التطبيق.

عند استلام الطلب، تتم معالجة الحذف خلال مدة معقولة، مع حذف البيانات المشمولة بالطلب، باستثناء المعلومات التي يلزم الاحتفاظ بها لأسباب قانونية. ويتم توضيح أي استثناءات ومدة الاحتفاظ عند انطباقها.

## 9. حقوق المستخدم
يمكن للمستخدم طلب الوصول إلى بياناته أو تصحيحها أو حذفها، وفقًا للقوانين المعمول بها. ويمكنه التواصل معنا بشأن أي استفسار متعلق بالخصوصية أو معالجة بياناته.

## 10. التعديلات على السياسة
قد نحدّث هذه السياسة عند تغيير خدمات التطبيق أو ممارسات معالجة البيانات. وسيتم نشر النسخة الجديدة مع تحديث تاريخ المراجعة.

## 11. التواصل
اسم التطبيق: My Hatō

يمكنك التواصل معنا عبر رقم الدعم الموضح أسفل هذه الصفحة لتقديم استفسار أو طلب يتعلق بالخصوصية.

My Hatō — YOUR PHONE. OUR PRIORITY.$t$::text), 'Privacy policy shown to Arabic users'),
 ('legal_privacy_en', to_jsonb($t$# Privacy Policy – My Hatō
Last updated: 24 October 2026

This Privacy Policy explains how we collect, use and protect information when you use the My Hatō app, which specialises in selling mobile phones and accessories and providing repair services.

## 1. Information we collect
Depending on the services you use, the app may collect the following:
- Account data: name, email address, and phone number when provided.
- Order data: items ordered, prices, addresses and order status.
- Repair data: device type, fault description, repair details and the photos the customer sends.
- Payment data: transaction status, amount and transaction ID. Card details may be processed by an approved payment provider.
- Technical data necessary to run and protect the app, in line with the app's actual permissions and practices.

We do not collect more data than we need to provide our services, and we never ask for banking passwords or card verification codes.

## 2. How we use information
We use information to:
- Create, sign in to and manage accounts.
- Process orders and payments and follow up on deliveries.
- Provide repair services and communicate with customers.
- Handle complaints, returns and refunds.
- Keep accounts safe and improve the app's performance.

## 3. Signing in
The app may allow sign-in with email, phone number, or third-party sign-in services such as Google or Facebook, where these options are enabled.

Data processed through those services is subject to their own policies, in addition to this policy as it relates to their use inside My Hatō.

## 4. Payments
The app may use approved payment providers to process online payments. Payment data collected by those providers is subject to their policies and terms.

Card details are processed through the approved payment provider.

## 5. Protecting information
We take appropriate technical and organisational measures to protect information from unauthorised access, alteration, disclosure or loss.

Access to customer data is limited to authorised people who need it to do their jobs, according to the permissions applied in the system.

## 6. Sharing information
We do not sell customers' personal data. Information may be shared to the extent necessary with hosting, database, payment and delivery providers, or where there is a legal obligation to do so.

Any dealings with service providers are subject to appropriate data protection controls.

## 7. Keeping data
We keep information only for as long as needed to provide the services and achieve the purposes described in this policy, or for as long as legal obligations, protecting your account require.

## 8. Deleting your account and data
A user may request deletion of their account and related data through the delete account option inside the app.

When we receive the request, deletion is processed within a reasonable time and the data covered by the request is deleted, except for information we must keep for legal reasons. Any exceptions and retention periods are explained where they apply.

## 9. User rights
A user may request access to, correction of, or deletion of their data, in accordance with applicable laws. They may contact us about any privacy question or how their data is handled.

## 10. Changes to this policy
We may update this policy when the app's services or data handling practices change. The new version will be published with an updated review date.

## 11. Contact
App name: My Hatō

You can contact us through the support number shown at the bottom of this page for any question or request about privacy.

My Hatō — YOUR PHONE. OUR PRIORITY.$t$::text), 'Privacy policy shown to English users')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- customers (and visitors) may read these two keys
alter policy settings_public_read on public.application_settings
  using (key in ('default_currency','default_delivery_fee_minor','free_delivery_threshold_minor',
                 'enabled_payment_methods','repair_requires_approval','supported_locales','used_devices_enabled',
                 'legal_privacy_ar','legal_privacy_en') or public.is_staff());
