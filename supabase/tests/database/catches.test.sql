-- Tester for fangst. Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(20);

insert into auth.users (id, aud, role) values
  ('22222222-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('22222222-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Lag Rød
  ('22222222-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Astrid
  ('22222222-0000-0000-0000-000000000004', 'authenticated', 'authenticated'),  -- Gerd
  ('22222222-0000-0000-0000-000000000005', 'authenticated', 'authenticated');  -- Spilleder

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.team_points(tid uuid) returns int language sql as $$
  select coalesce(sum(delta), 0)::int from public.points_ledger where team_id = tid
$$;

select pg_temp.as_user('22222222-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('22222222-0000-0000-0000-000000000002'); select public.join_game('TEST-ROD');
select pg_temp.as_user('22222222-0000-0000-0000-000000000003'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('22222222-0000-0000-0000-000000000004'); select public.join_game('TEST-GERD');
select pg_temp.as_user('22222222-0000-0000-0000-000000000005'); select public.join_game('TEST-ADMIN');

-- Før start ------------------------------------------------------------------
select pg_temp.as_user('22222222-0000-0000-0000-000000000001');
select throws_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a2') $$,
  'P0001', 'Spillet er ikke i gang', 'kan ikke fange før spillet er startet');

-- Spillet har gått 1:20:00 -------------------------------------------------------
select pg_temp.as_postgres();
update public.games set status = 'running', started_at = now() - interval '4800 seconds'
 where id = '00000000-0000-0000-0000-000000000001';
-- Astrid sladret på Gerd 1:15, altså innen 10 min før fangsten.
insert into public.snitches (game_id, snitch_granny_id, target_granny_id, at_s, live_until_s)
values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 4500, 4560);

-- To lag registrerer Gerd. Lag Rød har Gerd som egen granny.
select pg_temp.as_user('22222222-0000-0000-0000-000000000001');
select lives_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a2') $$, 'Lag Blå registrerer Gerd');
select lives_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a2') $$, 'samme lag kan trykke to ganger');
select pg_temp.as_user('22222222-0000-0000-0000-000000000002');
select lives_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a2') $$, 'Lag Rød registrerer Gerd også');

select throws_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a9') $$,
  'P0001', 'Krever lisens', 'Rømlingen kan ikke fanges uten lisens');

-- Gerd ser begge kravene og velger Lag Rød.
select pg_temp.as_user('22222222-0000-0000-0000-000000000004');
select is(jsonb_array_length(public.granny_pending_catches()), 2, 'Gerd ser to krav');
select public.granny_respond_catch(
  (select (c->>'id')::uuid from jsonb_array_elements(public.granny_pending_catches()) c where c->>'team_name' = 'Lag Rød'),
  true);

select pg_temp.as_postgres();
select is((select caught_by from public.grannies where name = 'Gerd'), '00000000-0000-0000-0000-0000000000b2'::uuid, 'Gerd er fanget av laget hun valgte');
select is((select status::text from public.catches c join public.teams t on t.id = c.team_id where t.name = 'Lag Blå'), 'void', 'det andre kravet faller bort');
select is(pg_temp.team_points('00000000-0000-0000-0000-0000000000b2'), 15, 'egen granny gir 15p');
select is((select delta from public.points_ledger where reason = 'sladrehank'), 3, 'sladrehanken får 3p når målet fanges innen 10 min');
select is((select delta from public.points_ledger where reason = 'honnorrabatt' and granny_id = '00000000-0000-0000-0000-0000000000a2'), 3, 'honnørrabatt etter 75 min og under 3 taxiturer');
select is((select catch_order from public.grannies where name = 'Gerd'), 1, 'Gerd er fanget som nr. 1');

-- Astrid sier nei til Lag Blå, og spilleder avgjør.
select pg_temp.as_user('22222222-0000-0000-0000-000000000001');
select public.register_catch('00000000-0000-0000-0000-0000000000a1');
select pg_temp.as_user('22222222-0000-0000-0000-000000000003');
select public.granny_respond_catch(null, false);
select pg_temp.as_user('22222222-0000-0000-0000-000000000005');
select is((select q->>'status' from jsonb_array_elements(public.admin_catch_queue()) q where q->>'granny_name' = 'Astrid'), 'rejected', 'avvist fangst havner hos spilleder');
select lives_ok($$ select public.admin_resolve_catch(
  (select (q->>'id')::uuid from jsonb_array_elements(public.admin_catch_queue()) q where q->>'granny_name' = 'Astrid'), true) $$,
  'spilleder kan la fangsten telle');
select pg_temp.as_postgres();
select is(pg_temp.team_points('00000000-0000-0000-0000-0000000000b1'), 15, 'Lag Blå får 15p for egen granny');
select is((select catch_order from public.grannies where name = 'Astrid'), 2, 'Astrid er fanget som nr. 2');
select is(jsonb_array_length((select public.admin_catch_queue() from (select pg_temp.as_user('22222222-0000-0000-0000-000000000005')) x)), 0, 'køen er tom etter avgjørelsen');

-- Tilgang ---------------------------------------------------------------------
select pg_temp.as_user('22222222-0000-0000-0000-000000000003');
select throws_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a3') $$, '42501', null, 'grannies kan ikke registrere fangst');
select throws_ok($$ select public.finalize_catch(gen_random_uuid(), 'granny') $$, '42501', null, 'finalize_catch kan ikke kalles direkte');

select pg_temp.as_postgres();
-- Alle funksjoner klienter kan kalle. Ny funksjon? Legg den til her med vilje.
select results_eq(
  $$ select p.proname::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
     order by 1 $$,
  $$ select v::text collate "C" from (values ('admin_catch_queue'), ('admin_live'), ('admin_resolve_catch'), ('admin_set_status'), ('admin_telegram_stats'),
            ('game_seconds'), ('game_state'), ('granny_pending_catches'), ('granny_respond_catch'), ('i_am_romling'),
            ('int_array_is_sorted'), ('is_admin_of'), ('join_game'), ('last_ping_s'), ('me'), ('my_game_id'),
            ('my_granny_id'), ('my_role'), ('my_team_id'), ('my_telegram'), ('next_ping_s'), ('register_catch'),
            ('report_position'), ('team_catches'), ('team_has_license'), ('team_map'), ('zone_visible')) x(v) $$,
  'bare tillatte funksjoner kan kalles av klienter');

select * from finish();
rollback;
