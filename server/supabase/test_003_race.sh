#!/usr/bin/env bash
# Race test for 003_storages.sql. Run AFTER test_003.sql, same database (default "postgres"):   bash test_003_race.sh
# 8 different teachers ask for 1 GiB at the SAME moment. The "race" storage has room for exactly 3 GiB and is the first in line,
# so exactly 3 reservations must land on it and its reserved_bytes must be exactly 3 GiB (never more). Not for production.
set -euo pipefail
DB="${PGDATABASE:-postgres}"
P="psql -X -q -At -v ON_ERROR_STOP=1 -d $DB"
GIB=1073741824

$P <<SQL
delete from public.upload_reservations where storage_id = 's-race';
delete from public.storages where id = 's-race';
insert into public.storages(id, name, endpoint, bucket, account_ref, secret_name, sort_order, used_bytes)
values ('s-race', 'Race', 'https://race.r2.cloudflarestorage.com', 'race', 'race-account', 'R2_RACE', -1, 8589934592 - 3 * $GIB);
do \$\$ declare i int; u uuid; l uuid; begin
  for i in 1..8 loop
    u := format('00000000-0000-0000-0000-%s', lpad('c' || i, 12, '0'))::uuid;
    l := format('dddddddd-0000-0000-0000-%s', lpad(i::text, 12, '0'))::uuid;
    insert into auth.users(id) values (u) on conflict do nothing;
    update public.profiles set role = 'teacher' where id = u;
    insert into public.lessons(id, owner, title, src) values (l, u, 'race ' || i, 'up') on conflict do nothing;
  end loop;
end \$\$;
SQL

rm -f /tmp/race_*.txt
for i in 1 2 3 4 5 6 7 8; do
  U="00000000-0000-0000-0000-$(printf '%012s' "c$i" | tr ' ' '0')"
  L="dddddddd-0000-0000-0000-$(printf '%012d' "$i")"
  ( $P -c "set role service_role; select coalesce(public.reserve_upload('$U','$L',$GIB)->>'storageId','none')" | tail -n 1 > "/tmp/race_$i.txt" ) &
done
wait

ON_RACE=$(cat /tmp/race_*.txt | grep -c '^s-race$' || true)
RESERVED=$($P -c "select reserved_bytes from public.storages where id = 's-race'")
echo "reservations that landed on the race storage: $ON_RACE (expected 3)"
echo "reserved_bytes of the race storage: $RESERVED (expected $((3 * GIB)))"
if [ "$ON_RACE" = "3" ] && [ "$RESERVED" = "$((3 * GIB))" ]; then echo "PASS: the limit held under concurrency"; else echo "FAIL: the limit did NOT hold"; exit 1; fi

# clean up
$P -c "delete from public.upload_reservations where storage_id = 's-race'; delete from public.storages where id = 's-race';" || true
