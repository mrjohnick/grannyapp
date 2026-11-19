-- Tester for taxi-kanttilfeller: sjåfør uten svar, spilleder-verktøy, sletting
-- midt i en tur, ekstra turer og beskjed når grannyen blir fanget.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(31);

insert into auth.users (id, aud, role) values
  ('77777777-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Astrid
  ('77777777-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Taxi Test
  ('77777777-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Spilleder
  ('77777777-0000-0000-0000-000000000004', 'authenticated', 'authenticated'),  -- Lag Blå
  ('77777777-0000-0000-0000-000000000005', 'authenticated', 'authenticated');  -- Gerd

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
-- Sjåføren sender posisjon ved spilltid s.
create function pg_temp.driver_at(s int) returns void language sql as $$
  insert into public.positions (game_id, taxi_id, source, geom, game_s)
  values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c1', 'app', public._point(58.34, 8.59), s)
$$;
create function pg_temp.req(p_granny uuid) returns public.taxi_requests language sql security definer as $$
  -- now() er lik i hele transaksjonen, så sorter på åpne turer først og spilltid.
  select * from public.taxi_requests where granny_id = p_granny
   order by (status in ('waiting', 'accepted', 'picked_up')) desc, requested_s desc limit 1
$$;
create function pg_temp.rides(p_granny uuid) returns int language sql security definer as $$
  select count(*)::int from public.taxi_rides where granny_id = p_granny
$$;
create function pg_temp.has_event(p_audience text, p_kind text, p_title text) returns boolean language sql security definer as $$
  select exists (select 1 from public.events where audience = p_audience and kind = p_kind and title = p_title)
$$;

select pg_temp.as_user('77777777-0000-0000-0000-000000000001'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.join_game('TEST-TAXI');
select pg_temp.as_user('77777777-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('77777777-0000-0000-0000-000000000004'); select public.join_game('TEST-BLA');
select pg_temp.as_user('77777777-0000-0000-0000-000000000005'); select public.join_game('TEST-GERD');

select pg_temp.as_postgres(); select pg_temp.at(1200); select pg_temp.driver_at(1200);

-- Sjåføren tar turen og blir så borte -----------------------------------------
select pg_temp.as_user('77777777-0000-0000-0000-000000000001'); select public.granny_request_taxi();
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_accept_next();
select ok(public.taxi_queue()->'active' ? 'position_age_s', 'sjåføren ser alderen på posisjonen');
select is((public.taxi_queue()->>'timeout_s')::int, 300, 'og grensen før turen gis videre');

select pg_temp.as_postgres(); select pg_temp.at(1340);
select is(public.tick_taxis(), 0, '2 min uten posisjon: turen beholdes');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).warned, false, 'ingen varsel ennå');
select pg_temp.at(1360); select public.tick_taxis();
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).warned, true, '2,5 min: sjåføren varsles');
select pg_temp.as_user('77777777-0000-0000-0000-000000000002');
select ok(public.my_events() @> '[{"kind": "taxi_warning"}]', 'sjåføren får varselet');
select pg_temp.as_user('77777777-0000-0000-0000-000000000004');
select ok(not public.my_event_history() @> '[{"kind": "taxi_warning"}]', 'lagene ser det ikke');

select pg_temp.as_postgres(); select pg_temp.at(1510);
select is(public.tick_taxis(), 1, '5 min: turen gis videre');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).status, 'waiting', 'Astrid er tilbake i køen');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).taxi_id, null, 'uten taxi');
select ok(pg_temp.has_event('taxi', 'taxi_timeout', 'Turen til Astrid er gitt videre.'), 'sjåføren får beskjed');
select ok(pg_temp.has_event('granny', 'taxi_released', 'Taxien svarer ikke.'), 'Astrid får beskjed');

-- Sjåfør som sender posisjon, beholder turen
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_accept_next();
select pg_temp.as_postgres(); select pg_temp.driver_at(1700); select pg_temp.at(1800);
select is(public.tick_taxis(), 0, 'sjåfør med fersk posisjon beholder turen');

-- Spilleder angrer henting ----------------------------------------------------
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_pickup(58.34, 8.59, 5);
select pg_temp.as_postgres();
select is(pg_temp.rides('00000000-0000-0000-0000-0000000000a1'), 1, 'turen er brukt');
select pg_temp.as_user('77777777-0000-0000-0000-000000000004');
select throws_ok($$ select public.admin_taxi_action((select id from public.taxi_requests limit 1), 'cancel') $$, '42501', null, 'bare spilleder');
select pg_temp.as_user('77777777-0000-0000-0000-000000000003');
select lives_ok(format($$ select public.admin_taxi_action(%L, 'undo_pickup') $$, (pg_temp.req('00000000-0000-0000-0000-0000000000a1')).id), 'spilleder angrer hentingen');
select pg_temp.as_postgres();
select is(pg_temp.rides('00000000-0000-0000-0000-0000000000a1'), 0, 'turen er ikke brukt likevel');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).status, 'accepted', 'taxien er fortsatt på vei');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).pickup, null, 'hentestedet er fjernet');

-- Ekstra tur ------------------------------------------------------------------
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_pickup(58.34, 8.59, 5); select public.taxi_dropoff();
select pg_temp.as_user('77777777-0000-0000-0000-000000000001');
select throws_ok($$ select public.granny_request_taxi() $$, 'P0001', 'Du har brukt opp taxiturene dine', 'turen er brukt opp');
select pg_temp.as_user('77777777-0000-0000-0000-000000000003');
select is(public.admin_taxi_extra_ride('00000000-0000-0000-0000-0000000000a1', 1), 1, 'spilleder gir en ekstra tur');
select pg_temp.as_user('77777777-0000-0000-0000-000000000001');
select is((public.granny_status()->>'taxi_rides')::int, 0, 'appen viser at hun har en tur igjen');
select lives_ok($$ select public.granny_request_taxi() $$, 'Astrid kan bestille igjen');

-- Spilleder gir turen videre og avbryter --------------------------------------
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_accept_next();
select pg_temp.as_user('77777777-0000-0000-0000-000000000003');
select lives_ok(format($$ select public.admin_taxi_action(%L, 'requeue') $$, (pg_temp.req('00000000-0000-0000-0000-0000000000a1')).id), 'spilleder gir turen videre');
select is(public.admin_taxi_overview()->'requests'->0->>'status', 'waiting', 'oversikten viser at hun venter');
select ok(public.admin_taxi_overview()->'online' ? '00000000-0000-0000-0000-0000000000c1', 'taxien er på nett');
select lives_ok(format($$ select public.admin_taxi_action(%L, 'cancel') $$, (pg_temp.req('00000000-0000-0000-0000-0000000000a1')).id), 'spilleder avbryter');
select is(jsonb_array_length(public.admin_taxi_overview()->'requests'), 0, 'ingen åpne turer');

-- Fangst mens taxien er på vei ------------------------------------------------
select pg_temp.as_user('77777777-0000-0000-0000-000000000005'); select public.granny_request_taxi();
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_accept_next();
select pg_temp.as_postgres();
update public.grannies set caught_at_s = 1800 where id = '00000000-0000-0000-0000-0000000000a2';
update public.taxi_requests set status = 'cancelled' where granny_id = '00000000-0000-0000-0000-0000000000a2' and status = 'accepted';
select ok(pg_temp.has_event('taxi', 'taxi_cancelled', 'Gerd er fanget.'), 'sjåføren får beskjed om fangsten');

-- Taxien slettes midt i en tur -------------------------------------------------
update public.grannies set caught_at_s = null where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('77777777-0000-0000-0000-000000000005'); select public.granny_request_taxi();
select pg_temp.as_user('77777777-0000-0000-0000-000000000002'); select public.taxi_accept_next();
select pg_temp.as_user('77777777-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_delete('taxi', '00000000-0000-0000-0000-0000000000c1') $$, 'spilleder sletter taxien');
select pg_temp.as_postgres();
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a2')).status, 'waiting', 'Gerd er tilbake i køen, ikke låst');

select * from finish();
rollback;
