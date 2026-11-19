-- Tester for evnesekken (fire typer) og varsel til grannyer ved ping.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(20);

insert into auth.users (id, aud, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('aaaaaaaa-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Lag Rød
  ('aaaaaaaa-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Spilleder
  ('aaaaaaaa-0000-0000-0000-000000000004', 'authenticated', 'authenticated');  -- Gerd

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
create function pg_temp.has_event(p_granny uuid, p_kind text, p_title text) returns boolean language sql security definer as $$
  select exists (select 1 from public.events where granny_id = p_granny and kind = p_kind and title = p_title)
$$;
create function pg_temp.marker(p_name text) returns jsonb language sql as $$
  select m from jsonb_array_elements(public.team_map()->'markers') m where m->>'name' = p_name
$$;

-- En bonus-granny
select pg_temp.as_postgres();
insert into public.grannies (id, game_id, name) values ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-000000000001', 'Bonusbestemor');

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000002'); select public.join_game('TEST-ROD');
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000004'); select public.join_game('TEST-GERD');

-- Fire oppdrag med hver sin evne, alle godkjent for Lag Blå
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_save_quest(null, 'A', null, 0, 2, null, 'teams', null, 'ping_one') $$, 'oppdrag med to ping-evner');
select throws_ok($$ select public.admin_save_quest(null, 'X', null, 0, 1, null, 'teams', null, 'tull') $$, '22023', null, 'ukjent evne avvises');
select public.admin_save_quest(null, 'B', null, 0, 1, null, 'teams', null, 'ping_all');
select public.admin_save_quest(null, 'C', null, 0, 1, null, 'teams', null, 'ping_bonus');
select public.admin_save_quest(null, 'D', null, 0, 1, null, 'teams', null, 'live');
select pg_temp.as_postgres(); select pg_temp.at(1000);
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select public.deliver_quest((q->>'id')::uuid) from jsonb_array_elements(public.team_quests()->'quests') q;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000003');
select public.admin_review_quest((q->>'id')::uuid, true) from jsonb_array_elements(public.admin_quest_queue()) q;

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select is(public.team_quests()->'abilities', '{"ping_one": 2, "ping_all": 1, "ping_bonus": 1, "live": 1}'::jsonb, 'evnene samles i sekken');

-- Posisjoner. Gerd beveger seg etter pingen.
select pg_temp.as_postgres();
select pg_temp.pos('00000000-0000-0000-0000-0000000000a2', 990, 58.341);
select pg_temp.pos('00000000-0000-0000-0000-0000000000a3', 990, 58.342);
select pg_temp.pos('00000000-0000-0000-0000-0000000000a5', 990, 58.343);

-- Ping på én granny
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select lives_ok($$ select public.use_team_ability('ping_one', '00000000-0000-0000-0000-0000000000a2') $$, 'Lag Blå pinger Gerd');
select pg_temp.as_postgres(); select pg_temp.pos('00000000-0000-0000-0000-0000000000a2', 1005, 58.349); select pg_temp.at(1010);
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select is(round((pg_temp.marker('Gerd')->>'lat')::numeric, 3)::float, 58.341::float, 'laget ser Gerd der hun var ved pingen');
select is((pg_temp.marker('Gerd')->>'team_pinged')::boolean, true, 'merket som lagets ping');
select ok(pg_temp.has_event('00000000-0000-0000-0000-0000000000a2', 'pinged', 'Et lag har pinget deg.'), 'Gerd varsles');
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000002');
select is(pg_temp.marker('Gerd'), null, 'andre lag ser henne ikke');

-- Ping på bonus-grannyer
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select lives_ok($$ select public.use_team_ability('ping_bonus') $$, 'Lag Blå pinger bonus-grannyene');
select ok(pg_temp.marker('Bonusbestemor') is not null, 'laget ser bonus-grannyen');
select is(pg_temp.marker('Solveig'), null, 'men ikke de andre');
select ok(pg_temp.has_event('00000000-0000-0000-0000-0000000000a5', 'pinged', 'Et lag har pinget alle bonus-grannyer.'), 'bonus-grannyen varsles');

-- Ping på alle
select lives_ok($$ select public.use_team_ability('ping_all') $$, 'Lag Blå pinger alle');
select ok(pg_temp.marker('Solveig') is not null, 'nå ser laget Solveig også');
select ok(pg_temp.has_event('00000000-0000-0000-0000-0000000000a3', 'pinged', 'Et lag har pinget alle grannyer.'), 'Solveig varsles');
select throws_ok($$ select public.use_team_ability('ping_all') $$, 'P0001', 'Dere har ingen slike evner igjen', 'hver evne kan bare brukes én gang');

-- Live i 30 sek
select lives_ok($$ select public.use_team_ability('live', '00000000-0000-0000-0000-0000000000a3') $$, 'Lag Blå ser Solveig live');
select is(pg_temp.marker('Solveig')->>'live_reason', 'evne', 'Solveig er live for laget');
select pg_temp.as_postgres(); select pg_temp.at(1045);
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select is(pg_temp.marker('Solveig')->>'live_reason', null, 'etter 30 sek er hun ikke live lenger');

-- Varsel ved vanlig ping (testspillet pinger 0:15)
select pg_temp.as_postgres(); select pg_temp.at(910); select public.tick_granny_ping_alerts();
select ok(pg_temp.has_event('00000000-0000-0000-0000-0000000000a2', 'pinged', 'Ping!'), 'grannyen varsles ved vanlig ping');

select * from finish();
rollback;
