-- Tester for taxi som deler live-posisjon med boten i Telegram.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(7);

insert into auth.users (id, aud, role) values ('bbbbbbbb-0000-0000-0000-000000000001', 'authenticated', 'authenticated');

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;

select pg_temp.as_user('bbbbbbbb-0000-0000-0000-000000000001'); select public.join_game('TEST-TAXI');
select is(public.my_telegram_alerts()->>'last_position_age_s', null, 'ingen posisjon fra Telegram ennå');

select pg_temp.as_postgres();
select is(public.telegram_start(
  (select link_token from public.player_telegram where user_id = 'bbbbbbbb-0000-0000-0000-000000000001'), 777, 777)->>'role',
  'taxi', 'boten vet at det er en taxi');
select is(public.telegram_ingest_location(777, 58.34, 8.59, 5, 900), '{"ok": true, "is_live": true, "kind": "taxi"}'::jsonb, 'taxien deler live-posisjon');
select is((select count(*)::int from public.positions where taxi_id = '00000000-0000-0000-0000-0000000000c1' and source = 'telegram'), 1, 'posisjonen er lagret på taxien');
select ok(public._taxi_markers('00000000-0000-0000-0000-000000000001') @> '[{"name": "Taxi Test"}]', 'grannyene ser taxien på kartet');
select is(public.telegram_ingest_location(888, 58.34, 8.59)->>'ok', 'false', 'ukjent konto avvises');

select pg_temp.as_user('bbbbbbbb-0000-0000-0000-000000000001');
select ok((public.my_telegram_alerts()->>'last_position_age_s')::int < 60, 'appen ser at Telegram sender posisjonen');

select * from finish();
rollback;
