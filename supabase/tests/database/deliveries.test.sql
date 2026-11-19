-- Tester for «Marker som levert»: side quests for lag og grannyer, og postkort.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(17);

insert into auth.users (id, aud, role) values
  ('99999999-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('99999999-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Astrid
  ('99999999-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Spilleder
  ('99999999-0000-0000-0000-000000000004', 'authenticated', 'authenticated');  -- Gerd

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.gpoints(p_granny uuid) returns int language sql security definer as $$
  select coalesce(sum(delta), 0)::int from public.points_ledger where granny_id = p_granny
$$;

select pg_temp.as_user('99999999-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('99999999-0000-0000-0000-000000000002'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('99999999-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('99999999-0000-0000-0000-000000000004'); select public.join_game('TEST-GERD');
select pg_temp.as_postgres(); select pg_temp.at(1900);

-- Spilleder lager ett oppdrag for lagene og ett for grannyene
select pg_temp.as_user('99999999-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_save_quest(null, 'Syng', null, 3) $$, 'oppdrag til alle lag');
select lives_ok($$ select public.admin_save_quest(null, 'Dans', null, 4, 0, null, 'grannies') $$, 'oppdrag til alle grannyer');
select throws_ok($$ select public.admin_save_quest(null, 'Feil', null, 1, 0, '00000000-0000-0000-0000-0000000000b1', 'grannies') $$,
  '22023', null, 'et granny-oppdrag kan ikke gå til et lag');

-- Grannyen ser bare sitt oppdrag og leverer
select pg_temp.as_user('99999999-0000-0000-0000-000000000002');
select is(jsonb_array_length(public.granny_quests()->'quests'), 1, 'grannyen ser ett oppdrag');
select is(public.granny_quests()->'quests'->0->>'title', 'Dans', 'det er granny-oppdraget');
select lives_ok(format($$ select public.deliver_quest(%L) $$, public.granny_quests()->'quests'->0->>'id'), 'Astrid markerer som levert');
select throws_ok(format($$ select public.deliver_quest(%L) $$, public.granny_quests()->'quests'->0->>'id'),
  'P0001', 'Dere har allerede levert dette oppdraget', 'bare én levering');
select is(public.granny_quests()->'quests'->0->>'status', 'pending', 'oppdraget venter på spilleder');

-- Laget ser bare lag-oppdraget og leverer
select pg_temp.as_user('99999999-0000-0000-0000-000000000001');
select is(public.team_quests()->'quests'->0->>'title', 'Syng', 'laget ser lag-oppdraget');
select lives_ok(format($$ select public.deliver_quest(%L) $$, public.team_quests()->'quests'->0->>'id'), 'laget markerer som levert');

-- Spilleder godkjenner grannyens levering
select pg_temp.as_user('99999999-0000-0000-0000-000000000003');
select is(jsonb_array_length(public.admin_quest_queue()), 2, 'spilleder ser to leveringer');
select ok(public.my_events() @> '[{"kind": "quest_pending", "title": "Astrid har levert «Dans»."}]', 'spilleder får varsel');
select public.admin_review_quest(
  (select (q->>'id')::uuid from jsonb_array_elements(public.admin_quest_queue()) q where q->>'granny_name' = 'Astrid'), true);
select pg_temp.as_postgres();
select is(pg_temp.gpoints('00000000-0000-0000-0000-0000000000a1'), 4, 'Astrid får poengene først når spilleder godkjenner');

-- Postkort uten bilde (Postkort 2 er åpent 1:20–1:40 i testspillet)
select pg_temp.at(4900);
select pg_temp.as_user('99999999-0000-0000-0000-000000000001');
select lives_ok($$ select public.deliver_postkort(58.3395, 8.5990, 5) $$, 'laget leverer postkort uten bilde');
select throws_ok($$ select public.deliver_postkort() $$, 'P0001', 'Dere har allerede levert dette postkortet', 'bare én levering per postkort');
select pg_temp.as_user('99999999-0000-0000-0000-000000000003');
select is((select (x->>'storage_path') from jsonb_array_elements(public.admin_photos()) x where x->>'kind' = 'postkort'), null, 'spilleder ser leveringen uten bilde');
select lives_ok($$ select public.admin_review_photo((select (x->>'id')::uuid from jsonb_array_elements(public.admin_photos()) x where x->>'kind' = 'postkort'), true) $$,
  'spilleder godkjenner postkortet');

select * from finish();
rollback;
