-- Tester for tilgang og ping-logikk. Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(22);

-- Testbrukere -------------------------------------------------------------
insert into auth.users (id, aud, role) values
  ('11111111-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå, telefon 1
  ('11111111-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Lag Blå, telefon 2
  ('11111111-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Astrid
  ('11111111-0000-0000-0000-000000000004', 'authenticated', 'authenticated'),  -- Rømlingen
  ('11111111-0000-0000-0000-000000000005', 'authenticated', 'authenticated');  -- Spilleder

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('role', 'postgres', true)
$$;

-- Bli med ------------------------------------------------------------------
select pg_temp.as_user('11111111-0000-0000-0000-000000000001');
select is((public.join_game(' test-bla ')).role, 'team'::public.player_role, 'lagkode gir rollen lag, uavhengig av mellomrom og store bokstaver');
select pg_temp.as_user('11111111-0000-0000-0000-000000000002');
select is((public.join_game('TEST-BLA')).team_id, '00000000-0000-0000-0000-0000000000b1'::uuid, 'to telefoner kan dele samme lag');
select throws_ok($$ select public.join_game('FINNES-IKKE') $$, 'P0002', 'Ukjent kode', 'ukjent kode avvises');
select pg_temp.as_user('11111111-0000-0000-0000-000000000003');
select public.join_game('TEST-ASTRID');
select pg_temp.as_user('11111111-0000-0000-0000-000000000004');
select public.join_game('TEST-ROMLING');
select pg_temp.as_user('11111111-0000-0000-0000-000000000005');
select public.join_game('TEST-ADMIN');

-- Spillet har gått i 1:00:30, og det har vært posisjoner før og etter ping 1:00
select pg_temp.as_postgres();
update public.games set status = 'running', started_at = now() - interval '3630 seconds'
where id = '00000000-0000-0000-0000-000000000001';

insert into public.positions (game_id, granny_id, source, geom, game_s) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'telegram', 'SRID=4326;POINT(8.5900 58.3400)', 3590),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'telegram', 'SRID=4326;POINT(8.5990 58.3450)', 3620),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a2', 'telegram', 'SRID=4326;POINT(8.5800 58.3380)', 3500),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a9', 'telegram', 'SRID=4326;POINT(8.5700 58.3350)', 3595);

-- Lag: hemmeligheter ---------------------------------------------------------
select pg_temp.as_user('11111111-0000-0000-0000-000000000001');
select is((select count(*) from public.positions)::int, 0, 'lag kan ikke lese posisjonstabellen');
select is((select count(*) from public.grannies where is_romling)::int, 0, 'lag uten lisens ser ikke Rømlingen');
select is((select count(*) from public.zones where kind = 'postkort')::int, 0, 'lag ser ikke postkortsonene');
select is((select count(*) from public.zones where kind in ('kaffekroken', 'bingo'))::int, 0, 'lag ser ikke Kaffekroken eller Bingo');
select is((select count(*) from public.zones where kind = 'nattevakt')::int, 1, 'lag ser Nattevaktens post etter 0:45');
select is((select count(*) from public.join_codes)::int, 0, 'lag kan ikke lese innloggingskoder');
select throws_ok($$ insert into public.catches (game_id, granny_id, team_id, registered_s)
                    values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 1) $$,
                 '42501', null, 'lag kan ikke skrive direkte til tabellene');

-- Lag: kartet viser posisjonen ved ping 1:00, ikke den nyeste ---------------
select is((public.team_map()->>'ping_s')::int, 3600, 'siste ping er 1:00');
select is(
  (select round((m->>'lng')::numeric, 4) from jsonb_array_elements(public.team_map()->'markers') m where m->>'name' = 'Astrid'),
  8.5900, 'Astrid vises der hun var ved pinget, ikke der hun er nå');
select is(
  (select m->>'kind' from jsonb_array_elements(public.team_map()->'markers') m where m->>'name' = 'Astrid'),
  'own_granny', 'lagets egen granny er merket');
select is(
  (select count(*) from jsonb_array_elements(public.team_map()->'markers') m where m->>'kind' = 'romling' and m->>'name' is null)::int,
  1, 'Rømlingen vises anonymt uten navn');

-- Sladring gjør Gerd live -----------------------------------------------------
select pg_temp.as_postgres();
insert into public.snitches (game_id, snitch_granny_id, target_granny_id, at_s, live_until_s)
values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 3620, 3680);
insert into public.positions (game_id, granny_id, source, geom, game_s) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a2', 'app', 'SRID=4326;POINT(8.5850 58.3390)', 3625);
select pg_temp.as_user('11111111-0000-0000-0000-000000000001');
select is(
  (select round((m->>'lng')::numeric, 4) || ' ' || (m->>'live_reason') from jsonb_array_elements(public.team_map()->'markers') m where m->>'name' = 'Gerd'),
  '8.5850 sladret', 'granny det er sladret på vises med nåværende posisjon');

-- Blindet lag får ingen markører -----------------------------------------------
select pg_temp.as_postgres();
insert into public.blinds (game_id, team_id, from_s, until_s)
values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 3500, 4100);
select pg_temp.as_user('11111111-0000-0000-0000-000000000002');
select is(jsonb_array_length(public.team_map()->'markers'), 0, 'blindet lag ser ingen grannies');

-- Granny og Rømling ---------------------------------------------------------
select pg_temp.as_user('11111111-0000-0000-0000-000000000003');
select is((select count(*) from public.zones where kind in ('kaffekroken', 'bingo'))::int, 2, 'granny ser Kaffekroken og Bingo');
select pg_temp.as_user('11111111-0000-0000-0000-000000000004');
select is((select count(*) from public.grannies)::int, 1, 'Rømlingen ser bare seg selv');

-- Pause fryser klokka ----------------------------------------------------------
select pg_temp.as_user('11111111-0000-0000-0000-000000000005');
select public.admin_set_status('pause');
select pg_temp.as_postgres();
update public.games set paused_at = paused_at - interval '120 seconds', started_at = started_at - interval '120 seconds'
where id = '00000000-0000-0000-0000-000000000001';
select pg_temp.as_user('11111111-0000-0000-0000-000000000005');
select ok((public.game_state()->>'game_s')::int between 3629 and 3632, 'spilltid står stille under pause');

-- Bare webhooken kan sende inn Telegram-posisjoner -----------------------------
select throws_ok($$ select public.telegram_ingest_location(1, 58.0, 8.0) $$, '42501', null,
                 'vanlige brukere kan ikke kalle Telegram-funksjonene');


-- Telegram-måling: bare spilleder, og hull regnes riktig -------------------
select pg_temp.as_postgres();
insert into public.positions (game_id, granny_id, source, geom, game_s, recorded_at) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a3', 'telegram', 'SRID=4326;POINT(8.59 58.34)', 1, now() - interval '300 seconds'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a3', 'telegram', 'SRID=4326;POINT(8.59 58.34)', 1, now() - interval '270 seconds'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a3', 'telegram', 'SRID=4326;POINT(8.59 58.34)', 1, now() - interval '30 seconds');
select pg_temp.as_user('11111111-0000-0000-0000-000000000005');
select is(
  (select (g->>'max_gap_s')::numeric::int || '/' || (g->>'updates') from jsonb_array_elements(public.admin_telegram_stats(10)->'grannies') g where g->>'name' = 'Solveig'),
  '240/3', 'målingen finner største hull og antall oppdateringer');
select pg_temp.as_user('11111111-0000-0000-0000-000000000001');
select throws_ok($$ select public.admin_telegram_stats(10) $$, '42501', null, 'lag kan ikke se målingen');

select * from finish();
rollback;
