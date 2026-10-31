create or replace function public._wallet_parse(p_from text, p_text text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t text; wallet text := 'unknown'; amt text; m text[]; sender text; ref text; incoming boolean; otp boolean; r record;
begin
  t := translate(coalesce(p_text, ''), '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  if (coalesce(p_from, '') || ' ' || t) ~* 'vodafone|فودافون|vf[- ]?cash' then wallet := 'vodafone';
  elsif (coalesce(p_from, '') || ' ' || t) ~* 'etisalat|اتصالات|e&' then wallet := 'etisalat';
  elsif (coalesce(p_from, '') || ' ' || t) ~* 'instapay|انستا|إنستا' then wallet := 'instapay'; end if;
  otp := t ~* 'otp|رمز التحقق|كود التحقق|verification|one.time|password|الرقم السري';
  m := regexp_match(t, '(?:استلمت|استلام|استقبلت|استقبال|received|مبلغ|amount|اضافة|إضافة|added|credited)[^0-9]{0,30}([0-9][0-9,]*(?:\.[0-9]+)?)', 'i');
  amt := m[1];
  if amt is null then
    m := regexp_match(t, '(?:EGP|LE|جنيه|ج\.م|جم)\s*([0-9][0-9,]*(?:\.[0-9]+)?)|([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:EGP|LE|جنيه|ج\.م|جم)', 'i');
    amt := coalesce(m[1], m[2]);
  end if;
  incoming := not otp and (t ~* 'received|استلم|استلام|استقبل|استقبال|وصلك|وصل لك|اضافة|إضافة|added|credited|حول لك|حولك|transferred to you|you have received' or (amt is not null and wallet <> 'unknown'));
  if t ~* 'sent to|تم تحويل مبلغ.*الى|تم ارسال|you have sent|دفعت|سحب' and t !~* 'received|استلم|استلام|استقبل|وصلك' then incoming := false; end if;
  for r in select (x)[1] as n from regexp_matches(regexp_replace(t, '[ -]', '', 'g'), '(?:\+?2)?(01[0125][0-9]{8})', 'g') x loop
    if not exists (select 1 from public.wallet_numbers w where w.number <> '' and right(regexp_replace(w.number, '\D', '', 'g'), 10) = right(r.n, 10)) then sender := r.n; exit; end if;
  end loop;
  m := regexp_match(t, '(?:رقم العملية|رقم المعاملة|transaction(?: id| number| no)?|trx|ref(?:erence)?|id)[^0-9]{0,15}([0-9]{6,})', 'i');
  ref := m[1];
  return jsonb_build_object('wallet', wallet, 'amount_minor', case when amt is null then null else round(replace(amt, ',', '')::numeric * 100)::bigint end,
                            'sender', sender, 'ref', ref, 'incoming', incoming);
exception when others then
  return jsonb_build_object('wallet', 'unknown', 'amount_minor', null, 'sender', null, 'ref', null, 'incoming', false);
end $$;
revoke all on function public._wallet_parse(text, text) from public, anon, authenticated;
