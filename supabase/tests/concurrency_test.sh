#!/usr/bin/env bash
# Two customers race for the LAST unit in stock at the same moment.
# Expected: exactly one order succeeds, stock ends at 0 (never negative).
# Run after run.sh (uses database myhato_test).
set -euo pipefail
P="psql -d myhato_test -v ON_ERROR_STOP=1 -qtA"
$P <<'SQL'
select t.reset();
update public.products set stock_quantity = 1 where sku = 'SGS24-256';
delete from public.cart_items;
select t.act('00000000-0000-0000-0000-00000000000a');
select public.cart_set_item((select id from public.products where sku='SGS24-256'), null, 1);
select t.act('00000000-0000-0000-0000-00000000000b');
select public.cart_set_item((select id from public.products where sku='SGS24-256'), null, 1);
SQL

race() {  # $1 user id, $2 key
  $P <<SQL 2>&1 || true
select t.act('$1');
select pg_sleep(0.5 - extract(milliseconds from clock_timestamp())::int % 500 / 1000.0);
select public.place_order('$2', 'pickup', 'pay_at_branch', (select id from public.branches limit 1), null, null)->>'reference';
SQL
}
race 00000000-0000-0000-0000-00000000000a race-key-aaaa > /tmp/race_a.txt &
race 00000000-0000-0000-0000-00000000000b race-key-bbbb > /tmp/race_b.txt &
wait
echo "A: $(grep -o 'MH-[0-9-]*\|OUT_OF_STOCK[^ ]*' /tmp/race_a.txt | head -1)"
echo "B: $(grep -o 'MH-[0-9-]*\|OUT_OF_STOCK[^ ]*' /tmp/race_b.txt | head -1)"
OK=$(cat /tmp/race_a.txt /tmp/race_b.txt | grep -c 'MH-' || true)
STOCK=$($P -c "select stock_quantity from public.products where sku='SGS24-256'")
echo "successful orders=$OK final stock=$STOCK"
[ "$OK" = "1" ] && [ "$STOCK" = "0" ] && echo "CONCURRENCY TEST PASSED" || { echo "CONCURRENCY TEST FAILED"; exit 1; }
