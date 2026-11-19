-- Tester for taxi, sladrehank, nabovakt, Rømlingen, bilder, varsler og slutt.
-- Kjør med: pnpm db:test
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(65);

insert into auth.users (id, aud, role) values
  ('33333333-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),  -- Lag Blå
  ('33333333-0000-0000-0000-000000000002', 'authenticated', 'authenticated'),  -- Lag Rød
  ('33333333-0000-0000-0000-000000000003', 'authenticated', 'authenticated'),  -- Astrid
  ('33333333-0000-0000-0000-000000000004', 'authenticated', 'authenticated'),  -- Gerd
  ('33333333-0000-0000-0000-000000000005', 'authenticated', 'authenticated'),  -- Spilleder
  ('33333333-0000-0000-0000-000000000006', 'authenticated', 'authenticated'),  -- Rømlingen
  ('33333333-0000-0000-0000-000000000007', 'authenticated', 'authenticated'),  -- Solveig
  ('33333333-0000-0000-0000-000000000008', 'authenticated', 'authenticated');  -- Taxisjåfør

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true)
$$;
create function pg_temp.as_postgres() returns void language sql as $$ select set_config('role', 'postgres', true) $$;
create function pg_temp.at(s int) returns void language sql as $$
  update public.games set status = 'running', started_at = now() - make_interval(secs => s), paused_total = '0'
   where id = '00000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.put(granny uuid, lat float8, lng float8, s int) returns void language sql as $$
  insert into public.positions (game_id, granny_id, source, geom, game_s)
  values ('00000000-0000-0000-0000-000000000001', granny, 'app', public._point(lat, lng), s)
$$;
create function pg_temp.points(team uuid) returns int language sql as $$
  select coalesce(sum(delta), 0)::int from public.points_ledger where team_id = team
$$;
create function pg_temp.gpoints(granny uuid) returns int language sql as $$
  select coalesce(sum(delta), 0)::int from public.points_ledger where granny_id = granny
$$;
create function pg_temp.file(name text) returns void language sql as $$
  insert into storage.objects (bucket_id, name) values ('photos', '00000000-0000-0000-0000-000000000001/' || name)
$$;

select pg_temp.as_user('33333333-0000-0000-0000-000000000001'); select public.join_game('TEST-BLA');
select pg_temp.as_user('33333333-0000-0000-0000-000000000002'); select public.join_game('TEST-ROD');
select pg_temp.as_user('33333333-0000-0000-0000-000000000003'); select public.join_game('TEST-ASTRID');
select pg_temp.as_user('33333333-0000-0000-0000-000000000004'); select public.join_game('TEST-GERD');
select pg_temp.as_user('33333333-0000-0000-0000-000000000005'); select public.join_game('TEST-ADMIN');
select pg_temp.as_user('33333333-0000-0000-0000-000000000006'); select public.join_game('TEST-ROMLING');
select pg_temp.as_user('33333333-0000-0000-0000-000000000007'); select public.join_game('TEST-SOLVEIG');
select pg_temp.as_user('33333333-0000-0000-0000-000000000008'); select public.join_game('TEST-TAXI');

-- Oppsett før start ------------------------------------------------------------
select pg_temp.as_user('33333333-0000-0000-0000-000000000005');
select lives_ok($$ select public.admin_save_granny(null, 'Ingrid') $$, 'spilleder kan legge til granny før start');
select ok((select code like 'G-%' from public.join_codes jc join public.grannies g on g.id = jc.granny_id where g.name = 'Ingrid'),
  'ny granny får innloggingskode');
select lives_ok($$ select public.admin_update_game('{"ping_schedule_s": [1800, 900], "name": "Testjakt 2"}') $$, 'spilleder kan endre tider før start');
select is((select ping_schedule_s from public.games where id = '00000000-0000-0000-0000-000000000001'), '{900,1800}'::int[], 'ping-tidene sorteres');
select public.admin_update_game('{"ping_schedule_s": [900,1800,2700,3600,4500,5100,5700,6300,6900,7200,7500,7800,8100,8400,8700,9000]}');
select public.admin_delete('granny', (select id from public.grannies where name = 'Ingrid'));

-- 0:16:40 – jakten er i gang ----------------------------------------------------
select pg_temp.as_postgres(); select pg_temp.at(1000);
select pg_temp.as_user('33333333-0000-0000-0000-000000000005');
select throws_ok($$ select public.admin_save_granny(null, 'Sen') $$, 'P0001', 'Kan bare endres før spillet starter', 'kan ikke legge til grannies etter start');
select throws_ok($$ select public.admin_update_game('{"duration_s": 100}') $$, 'P0001', 'Tidene kan bare endres før spillet starter', 'kan ikke endre tider etter start');

-- Taxi: Astrid bestiller, sjåføren tar turen, henter og leverer
select pg_temp.as_user('33333333-0000-0000-0000-000000000003');
select lives_ok($$ select public.granny_request_taxi() $$, 'Astrid bestiller taxi');
select throws_ok($$ select public.granny_request_taxi() $$, 'P0001', 'Du har allerede bestilt taxi', 'kan ikke bestille to ganger');
select pg_temp.as_user('33333333-0000-0000-0000-000000000008');
select ok(public.my_events() @> '[{"kind": "taxi_request"}]', 'sjåføren får varsel om bestillingen');
select is(public.taxi_queue()->'waiting'->0->>'granny_name', 'Astrid', 'Astrid står i køen');
select lives_ok($$ select public.taxi_accept_next() $$, 'sjåføren tar turen');
select pg_temp.as_user('33333333-0000-0000-0000-000000000003');
select is(public.granny_status()->'taxi_request'->>'status', 'accepted', 'Astrid ser at taxien kommer');
select pg_temp.as_user('33333333-0000-0000-0000-000000000008');
select lives_ok($$ select public.taxi_pickup(58.3405, 8.5934, 5) $$, 'sjåføren henter Astrid');
select lives_ok($$ select public.taxi_dropoff() $$, 'og leverer henne');
select pg_temp.as_user('33333333-0000-0000-0000-000000000003');
select is((public.granny_status()->>'taxi_rides')::int, 1, 'appen teller taxiturer');
select throws_ok($$ select public.granny_request_taxi() $$, 'P0001', 'Du har brukt opp taxiturene dine', 'én taxitur per granny');
select ok(public.granny_map()->'markers' @> '[{"kind": "taxi", "name": "Taxi Test"}]', 'grannies ser taxien på kartet');
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select ok(public.my_events() @> '[{"kind": "taxi", "title": "En granny har tatt taxi."}]', 'lagene får taxivarsel');
select ok(public.team_map()->'markers' @> '[{"kind": "taxi", "name": null}]', 'lagene ser hentestedet, uten navn');
select pg_temp.as_user('33333333-0000-0000-0000-000000000004');
select ok(not (public.my_events() @> '[{"kind": "taxi"}]'), 'grannies får ikke taxivarselet');

-- Sladrehanken: valgfri granny, ingen sone, bare siste posisjon (ingen live)
select pg_temp.as_postgres(); select pg_temp.put('00000000-0000-0000-0000-0000000000a2', 58.3390, 8.5850, 990);
select pg_temp.as_user('33333333-0000-0000-0000-000000000003');
select lives_ok($$ select public.granny_snitch('00000000-0000-0000-0000-0000000000a2', null, null) $$, 'Astrid sladrer på Gerd uten å stå i en sone');
select throws_ok($$ select public.granny_snitch('00000000-0000-0000-0000-0000000000a3', null, null) $$,
  'P0001', 'Du har allerede sladret', 'bare én sladring per granny');
select pg_temp.as_user('33333333-0000-0000-0000-000000000006');
select throws_ok($$ select public.granny_snitch('00000000-0000-0000-0000-0000000000a2', null, null) $$,
  'P0001', 'Rømlingen kan ikke sladre', 'Rømlingen kan ikke sladre');
select pg_temp.as_user('33333333-0000-0000-0000-000000000007');
select throws_ok($$ select public.granny_snitch('00000000-0000-0000-0000-0000000000a1', null, null) $$,
  'P0001', 'Vi vet ikke hvor hun er ennå', 'sladring på en granny uten posisjon brukes ikke opp');
select pg_temp.as_postgres();
select is(public.granny_live_reason('00000000-0000-0000-0000-0000000000a2', 1000), null, 'Gerd blir ikke live');
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select ok(public.team_map()->'markers' @> '[{"name": "Gerd", "snitched": true, "at_s": 1000}]', 'lagene ser Gerd der hun var da det ble sladret');
select ok(not jsonb_path_exists(public.team_map(), '$.markers[*] ? (@.kind == "anonym")'), 'ingen anonym markør i Kaffekroken');
select pg_temp.as_user('33333333-0000-0000-0000-000000000004');
select ok(public.my_events() @> '[{"kind": "snitch_target"}]', 'den det sladres på, får varsel');

-- Nabovakten: Gerd står 150 m fra punkt 1
select pg_temp.as_postgres();
select pg_temp.put('00000000-0000-0000-0000-0000000000a2', 58.3393, 8.5810, 1000);
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select throws_ok($$ select public.team_nabovakt((select id from public.zones where kind = 'nabovakt' and number = 1), 58.3300, 8.5700) $$,
  'P0001', 'Dere må stå ved punktet', 'innsjekk krever at laget står ved punktet');
select is((public.team_nabovakt((select id from public.zones where kind = 'nabovakt' and number = 1), 58.3380, 8.5810, 5))->>'hit',
  'true', 'Nabovakten finner Gerd innenfor 300 m');
select throws_ok($$ select public.team_nabovakt((select id from public.zones where kind = 'nabovakt' and number = 1), 58.3380, 8.5810, 5) $$,
  'P0001', 'Punktet er brukt', 'hvert punkt én gang i timen');
select is((public.team_nabovakt((select id from public.zones where kind = 'nabovakt' and number = 3), 58.3420, 8.6060, 5))->>'hit',
  'false', 'ingen grannies ved punkt 3');
select pg_temp.as_user('33333333-0000-0000-0000-000000000004');
select ok(public.my_events() @> '[{"kind": "nabovakt_seen", "title": "Nabovakten har sett deg ved punkt 1."}]', 'Gerd får beskjed om Nabovakten');

-- Rømlingen
select throws_ok($$ select public.team_romling_guess('Testrømling', 58.3345, 8.5760) $$, '42501', null, 'grannies kan ikke gjette');
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select throws_ok($$ select public.team_romling_guess('Testrømling', 58.3345, 8.5760) $$, 'P0001', 'Rømlingen er ikke annonsert', 'ingen gjetting før 0:45');
select pg_temp.as_postgres(); select pg_temp.at(3000);
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select throws_ok($$ select public.team_romling_guess('Testrømling', 58.3300, 8.5700) $$, 'P0001', 'Dere må stå ved Nattevaktens post', 'feltet er låst utenfor posten');
select is((public.team_romling_guess('Feil Navn', 58.3345, 8.5760, 5))->>'correct', 'false', 'feil navn');
select throws_ok($$ select public.team_romling_guess('Testrømling', 58.3345, 8.5760, 5) $$, 'P0001', 'Vent til neste forsøk', 'nytt forsøk først etter 20 min');
select pg_temp.as_user('33333333-0000-0000-0000-000000000002');
select is((public.team_romling_guess('  testRØMLING ', 58.3345, 8.5760, 5))->>'correct', 'true', 'riktig navn, uansett store bokstaver og mellomrom');
select pg_temp.as_postgres();
select is(pg_temp.points('00000000-0000-0000-0000-0000000000b2'), 3, 'riktig navn gir 3p');
select pg_temp.as_user('33333333-0000-0000-0000-000000000006');
select ok(public.my_events() @> '[{"kind": "license"}]', 'Rømlingen får varsel om lisens');

-- Bilder: Bingo
select pg_temp.as_postgres();
select pg_temp.file('bingo-astrid.jpg'); select pg_temp.file('bingo-gerd.jpg');
select pg_temp.file('album-1.jpg'); select pg_temp.file('album-2.jpg'); select pg_temp.file('kort-bla.jpg'); select pg_temp.file('kort-rod.jpg');
select pg_temp.as_user('33333333-0000-0000-0000-000000000003');
select throws_ok($$ select public.submit_photo('bingo', '00000000-0000-0000-0000-000000000001/bingo-astrid.jpg', 58.3300, 8.5700) $$,
  'P0001', 'Du må stå i Bingo-sonen', 'Bingo krever sonen');
select lives_ok($$ select public.submit_photo('bingo', '00000000-0000-0000-0000-000000000001/bingo-astrid.jpg', 58.3372, 8.5880, 5) $$, 'Astrid tar Bingo');
select pg_temp.as_user('33333333-0000-0000-0000-000000000004');
select public.submit_photo('bingo', '00000000-0000-0000-0000-000000000001/bingo-gerd.jpg', 58.3372, 8.5880, 5);
select pg_temp.as_postgres();
select is((select array_agg(delta order by id) from public.points_ledger where reason = 'bingo'), '{2,3}'::int[], 'Bingo gir 2p, deretter 3p');
select is(public.granny_live_reason('00000000-0000-0000-0000-0000000000a1', 3000), 'bingo', 'Bingo gjør grannyen synlig');

-- Fotoalbumet
select pg_temp.as_user('33333333-0000-0000-0000-000000000003');
select lives_ok($$ select public.submit_photo('fotoalbum', '00000000-0000-0000-0000-000000000001/album-1.jpg', null, null, null, '00000000-0000-0000-0000-0000000000b1') $$,
  'Astrid sender bilde av Lag Blå');
select throws_ok($$ select public.submit_photo('fotoalbum', '00000000-0000-0000-0000-000000000001/album-2.jpg') $$,
  'P0001', 'Fotoalbumet er sperret', 'én gang i timen');
select pg_temp.as_user('33333333-0000-0000-0000-000000000005');
select public.admin_review_photo((select id from public.photos where storage_path like '%album-1.jpg'), true);
select pg_temp.as_postgres();
select is(pg_temp.points('00000000-0000-0000-0000-0000000000b1'), -2, 'laget i Fotoalbumet får -2p');
select is(pg_temp.gpoints('00000000-0000-0000-0000-0000000000a1'), 4, 'fotografen får 2p (pluss 2p fra Bingo)');
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select is((public.team_map()->>'blind_until_s')::int, 3600, 'laget er blindt i 10 min');
select ok(not public.can_view_photo('00000000-0000-0000-0000-000000000001/album-1.jpg'), 'laget ser ikke bildet mens det er blindt');
-- Gerd tar taxi mens Lag Blå er blinde.
select pg_temp.as_user('33333333-0000-0000-0000-000000000004'); select public.granny_request_taxi();
select pg_temp.as_user('33333333-0000-0000-0000-000000000008'); select public.taxi_accept_next(); select public.taxi_pickup(58.3405, 8.5934, 5);
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select is(jsonb_array_length(jsonb_path_query_array(public.my_events(), '$[*] ? (@.kind == "taxi" && @.at_s == 3000)')), 0, 'blinde lag får ikke taxivarsel');
select pg_temp.as_user('33333333-0000-0000-0000-000000000002');
select is(jsonb_array_length(jsonb_path_query_array(public.my_events(), '$[*] ? (@.kind == "taxi" && @.at_s == 3000)')), 1, 'andre lag får det');

-- Et nytt bilde av samme lag kan ikke godkjennes før 15 min etter blindheten.
select pg_temp.as_user('33333333-0000-0000-0000-000000000004');
select public.submit_photo('fotoalbum', '00000000-0000-0000-0000-000000000001/album-2.jpg', null, null, null, '00000000-0000-0000-0000-0000000000b1');
select pg_temp.as_user('33333333-0000-0000-0000-000000000005');
select throws_ok($$ select public.admin_review_photo((select id from public.photos where storage_path like '%album-2.jpg'), true) $$,
  'P0001', 'Laget kan ikke blindes ennå', 'ingen ny blindhet før 15 min etter forrige');

-- 1:21:40 – blindheten er over, Postkort 2 er åpent
select pg_temp.as_postgres(); select pg_temp.at(4900);
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select ok(public.can_view_photo('00000000-0000-0000-0000-000000000001/album-1.jpg'), 'laget ser bildet når blindheten er over');
select lives_ok($$ select public.submit_photo('postkort', '00000000-0000-0000-0000-000000000001/kort-bla.jpg', 58.3395, 8.5990, 5) $$, 'Lag Blå sender postkort');
select pg_temp.as_user('33333333-0000-0000-0000-000000000002');
select public.submit_photo('postkort', '00000000-0000-0000-0000-000000000001/kort-rod.jpg', 58.3500, 8.6100, 5);
select ok(not public.can_view_photo('00000000-0000-0000-0000-000000000001/kort-bla.jpg'), 'lag ser ikke andre lags postkort');
select pg_temp.as_user('33333333-0000-0000-0000-000000000005');
select ok((select (x->>'distance_m')::real < 5 from jsonb_array_elements(public.admin_photos()) x where x->>'team_name' = 'Lag Blå'),
  'spilleder ser avstanden til den skjulte sonen');
select public.admin_review_photo((select id from public.photos where storage_path like '%kort-bla.jpg'), true);
select throws_ok($$ select public.admin_review_photo((select id from public.photos where storage_path like '%kort-rod.jpg'), true) $$,
  'P0001', 'Postkortet er allerede tatt', 'bare første lag får postkortet');

-- Klokka: ping og 0:45-varselet lages én gang
select pg_temp.as_postgres();
select public.tick_games(); select public.tick_games();
select is((select count(*)::int from public.events where kind = 'ping' and at_s = 4800), 0, 'gamle ping varsles ikke i etterkant');
select is((select count(*)::int from public.events where kind = 'postkort_open'), 1, 'åpent postkort varsles én gang');

-- Slutt
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select throws_ok($$ select public.game_summary() $$, 'P0001', 'Oppsummeringen kommer når spillet er over', 'ingen oppsummering for lag før slutt');
select pg_temp.as_postgres();
insert into public.taxi_rides (game_id, granny_id, at_s)
select '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a3', x from unnest('{1000,3000,5000}'::int[]) x;
select pg_temp.at(9100); select public.tick_games();
select is((select status::text from public.games where id = '00000000-0000-0000-0000-000000000001'), 'ended', 'spillet slutter av seg selv 2:30');
select is((select count(*)::int from public.points_ledger where reason = 'honnorrabatt'), 0, 'ingen honnørrabatt ved slutt');
select pg_temp.as_user('33333333-0000-0000-0000-000000000001');
select ok(public.game_summary()->'snitches' @> '[{"snitch": "Astrid", "target": "Gerd"}]', 'oppsummeringen avslører sladrehanken');

select * from finish();
rollback;
