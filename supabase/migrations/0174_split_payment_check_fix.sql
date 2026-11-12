-- an older duplicate check (pos_sales_payment_method_chk) still allowed only cash/card/wallet: drop it, keep the one that allows 'split'
alter table public.pos_sales drop constraint if exists pos_sales_payment_method_chk;
