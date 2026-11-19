-- Tester for omstart, «vis granny live» og regler underveis.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(19);

insert into auth.users (id, aud, role) values
  ('44444444-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('44444444-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Astrid
  ('44444444-0000-0000-0000-000000000003', 'authenticated', 'authenticated');  -- Spilleder

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;

select pg_temp.as_user('44444444-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('44444444-0000-0000-0000-000000000002'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('44444444-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');

-- Spillet går, 0:20 -----------------------------------------------------------
select pg_temp.as_postgres(); select pg_temp.at(1200);
insert into public.positions (game_id, granny_id, source, geom, game_s)
values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'app', public._point(58.34, 8.59), 1190);

-- Regler underveis
select pg_temp.as_user('44444444-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_update_game('{"rules": {"blind_s": 300}}') $$, 'spilleder kan endre regler mens spillet går');
select pg_temp.as_postgres();
select is((select (rules->>'blind_s')::int from public.games where id = '00000000-0000-0000-0000-000000000001'), 300, 'regelen er lagret');
select is((select (rules->>'snitch_live_s')::int from public.games where id = '00000000-0000-0000-0000-000000000001'), 60, 'de andre reglene er urørt');
select pg_temp.as_user('44444444-0000-0000-0000-000000000003');
select throws_ok($$ select public.admin_update_game('{"duration_s": 600}') $$, 'P0001', 'Tidene kan bare endres før spillet starter', 'tidene er låst');
select throws_ok($$ select public.admin_update_game('{"rules": {"blind_s": -5}}') $$, 'P0001', 'Reglene må være tall som er 0 eller mer', 'negative regler avvises');

-- Vis granny live
select pg_temp.as_user('44444444-0000-0000-0000-000000000001');
select throws_ok($$ select public.admin_reveal_granny('00000000-0000-0000-0000-0000000000a1', 2) $$, '42501', null, 'bare spilleder kan vise en granny');
select pg_temp.as_user('44444444-0000-0000-0000-000000000003');
select throws_ok($$ select public.admin_reveal_granny('00000000-0000-0000-0000-0000000000a1', 0) $$, 'P0001', 'Velg mellom 1 og 30 minutter', 'antall minutter sjekkes');
select throws_ok($$ select public.admin_reveal_granny('00000000-0000-0000-0000-0000000000a9', 2) $$, 'P0001', 'Rømlingen kan ikke vises live', 'Rømlingen kan ikke vises');
select lives_ok($$ select public.admin_reveal_granny('00000000-0000-0000-0000-0000000000a1', 2) $$, 'spilleder viser Astrid live i 2 min');
select pg_temp.as_postgres();
select is(public.granny_live_reason('00000000-0000-0000-0000-0000000000a1', 1210), 'spilleder', 'Astrid er live');
select is(public.granny_live_reason('00000000-0000-0000-0000-0000000000a1', 1330), null, 'og ikke lenger etter 2 min');
select pg_temp.as_user('44444444-0000-0000-0000-000000000001');
select ok((select bool_or(m->>'live_reason' = 'spilleder') from jsonb_array_elements(public.team_map()->'markers') m), 'laget ser Astrid live på kartet');
select ok(public.my_events() @> '[{"kind": "reveal"}]', 'laget får varsel');
select pg_temp.as_user('44444444-0000-0000-0000-000000000002');
select ok(public.my_events() @> '[{"kind": "reveal_target"}]', 'Astrid får varsel');

-- Omstart
select pg_temp.as_user('44444444-0000-0000-0000-000000000003');
select throws_ok($$ select public.admin_reset_game() $$, 'P0001', 'Avslutt spillet før du starter det på nytt', 'kan ikke starte på nytt mens spillet går');
select public.admin_set_status('end');
select is(public.admin_reset_game()->>'status', 'setup', 'spillet er tilbake i oppsett');
select pg_temp.as_postgres();
select is((select count(*)::int from public.events where game_id = '00000000-0000-0000-0000-000000000001')
        + (select count(*)::int from public.reveals) + (select count(*)::int from public.positions)
        + (select count(*)::int from public.grannies where caught_at_s is not null), 0, 'alt fra forrige runde er borte');
select is((select count(*)::int from public.players where game_id = '00000000-0000-0000-0000-000000000001'), 3, 'innloggede telefoner beholdes');
select pg_temp.as_user('44444444-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_set_status('start') $$, 'spillet kan startes igjen');

select * from finish();
rollback;
