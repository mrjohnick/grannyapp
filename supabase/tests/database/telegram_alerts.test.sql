-- Tester for varsler i Telegram (kobling, mottakere, /stopp).
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(18);

insert into auth.users (id, aud, role) values
  ('66666666-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('66666666-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Astrid
  ('66666666-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Spilleder
  ('66666666-0000-0000-0000-000000000004', 'authenticated', 'authenticated');  -- Lag Rød

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
-- Legger inn et varsel og returnerer Telegram-chattene som skal ha det.
create function pg_temp.chats_for(p_audience text, p_team uuid default null, p_granny uuid default null) returns jsonb
language plpgsql as $$
declare
  eid bigint;
  claimed jsonb;
begin
  perform public.worker_claim_events();  -- tøm køen først
  insert into public.events (game_id, at_s, audience, team_id, granny_id, kind, title)
  values ('00000000-0000-0000-0000-000000000001', 100, p_audience, p_team, p_granny, 'message', 'Test')
  returning id into eid;
  claimed := public.worker_claim_events();
  return (select e->'chats' from jsonb_array_elements(claimed) e where (e->>'id')::bigint = eid);
end
$$;

select pg_temp.as_user('66666666-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('66666666-0000-0000-0000-000000000002'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('66666666-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('66666666-0000-0000-0000-000000000004'); select public.join_game('TEST-ROD');

-- Kobling
select pg_temp.as_user('66666666-0000-0000-0000-000000000001');
select ok(public.my_telegram_alerts()->>'link_token' like 'v%', 'lag-telefonen får et eget token');
select is((public.my_telegram_alerts()->>'linked')::boolean, false, 'ikke koblet ennå');
select throws_ok($$ select public.telegram_start('vfinnesikke', 1, 1) $$, '42501', null, 'klienter kan ikke koble selv');

select pg_temp.as_postgres();
select is(public.telegram_start('vfinnesikke', 1, 1)->>'ok', 'false', 'ukjent token avvises');
select is(public.telegram_start(
  (select link_token from public.player_telegram where user_id = '66666666-0000-0000-0000-000000000001'), 111, 111),
  '{"ok": true, "kind": "player", "name": "Lag Blå"}'::jsonb, 'laget kobles');

select pg_temp.as_user('66666666-0000-0000-0000-000000000001');
select is((public.my_telegram_alerts()->>'linked')::boolean, true, 'appen ser at laget er koblet');

select pg_temp.as_user('66666666-0000-0000-0000-000000000002');
select is(public.my_telegram_alerts()->>'link_token', 'test-astrid', 'grannyen bruker samme lenke som for posisjon (fra seed)');

select pg_temp.as_user('66666666-0000-0000-0000-000000000003');
select public.my_telegram_alerts();

select pg_temp.as_postgres();
select is(public.telegram_start(
  (select link_token from public.granny_telegram where granny_id = '00000000-0000-0000-0000-0000000000a1'), 222, 222)->>'kind',
  'granny', 'grannyen kobles');
select public.telegram_start(
  (select link_token from public.player_telegram where user_id = '66666666-0000-0000-0000-000000000003'), 333, 333);

-- Mottakere
select is(pg_temp.chats_for('teams'), '[111]'::jsonb, 'varsel til lagene går til lagets chat');
select is(pg_temp.chats_for('granny', null, '00000000-0000-0000-0000-0000000000a1'), '[222]'::jsonb, 'varsel til grannyen går til hennes chat');
select is(pg_temp.chats_for('admin'), '[333]'::jsonb, 'spilleder får sine varsler');
select is(pg_temp.chats_for('all'), '[111, 222]'::jsonb, 'spilleder får ikke alt, som med push');
select is(pg_temp.chats_for('team', '00000000-0000-0000-0000-0000000000b2'), '[]'::jsonb, 'Lag Rød har ikke koblet seg til');

-- Oversikt for spilleder
select pg_temp.as_user('66666666-0000-0000-0000-000000000003');
select is((select (t->>'telegram')::int from jsonb_array_elements(public.admin_telegram_alerts()->'teams') t where t->>'name' = 'Lag Blå'),
  1, 'spilleder ser at Lag Blå har Telegram');
select throws_ok($$ select public.admin_telegram_alerts() $$, '42501', null, 'bare spilleder ser oversikten')
  from (select pg_temp.as_user('66666666-0000-0000-0000-000000000001')) x;

-- /stopp
select pg_temp.as_postgres();
select is(public.telegram_set_muted(111, true), 1, '/stopp skrur av laget');
select is(pg_temp.chats_for('teams'), '[]'::jsonb, 'ingen varsler etter /stopp');
select public.telegram_set_muted(111, false);
select public.worker_telegram_blocked(222);
select is(pg_temp.chats_for('granny', null, '00000000-0000-0000-0000-0000000000a1'), '[]'::jsonb, 'blokkert bot får ingen varsler');

select * from finish();
rollback;
