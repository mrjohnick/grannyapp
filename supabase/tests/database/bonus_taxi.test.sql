-- Tester for bonus-ping, taxi for fangede grannyer og tidsgrensen i taxien.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(29);

insert into auth.users (id, aud, role) values
  ('88888888-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('88888888-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Astrid
  ('88888888-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Gerd
  ('88888888-0000-0000-0000-000000000004', 'authenticated', 'authenticated'),  -- Taxi
  ('88888888-0000-0000-0000-000000000005', 'authenticated', 'authenticated'),  -- Spilleder
  ('88888888-0000-0000-0000-000000000006', 'authenticated', 'authenticated');  -- Bonusbestemor

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.pos(p_granny uuid, s int, lat float) returns void language sql as $$
  insert into public.positions (game_id, granny_id, source, geom, game_s)
  values ('00000000-0000-0000-0000-000000000001', p_granny, 'app', public._point(lat, 8.59), s)
$$;
create function pg_temp.marker_lat(p_name text) returns float language sql as $$
  select round((m->>'lat')::numeric, 3)::float from jsonb_array_elements(public.team_map()->'markers') m where m->>'name' = p_name
$$;
create function pg_temp.req(p_granny uuid) returns public.taxi_requests language sql security definer as $$
  select * from public.taxi_requests where granny_id = p_granny
   order by (status in ('waiting', 'accepted', 'picked_up')) desc, requested_s desc limit 1
$$;
create function pg_temp.has_event(p_audience text, p_kind text, p_title text) returns boolean language sql security definer as $$
  select exists (select 1 from public.events where audience = p_audience and kind = p_kind and title = p_title)
$$;

-- En bonus-granny (ingen lag har henne som egen granny).
select pg_temp.as_postgres();
insert into public.grannies (id, game_id, name) values ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-000000000001', 'Bonusbestemor');
insert into public.join_codes (code, game_id, role, granny_id) values ('TEST-BONUS', '00000000-0000-0000-0000-000000000001', 'granny', '00000000-0000-0000-0000-0000000000a5');

select pg_temp.as_user('88888888-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('88888888-0000-0000-0000-000000000002'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('88888888-0000-0000-0000-000000000003'); select public.join_game('TEST-GERD');
select pg_temp.as_user('88888888-0000-0000-0000-000000000004'); select public.join_game('TEST-TAXI');
select pg_temp.as_user('88888888-0000-0000-0000-000000000005'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('88888888-0000-0000-0000-000000000006'); select public.join_game('TEST-BONUS');

-- Oppsett ---------------------------------------------------------------------
select pg_temp.as_user('88888888-0000-0000-0000-000000000005');
select lives_ok($$ select public.admin_update_game('{"bonus_ping_schedule_s": [1600, 600]}') $$, 'spilleder setter bonus-ping');
select pg_temp.as_postgres();
select is((select bonus_ping_schedule_s from public.games where id = '00000000-0000-0000-0000-000000000001'), '{600,1600}'::int[], 'tidene sorteres');
select is(public._is_bonus_granny('00000000-0000-0000-0000-0000000000a5'), true, 'granny uten lag er bonus');
select is(public._is_bonus_granny('00000000-0000-0000-0000-0000000000a1'), false, 'Astrid er egen granny for Lag Blå');

-- Ping-tider ------------------------------------------------------------------
select pg_temp.at(500);
select pg_temp.as_user('88888888-0000-0000-0000-000000000001');
select is((public.game_state()->>'next_ping_s')::int, 600, 'lagene ser neste ping, også bonus');
select is((public.game_state()->>'next_ping_bonus')::boolean, true, 'og at den bare gjelder bonus-grannyene');
select pg_temp.as_user('88888888-0000-0000-0000-000000000006');
select is((public.game_state()->>'next_ping_s')::int, 600, 'bonus-grannyen ser sin egen neste ping');
select is((public.game_state()->'granny'->>'is_bonus')::boolean, true, 'og vet at hun er bonus');
select pg_temp.as_user('88888888-0000-0000-0000-000000000002');
select is((public.game_state()->>'next_ping_s')::int, 900, 'Astrid ser de vanlige tidene');

select pg_temp.as_postgres();
select pg_temp.pos('00000000-0000-0000-0000-0000000000a5', 550, 58.331);
select pg_temp.pos('00000000-0000-0000-0000-0000000000a5', 1550, 58.332);
select pg_temp.pos('00000000-0000-0000-0000-0000000000a5', 1650, 58.333);
select pg_temp.pos('00000000-0000-0000-0000-0000000000a2', 850, 58.341);
select pg_temp.pos('00000000-0000-0000-0000-0000000000a2', 1550, 58.342);
select pg_temp.at(1700);
select public.tick_bonus_pings();
select ok(pg_temp.has_event('teams', 'ping', 'Bonus-ping!'), 'bonus-ping varsler lagene');
select pg_temp.as_user('88888888-0000-0000-0000-000000000001');
select is(pg_temp.marker_lat('Bonusbestemor'), 58.332::float, 'bonus-grannyen vises fra bonus-pingen 0:26:40');
select is(pg_temp.marker_lat('Gerd'), 58.341::float, 'Gerd vises fra vanlig ping 0:15');

select pg_temp.as_user('88888888-0000-0000-0000-000000000005');
select throws_ok($$ select public.admin_update_game('{"bonus_ping_schedule_s": [700]}') $$, 'P0001',
  'Tidene kan bare endres før spillet starter', 'bonus-tidene er låst når spillet går');

-- Fanget granny tar taxi, sist i køen ----------------------------------------
select pg_temp.as_postgres();
update public.grannies set caught_at_s = 1650 where id = '00000000-0000-0000-0000-0000000000a1';
insert into public.taxi_rides (game_id, granny_id, at_s) values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 1000);
select pg_temp.as_user('88888888-0000-0000-0000-000000000002');
select lives_ok($$ select public.granny_request_taxi() $$, 'fanget Astrid kan bestille selv om turen er brukt');
select pg_temp.as_user('88888888-0000-0000-0000-000000000003');
select public.granny_request_taxi();
select pg_temp.as_user('88888888-0000-0000-0000-000000000002');
select is((public.granny_status()->'taxi_request'->>'queue_position')::int, 2, 'Astrid havner bak Gerd');
select is((public.granny_status()->'taxi_request'->>'last_in_queue')::boolean, true, 'og vet at hun står sist');
select pg_temp.as_user('88888888-0000-0000-0000-000000000004');
select is(public.taxi_queue()->'waiting'->0->>'granny_name', 'Gerd', 'sjåføren ser Gerd først');
select is((public.taxi_queue()->'waiting'->1->>'caught')::boolean, true, 'og at Astrid er fanget');

-- Tidsgrense i taxien ---------------------------------------------------------
select public.taxi_accept_next();
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a2')).status, 'accepted', 'sjåføren tar Gerd først');
select public.taxi_pickup(58.34, 8.59, 5);
select is((public.taxi_queue()->'active'->>'ride_ends_s')::int, 2300, 'Gerd har 10 min i bilen');
select pg_temp.as_postgres(); select pg_temp.at(2250);
select public.tick_taxis();
select ok(pg_temp.has_event('granny', 'taxi_ride_warning', 'Ett minutt igjen i taxien.'), 'Gerd varsles ett minutt før');
select ok(pg_temp.has_event('taxi', 'taxi_ride_warning', 'Ett minutt igjen med Gerd.'), 'sjåføren også');
select pg_temp.at(2300);
select is(public.tick_taxis(), 1, 'tiden er ute');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a2')).status, 'done', 'turen er avsluttet');
select ok(pg_temp.has_event('taxi', 'taxi_ride_over', 'Tiden er ute. Slipp av Gerd nå.'), 'sjåføren må slippe henne av');

-- Fanget granny i bilen: ingen tur, ingen varsel til lagene, ingen grense
select pg_temp.as_user('88888888-0000-0000-0000-000000000004');
select public.taxi_accept_next();
select public.taxi_pickup(58.35, 8.60, 5);
select pg_temp.as_postgres();
select is((select count(*)::int from public.taxi_rides where granny_id = '00000000-0000-0000-0000-0000000000a1'), 1, 'fanget tur teller ikke');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a1')).pickup, null, 'ingen hentested på lagenes kart');
select is((select count(*)::int from public.events where kind = 'taxi' and at_s = 2300), 0, 'lagene får ikke taxivarsel');
select pg_temp.as_user('88888888-0000-0000-0000-000000000004');
select is(public.taxi_queue()->'active'->>'ride_ends_s', null, 'ingen tidsgrense for en fanget granny');

select * from finish();
rollback;
