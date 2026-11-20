#!/usr/bin/env bash
# =====================================================================
#  SUPERMART POS  --  THE 4-PC OVERSELL RACE TEST
#
#  This is the single most important test in the project. It proves that
#  when two (or four) tills ring up the same item at the same instant,
#  the database serialises them and the loser gets a clean
#  "INSUFFICIENT_STOCK" error instead of two tills selling one unit.
#
#  Run:  sudo -u postgres bash local_test/race_test.sh
# =====================================================================
set -u
DB=${DB:-smtest}
# works whether you run it as your normal user or as the postgres user
if [ "$(id -un)" = "postgres" ]; then
  PSQL="psql -X -q -d $DB -tA"
else
  PSQL="sudo -u postgres psql -X -q -d $DB -tA"
fi

q()  { $PSQL -c "$1"; }
qj() { $PSQL -c "select set_config('jwt.claim.sub','$1',false); $2"; }

OWNER=$($PSQL -c "select id from auth.users where email='owner@supermart.local'")
CASH1=$($PSQL -c "select id from auth.users where email='cashier1@supermart.local'")
CASH2=$($PSQL -c "select id from auth.users where email='cashier2@supermart.local'")
CASH3=$($PSQL -c "select id from auth.users where email='supervisor@supermart.local'")
MANAGER=$($PSQL -c "select id from auth.users where email='manager@supermart.local'")
$PSQL -c "update public.profiles set is_active = true where email like '%@supermart.local';" >/dev/null
LAYS=$($PSQL -c "select id from public.products where barcode='8964000300015'")
ENG=$($PSQL -c "select name from public.products where barcode='8964000300015'")

# every run uses fresh client_uuids, otherwise create_sale would (correctly!)
# recognise last run's invoices as duplicates and skew the counting
RUN="r$(date +%s)$$"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { echo "PASS | $1"; pass=$((pass+1)); }
bad()  { echo "FAIL | $1"; fail=$((fail+1)); }

sale_sql() { # $1 = user id, $2 = qty, $3 = client uuid
  echo "select set_config('jwt.claim.sub','$1',false); select public.create_sale(jsonb_build_object(
     'client_uuid','$3','device_name','race-till','payment_method','cash','paid_amount',99999,
     'items', jsonb_build_array(jsonb_build_object('product_id','$LAYS','qty',$2))))->>'invoice_no';"
}

reset_stock() { qj "$OWNER" "select public.adjust_stock('$LAYS', $1, 'race test');" >/dev/null; }

echo "=============================================================="
echo " RACE 1: one unit left, till 1 and till 2 press Charge together"
echo "=============================================================="
reset_stock 1
echo "stock before: $(q "select stock_qty from public.products where id='$LAYS'")   ($ENG)"

# till 1 takes the row lock and holds it (it is "printing the receipt")
$PSQL -c "begin; $(sale_sql "$CASH1" 1 "$RUN-1-a") select pg_sleep(3); commit;" >$TMP/a.out 2>&1 &
A_PID=$!
sleep 1

# till 2 rings up the same last unit 1 second later - it must wait, then be refused
$PSQL -c "$(sale_sql "$CASH2" 1 "$RUN-1-b")" >$TMP/b.out 2>&1
B_RC=$?
wait $A_PID

A_OUT=$(grep -o 'INV-[0-9]*-[0-9]*' $TMP/a.out | head -1)
B_ERR=$(grep -o 'INSUFFICIENT_STOCK[^"]*' $TMP/b.out | head -1)
FINAL=$(q "select stock_qty from public.products where id='$LAYS'")
SOLD=$(q "select count(*) from public.sales where client_uuid in ('$RUN-1-a','$RUN-1-b')")

[ -n "$A_OUT" ] && ok "till 1 completed its sale ($A_OUT)" || bad "till 1 could not sell (unexpected): $(tail -1 $TMP/a.out)"
[ -n "$B_ERR" ] && ok "till 2 was refused with a friendly error: $B_ERR" || bad "till 2 was NOT refused (oversell!) output: $(tail -1 $TMP/b.out)"
[ "$SOLD" = "1" ] && ok "exactly one invoice exists for this race (no double sale)" || bad "$SOLD invoices were created for one unit of stock"
[ "$FINAL" = "0.000" ] || [ "$FINAL" = "0" ] && ok "stock landed exactly on zero, never negative" || bad "final stock is $FINAL (expected 0)"

echo
echo "=============================================================="
echo " RACE 2: 3 units on the shelf, 3 tills each try to sell 2"
echo "=============================================================="
reset_stock 3
echo "stock before: $(q "select stock_qty from public.products where id='$LAYS'")"

for u in "$CASH1:2-a" "$CASH2:2-b" "$CASH3:2-c"; do
  UID_="${u%%:*}"; CU_="${u##*:}"
  $PSQL -c "$(sale_sql "$UID_" 2 "$RUN-$CU_")" >$TMP/2-$CU_.out 2>&1 &
done
wait

WINS=$(grep -l 'INV-' $TMP/2-*.out 2>/dev/null | wc -l)
REFUSED=$(grep -l 'INSUFFICIENT_STOCK' $TMP/2-*.out 2>/dev/null | wc -l)
FINAL2=$(q "select stock_qty from public.products where id='$LAYS'")
SOLD2=$(q "select count(*) from public.sales where client_uuid like '$RUN-2-%'")

[ "$WINS" = "1" ] && ok "exactly one till won the 2-unit sale" || bad "$WINS tills were allowed to sell 2 units from a stock of 3"
[ "$REFUSED" = "2" ] && ok "the other two tills each got INSUFFICIENT_STOCK" || bad "expected 2 refusals, saw $REFUSED"
[ "$SOLD2" = "1" ] && ok "one invoice, no phantom stock" || bad "$SOLD2 invoices were created"
[ "$FINAL2" = "1.000" ] || [ "$FINAL2" = "1" ] && ok "stock left is exactly 1 unit (3 - 2)" || bad "final stock is $FINAL2 (expected 1)"

echo
echo "=============================================================="
echo " RACE 3: FOUR tills, one unit each, only two units in stock"
echo "=============================================================="
reset_stock 2
for u in "$CASH1:3-a" "$CASH2:3-b" "$CASH3:3-c" "$MANAGER:3-d"; do
  UID_="${u%%:*}"; CU_="${u##*:}"
  $PSQL -c "$(sale_sql "$UID_" 1 "$RUN-$CU_")" >$TMP/3-$CU_.out 2>&1 &
done
wait
FINAL3=$(q "select stock_qty from public.products where id='$LAYS'")
WINS3=$(grep -l 'INV-' $TMP/3-*.out 2>/dev/null | wc -l)
REF3=$(grep -l 'INSUFFICIENT_STOCK' $TMP/3-*.out 2>/dev/null | wc -l)
OTHER3=$(ls $TMP/3-*.out | wc -l)
[ "$WINS3" = "2" ] && ok "exactly two of the four tills sold the two units" || bad "$WINS3 succeeded (expected exactly 2)"
[ "$REF3" = "2" ] && ok "the other two tills were both refused (no overselling)" || bad "$REF3 refusals (expected 2)"
[ "$WINS3" = "2" ] && [ "$REF3" = "2" ] && [ "$OTHER3" = "4" ] && ok "every till got a clear answer: sold or refused" || bad "some till produced an unexpected result"
[ "$FINAL3" = "0.000" ] || [ "$FINAL3" = "0" ] && ok "stock finished on zero" || bad "final stock is $FINAL3 (expected 0)"

echo
echo "=============================================================="
echo " RACE 4: two tills, DIFFERENT products, same instant (deadlock check)"
echo "=============================================================="
SUGAR=$($PSQL -c "select id from public.products where barcode='8964000100062'")
qj "$OWNER" "select public.adjust_stock('$LAYS', 50, 'race 4'), public.adjust_stock('$SUGAR', 50, 'race 4');" >/dev/null
# till A sells lays then sugar, till B sells sugar then lays - opposite lock order
$PSQL -c "select set_config('jwt.claim.sub','$CASH1',false);
  select public.create_sale(jsonb_build_object('client_uuid','$RUN-4-a','device_name','race-till','payment_method','cash','paid_amount',99999,
    'items', jsonb_build_array(jsonb_build_object('product_id','$LAYS','qty',1), jsonb_build_object('product_id','$SUGAR','qty',1))));" >$TMP/d1.out 2>&1 &
$PSQL -c "select set_config('jwt.claim.sub','$CASH2',false);
  select public.create_sale(jsonb_build_object('client_uuid','$RUN-4-b','device_name','race-till','payment_method','cash','paid_amount',99999,
    'items', jsonb_build_array(jsonb_build_object('product_id','$SUGAR','qty',1), jsonb_build_object('product_id','$LAYS','qty',1))));" >$TMP/d2.out 2>&1 &
wait
DEAD=$(grep -ci 'deadlock' $TMP/d1.out $TMP/d2.out | awk -F: '{s+=$2} END {print s}')
[ "$DEAD" = "0" ] && ok "no deadlock when two tills ring up the same two items in opposite order" || bad "deadlock detected"
[ "$(q "select count(*) from public.sales where client_uuid like '$RUN-4-%'")" = "2" ] \
  && ok "both invoices posted correctly" || bad "expected 2 invoices"

echo
echo "=============================================================="
echo " RESULT:  $pass passed, $fail failed"
echo "=============================================================="
[ "$fail" = "0" ] && echo "The 4-PC oversell protection works." || echo "SOMETHING IS WRONG - do not put this in front of customers."
exit $fail
