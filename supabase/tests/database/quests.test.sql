-- Tester for side quests, evner, selfie ved fangst, profilbilder, bonuspoeng og ny standardtid.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(27);

insert into auth.users (id, aud, role) values
  ('55555555-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('55555555-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Astrid
  ('55555555-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Spilleder
  ('55555555-0000-0000-0000-000000000004', 'authenticated', 'authenticated');  -- Lag Rød

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.qid(t text) returns uuid language sql security definer as $$
  select id from public.quests where title = t
$$;
create function pg_temp.sid() returns uuid language sql security definer as $$
  select id from public.quest_submissions limit 1
$$;
create function pg_temp.cid() returns uuid language sql security definer as $$
  select id from public.catches where granny_id = '00000000-0000-0000-0000-0000000000a5'
$$;
create function pg_temp.points(team uuid) returns int language sql as $$
  select coalesce(sum(delta), 0)::int from public.points_ledger where team_id = team
$$;

-- Nye spill varer 1:30 og har én taxitur per granny ---------------------------
insert into public.games (id, name) values ('00000000-0000-0000-0000-0000000000ff', 'Ny');
select is((select duration_s from public.games where id = '00000000-0000-0000-0000-0000000000ff'), 5400, 'nye spill varer 1:30');
select is((select romling_reveal_s from public.games where id = '00000000-0000-0000-0000-0000000000ff'), 2400, 'Rømlingen kommer 0:40');
select is((select (rules->>'taxi_max_rides')::int from public.games where id = '00000000-0000-0000-0000-0000000000ff'), 1, 'én taxitur per granny');
select ok(not ((select rules from public.games where id = '00000000-0000-0000-0000-0000000000ff') ? 'honnor_max_rides'), 'honnørrabatten er borte fra reglene');
delete from public.games where id = '00000000-0000-0000-0000-0000000000ff';

-- En bonus-granny uten lag
insert into public.grannies (id, game_id, name) values
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-000000000001', 'Bonusbestemor');
insert into public.join_codes (code, game_id, role, granny_id) values
  ('TEST-BONUS', '00000000-0000-0000-0000-000000000001', 'granny', '00000000-0000-0000-0000-0000000000a5');

select pg_temp.as_user('55555555-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('55555555-0000-0000-0000-000000000002'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('55555555-0000-0000-0000-000000000003'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('55555555-0000-0000-0000-000000000004'); select public.join_game('TEST-ROD');

-- Profilbilde ------------------------------------------------------------------
select pg_temp.as_user('55555555-0000-0000-0000-000000000002');
select throws_ok($$ select public.granny_set_avatar('annet-spill/avatar-x.jpg') $$, '22023', 'Ugyldig bilde', 'profilbildet må ligge i eget spill');
select lives_ok($$ select public.granny_set_avatar('00000000-0000-0000-0000-000000000001/avatar-astrid.jpg') $$, 'Astrid lagrer profilbilde');
select pg_temp.as_user('55555555-0000-0000-0000-000000000001');
select ok(public.can_view_photo('00000000-0000-0000-0000-000000000001/avatar-astrid.jpg'), 'lagene ser profilbildet');
select pg_temp.as_user('55555555-0000-0000-0000-000000000003');
select lives_ok($$ select public.admin_set_avatar('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-000000000001/avatar-bonus.jpg') $$,
  'spilleder kan sette profilbilde');

-- Side quest ---------------------------------------------------------------------
select throws_ok($$ select public.admin_save_quest(null, 'Tom', null, 0, 0) $$, 'P0001', 'Gi poeng, en evne eller begge', 'et oppdrag må gi noe');
select lives_ok($$ select public.admin_save_quest(null, 'Synge for en fremmed', 'Hele laget synger.', 5, 1) $$, 'spilleder lager side quest');
select lives_ok($$ select public.admin_save_quest(null, 'Bare for Rød', null, 3, 0, '00000000-0000-0000-0000-0000000000b2') $$, 'side quest til ett lag');

select pg_temp.as_postgres(); select pg_temp.at(1200);
select pg_temp.as_user('55555555-0000-0000-0000-000000000001');
select is(jsonb_array_length(public.team_quests()->'quests'), 1, 'Lag Blå ser bare oppdraget som gjelder dem');
select lives_ok($$ select public.submit_quest(pg_temp.qid('Synge for en fremmed'),
  '00000000-0000-0000-0000-000000000001/quest-sang.mp4', 'video') $$, 'laget sender video');
select throws_ok($$ select public.submit_quest(pg_temp.qid('Synge for en fremmed'),
  '00000000-0000-0000-0000-000000000001/quest-sang2.mp4', 'video') $$, 'P0001', 'Dere har allerede sendt inn dette oppdraget', 'bare én innsending om gangen');
select ok(not public.can_view_photo('00000000-0000-0000-0000-000000000001/quest-sang.mp4'), 'andre enn spilleder ser ikke beviset');

select pg_temp.as_user('55555555-0000-0000-0000-000000000003');
select is(jsonb_array_length(public.admin_quest_queue()), 1, 'spilleder ser innsendingen');
select ok(public.can_view_photo('00000000-0000-0000-0000-000000000001/quest-sang.mp4'), 'spilleder kan se videoen');
select lives_ok($$ select public.admin_review_quest(pg_temp.sid(), true) $$, 'spilleder godkjenner');
select pg_temp.as_postgres();
select is(pg_temp.points('00000000-0000-0000-0000-0000000000b1'), 5, 'laget får poengene');

-- Evnen: laget velger granny og ser henne live i 1 min
select pg_temp.as_user('55555555-0000-0000-0000-000000000001');
select is((public.team_quests()->>'abilities_left')::int, 1, 'laget har én evne');
select pg_temp.as_postgres();
insert into public.positions (game_id, granny_id, source, geom, game_s)
values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a5', 'app', public._point(58.34, 8.59), 1190);
select pg_temp.as_user('55555555-0000-0000-0000-000000000001');
select lives_ok($$ select public.team_use_ability('00000000-0000-0000-0000-0000000000a5') $$, 'laget bruker evnen på bonus-grannyen');
select ok(public.team_map()->'markers' @> '[{"name": "Bonusbestemor", "live_reason": "evne"}]', 'laget ser henne live');
select throws_ok($$ select public.team_use_ability('00000000-0000-0000-0000-0000000000a5') $$, 'P0001', 'Dere har ingen evner igjen', 'evnen er brukt opp');
select pg_temp.as_user('55555555-0000-0000-0000-000000000004');
select ok(not (public.team_map()->'markers' @> '[{"live_reason": "evne"}]'), 'andre lag ser henne ikke');

-- Fangst med selfie, og bonus-granny gir 20p --------------------------------------
select pg_temp.as_user('55555555-0000-0000-0000-000000000001');
select lives_ok($$ select public.register_catch('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-000000000001/selfie-1.jpg') $$,
  'laget registrerer fangst med selfie');
select pg_temp.as_user('55555555-0000-0000-0000-000000000003');
select is(public.admin_catch_queue()->0->>'selfie_path', '00000000-0000-0000-0000-000000000001/selfie-1.jpg', 'spilleder ser selfien');
select public.admin_resolve_catch(pg_temp.cid(), true);
select pg_temp.as_postgres();
select is(pg_temp.points('00000000-0000-0000-0000-0000000000b1'), 25, 'bonus-granny gir 20p');

select * from finish();
rollback;
