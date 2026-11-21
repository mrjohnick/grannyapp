-- Tester for fangst av en granny som ikke er lagets egen: poeng, fri igjen, fredet.
-- I testspillet: Lag Blå har Astrid, Lag Rød har Gerd, Lag Grønn har Solveig.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(19);

insert into auth.users (id, aud, role) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('eeeeeeee-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Lag Rød
  ('eeeeeeee-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Gerd
  ('eeeeeeee-0000-0000-0000-000000000004', 'authenticated', 'authenticated');  -- spilleder

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.points(team text) returns int language sql security definer as $$
  select coalesce(sum(l.delta), 0)::int from public.points_ledger l join public.teams t on t.id = l.team_id where t.name = team
$$;
create function pg_temp.gerd() returns public.grannies language sql security definer as $$
  select * from public.grannies where id = '00000000-0000-0000-0000-0000000000a2'
$$;
create function pg_temp.ev(p_audience text, p_kind text) returns int language sql security definer as $$
  select count(*)::int from public.events where audience = p_audience and kind = p_kind
$$;
-- Spilleder godkjenner siste åpne krav.
create function pg_temp.approve() returns void language plpgsql as $$
declare id uuid;
begin
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000004');
  select (x->>'id')::uuid into id from jsonb_array_elements(public.admin_catch_queue()) x
   where x->>'status' = 'pending' order by (x->>'registered_s')::int desc limit 1;
  perform public.admin_resolve_catch(id, true);
end $$;

select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000002'); select public.join_game('TEST-ROD');
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000003'); select public.join_game('TEST-GERD');
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000004'); select public.join_game('TEST-ADMIN');
select pg_temp.as_postgres(); select pg_temp.at(1000);

-- Lag Blå ser at Gerd ikke er deres: 10 poeng, tar henne ikke ut.
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000001');
select ok(public.team_catch_targets() @> '[{"name": "Gerd", "points": 10, "takes_out": false}]', 'Gerd gir Lag Blå 10p og går fri');
select ok(public.team_catch_targets() @> '[{"name": "Astrid", "points": 15, "takes_out": true}]', 'egen granny tar henne ut');

-- Lag Blå tar Gerd. Spilleder får vite at hun går fri.
select public.register_catch('00000000-0000-0000-0000-0000000000a2');
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000004');
select ok(public.admin_catch_queue() @> '[{"granny_name": "Gerd", "takes_out": false}]', 'spilleders kø sier at hun går fri');
select pg_temp.approve();

select pg_temp.as_postgres();
select is(pg_temp.points('Lag Blå'), 10, 'Lag Blå får 10 poeng');
select is((pg_temp.gerd()).caught_at_s, null, 'Gerd er ikke ute av jakten');
select is((pg_temp.gerd()).protected_until_s, 1300, 'Gerd er fredet i 5 min fra godkjenningen');
select is(pg_temp.ev('teams', 'catch_released'), 1, 'lagene får beskjed');
select is(pg_temp.ev('granny', 'catch_released_me'), 1, 'Gerd får beskjed om at hun er fri');
select is(pg_temp.ev('all', 'catch_confirmed'), 0, 'ingen «er fanget»-melding');

select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000003');
select is((public.granny_status()->>'protected_until_s')::int, 1300, 'Gerd ser fredningen i appen');

-- Fredet: ingen kan registrere henne. Lag Blå kan ikke ta henne igjen.
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000002');
select throws_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a2') $$, 'P0001', 'Hun er fredet', 'fredet granny kan ikke registreres');
select pg_temp.as_postgres(); select pg_temp.at(1400);
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000001');
select ok(public.team_catch_targets() @> '[{"name": "Gerd", "taken_by_us": true}]', 'Lag Blå ser at de har tatt henne');
select throws_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a2') $$, 'P0001', 'Dere har allerede tatt henne', 'samme lag får ikke poeng for henne to ganger');

-- Bonus-granny: går også fri, 20 poeng.
select pg_temp.as_postgres();
update public.teams set assigned_granny_id = null where name = 'Lag Grønn';
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000001');
select public.register_catch('00000000-0000-0000-0000-0000000000a3');
select pg_temp.approve();
select pg_temp.as_postgres();
select is(pg_temp.points('Lag Blå'), 30, 'bonus-granny gir 20 poeng');
select is((select caught_at_s from public.grannies where id = '00000000-0000-0000-0000-0000000000a3'), null, 'bonus-grannyen går fri');

-- Etter fredningen: eget lag tar Gerd, og da er hun ute.
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000002');
select public.register_catch('00000000-0000-0000-0000-0000000000a2');
select pg_temp.approve();
select pg_temp.as_postgres();
select is(pg_temp.points('Lag Rød'), 15, 'eget lag får 15 poeng');
select is((pg_temp.gerd()).caught_at_s, 1400, 'Gerd er ute av jakten');
select is((pg_temp.gerd()).catch_order, 1, 'hun er fanget som nr. 1');

-- Ny runde nullstiller fredningen.
update public.games set status = 'ended', ended_at = now() where id = '00000000-0000-0000-0000-000000000001';
select pg_temp.as_user('eeeeeeee-0000-0000-0000-000000000004');
select public.admin_reset_game();
select pg_temp.as_postgres();
select is((select count(*)::int from public.grannies where protected_until_s is not null), 0, 'ny runde fjerner fredningen');

select * from finish();
rollback;
