-- 0119: the receiving wallet numbers are shown to signed-in customers only (not to anonymous visitors).
revoke execute on function public.wallet_options() from anon;
