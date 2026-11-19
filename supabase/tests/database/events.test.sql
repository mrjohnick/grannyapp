-- Tester for varslingssiden (my_event_history).
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(7);

insert into auth.users (id, aud, role) values
  ('55555555-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('55555555-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Lag Rød
  ('55555555-0000-0000-0000-000000000003', 'authenticated', 'authenticated');  -- Astrid

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;

select pg_temp.as_user('55555555-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('55555555-0000-0000-0000-000000000002'); select public.join_game('TEST-ROD');
select pg_temp.as_user('55555555-0000-0000-0000-000000000003'); select public.join_game('TEST-ASTRID');

select pg_temp.as_postgres();
insert into public.events (game_id, at_s, created_at, audience, team_id, kind, title) values
  ('00000000-0000-0000-0000-000000000001', 600,  now() - interval '1 hour', 'all',   null, 'message', 'Gammel beskjed til alle'),
  ('00000000-0000-0000-0000-000000000001', 3000, now(),                     'teams', null, 'message', 'Ny beskjed til lagene'),
  ('00000000-0000-0000-0000-000000000001', 3100, now(),                     'team',  '00000000-0000-0000-0000-0000000000b2', 'message', 'Bare til Lag Rød');

select pg_temp.as_user('55555555-0000-0000-0000-000000000001');
select ok(public.my_event_history() @> '[{"title": "Gammel beskjed til alle"}]', 'historikken har varsler eldre enn 15 minutter');
select ok(not public.my_events() @> '[{"title": "Gammel beskjed til alle"}]', 'my_events() viser dem ikke');
select ok(public.my_event_history() @> '[{"title": "Ny beskjed til lagene"}]', 'lagene ser beskjeden til lagene');
select ok(not public.my_event_history() @> '[{"title": "Bare til Lag Rød"}]', 'Lag Blå ser ikke Lag Røds varsel');
select is((select (public.my_event_history()->0->>'title')), 'Gammel beskjed til alle', 'eldste varsel kommer først');

select pg_temp.as_user('55555555-0000-0000-0000-000000000002');
select ok(public.my_event_history() @> '[{"title": "Bare til Lag Rød"}]', 'Lag Rød ser sitt eget varsel');

select pg_temp.as_user('55555555-0000-0000-0000-000000000003');
select ok(not public.my_event_history() @> '[{"title": "Ny beskjed til lagene"}]', 'grannyen ser ikke beskjeder til lagene');

select * from finish();
rollback;
