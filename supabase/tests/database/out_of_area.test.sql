-- Tester for varsel og nedtelling når en granny er utenfor spillområdet.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(13);

insert into auth.users (id, aud, role) values
  ('dddddddd-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Astrid
  ('dddddddd-0000-0000-0000-000000000002', 'authenticated', 'authenticated');  -- Lag Rød

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
-- Spillområdet i testspillet er 58.330–58.352 N. 58.36 er utenfor.
create function pg_temp.pos(s int, lat float) returns void language sql as $$
  insert into public.positions (game_id, granny_id, source, geom, game_s)
  values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'app', public._point(lat, 8.59), s)
$$;
create function pg_temp.ev(p_audience text, p_kind text) returns int language sql security definer as $$
  select count(*)::int from public.events where audience = p_audience and kind = p_kind
$$;

select pg_temp.as_user('dddddddd-0000-0000-0000-000000000001'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('dddddddd-0000-0000-0000-000000000002'); select public.join_game('TEST-ROD');

-- Inne i området: ingen varsel
select pg_temp.as_postgres(); select pg_temp.at(1000); select pg_temp.pos(1000, 58.340);
select public.tick_out_of_area();
select is(pg_temp.ev('granny', 'out_of_area'), 0, 'ingen varsel når hun er inne');
select pg_temp.as_user('dddddddd-0000-0000-0000-000000000001');
select is(public.granny_status()->>'out_of_area', null, 'appen viser ingen nedtelling');

-- Utenfor: varsel med en gang, live etter 60 sek
select pg_temp.as_postgres(); select pg_temp.pos(1010, 58.360); select pg_temp.at(1015);
select is(public._out_live_at('00000000-0000-0000-0000-0000000000a1', 1015), 1060, 'hun blir live 60 sek etter siste posisjon inne');
select public.tick_out_of_area();
select is(pg_temp.ev('granny', 'out_of_area'), 1, 'grannyen varsles med en gang');
select is(pg_temp.ev('granny', 'out_live'), 0, 'hun er ikke live ennå');
select public.tick_out_of_area();
select is(pg_temp.ev('granny', 'out_of_area'), 1, 'bare ett varsel per gang hun går ut');
select pg_temp.as_user('dddddddd-0000-0000-0000-000000000001');
select is((public.granny_status()->'out_of_area'->>'live_at_s')::int, 1060, 'appen får tidspunktet til nedtellingen');
select pg_temp.as_user('dddddddd-0000-0000-0000-000000000002');
select ok(not public.team_map()->'markers' @> '[{"name": "Astrid", "live_reason": "utenfor"}]', 'lagene ser henne ikke live ennå');

select pg_temp.as_postgres(); select pg_temp.pos(1050, 58.361); select pg_temp.at(1065); select public.tick_out_of_area();
select is(pg_temp.ev('granny', 'out_live'), 1, 'grannyen får beskjed når hun er live');
select is(pg_temp.ev('admin', 'out_live'), 1, 'spilleder får også varsel');
select pg_temp.as_user('dddddddd-0000-0000-0000-000000000002');
select ok(public.team_map()->'markers' @> '[{"name": "Astrid", "live_reason": "utenfor"}]', 'lagene ser henne live');

-- Inne igjen
select pg_temp.as_postgres(); select pg_temp.pos(1070, 58.341); select pg_temp.at(1075);
select public.tick_out_of_area(); select public.tick_out_of_area();
select is(pg_temp.ev('granny', 'out_back'), 1, 'hun får beskjed én gang når hun er inne igjen');
select pg_temp.as_user('dddddddd-0000-0000-0000-000000000001');
select is(public.granny_status()->>'out_of_area', null, 'nedtellingen er borte');

select * from finish();
rollback;
