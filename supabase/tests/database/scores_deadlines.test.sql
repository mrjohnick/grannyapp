-- Tester for hemmelig poengtavle, plasseringspoeng, tidsfrist på side quests og data_version.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(18);

insert into auth.users (id, aud, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('cccccccc-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Astrid
  ('cccccccc-0000-0000-0000-000000000003', 'authenticated', 'authenticated');  -- Spilleder

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.granny(p_name text) returns jsonb language sql as $$
  select x from jsonb_array_elements(public.game_summary()->'grannies') x where x->>'name' = p_name
$$;
create function pg_temp.version() returns bigint language sql security definer as $$
  select data_version from public.games where id = '00000000-0000-0000-0000-000000000001'
$$;

select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000002'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');

-- Plasseringspoeng velges av spilleder
select lives_ok($$ select public.admin_update_game('{"granny_place_points": [30, 12, 5]}') $$, 'spilleder setter poeng per plassering');
select throws_ok($$ select public.admin_update_game('{"granny_place_points": [10, -1]}') $$, 'P0001',
  'Poeng per plassering må være tall som er 0 eller mer', 'negative poeng avvises');
select is(public.game_state()->'granny_place_points', '[30, 12, 5]'::jsonb, 'spilleder ser listen');
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001');
select is(public.game_state()->>'granny_place_points', null, 'lag ser den ikke');

-- Tre grannyer i testspillet (uten Rømlingen). Astrid fanges først, Gerd etterpå.
select pg_temp.as_postgres(); select pg_temp.at(2000);
update public.grannies set caught_at_s = 1000, catch_order = 1 where id = '00000000-0000-0000-0000-0000000000a1';
update public.grannies set caught_at_s = 1500, catch_order = 2 where id = '00000000-0000-0000-0000-0000000000a2';

select pg_temp.as_user('cccccccc-0000-0000-0000-000000000003');
select is((pg_temp.granny('Solveig')->>'place')::int, 1, 'den som er fri, har 1. plass');
select is((pg_temp.granny('Solveig')->>'placement')::int, 30, 'og får poengene for 1. plass');
select is((pg_temp.granny('Gerd')->>'place')::int, 2, 'sist fanget får 2. plass');
select is((pg_temp.granny('Astrid')->>'placement')::int, 5, 'først fanget får siste plass (5p)');

-- Poengtavlen er hemmelig
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001');
select is(jsonb_array_length(public.team_status()->'scoreboard'), 1, 'laget ser bare seg selv');
select throws_ok($$ select public.game_summary() $$, '42501', 'Bare spilleder ser resultatet', 'laget ser ikke oppsummeringen');
select pg_temp.as_postgres(); update public.games set status = 'ended', ended_at = now() where id = '00000000-0000-0000-0000-000000000001';
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001');
select throws_ok($$ select public.game_summary() $$, '42501', 'Bare spilleder ser resultatet', 'heller ikke etter spillet');

-- Tidsfrist på side quest
select pg_temp.as_postgres(); select pg_temp.at(2000);
update public.games set ended_at = null where id = '00000000-0000-0000-0000-000000000001';
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_save_quest(null, 'Rask', null, 3, 0, null, 'teams', null, 'live', 10) $$, 'oppdrag med 10 min frist');
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001');
select is((public.team_quests()->'quests'->0->>'deadline_s')::int, 2600, 'fristen er 10 min fra nå');
select pg_temp.as_postgres(); select pg_temp.at(2601);
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001');
select throws_ok(format($$ select public.deliver_quest(%L) $$, public.team_quests()->'quests'->0->>'id'), 'P0001', 'Fristen er ute', 'kan ikke levere etter fristen');

-- data_version øker når faste data endres
select pg_temp.as_postgres();
create temp table v as select pg_temp.version() as before;
update public.grannies set avatar_path = '00000000-0000-0000-0000-000000000001/avatar-x.jpg' where id = '00000000-0000-0000-0000-0000000000a3';
select ok(pg_temp.version() > (select before from v), 'nytt profilbilde øker data_version');
update v set before = pg_temp.version();
update public.grannies set caught_at_s = 2500 where id = '00000000-0000-0000-0000-0000000000a3';
select is(pg_temp.version(), (select before from v), 'en fangst øker den ikke');
update public.teams set name = 'Lag Blå 2' where id = '00000000-0000-0000-0000-0000000000b1';
select ok(pg_temp.version() > (select before from v), 'nytt lagnavn øker data_version');
select pg_temp.as_user('cccccccc-0000-0000-0000-000000000001');
select ok((public.game_state()->>'data_version')::bigint > 0, 'appen får data_version i spillstatusen');

select * from finish();
rollback;
