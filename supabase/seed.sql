-- Lokale testdata. ALT HER ER FIKTIVT.
-- Ekte steder (Bingo, postkort) og Rømlingens navn legges inn av spilleder i
-- databasen før spillet, aldri i dette offentlige repoet.

insert into public.games (id, name) values
  ('00000000-0000-0000-0000-000000000001', 'Testjakt');

insert into public.grannies (id, game_id, name, is_romling) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000001', 'Astrid', false),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-000000000001', 'Gerd', false),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-000000000001', 'Solveig', false),
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-000000000001', 'Testrømling', true);

insert into public.teams (id, game_id, name, color, assigned_granny_id) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000001', 'Lag Blå',   'bla',   '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000001', 'Lag Rød',   'rod',   '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-000000000001', 'Lag Grønn', 'gronn', '00000000-0000-0000-0000-0000000000a3');

insert into public.join_codes (code, game_id, role, team_id, granny_id) values
  ('TEST-ADMIN',   '00000000-0000-0000-0000-000000000001', 'admin',  null, null),
  ('TEST-BLA',     '00000000-0000-0000-0000-000000000001', 'team',   '00000000-0000-0000-0000-0000000000b1', null),
  ('TEST-ROD',     '00000000-0000-0000-0000-000000000001', 'team',   '00000000-0000-0000-0000-0000000000b2', null),
  ('TEST-GRONN',   '00000000-0000-0000-0000-000000000001', 'team',   '00000000-0000-0000-0000-0000000000b3', null),
  ('TEST-ASTRID',  '00000000-0000-0000-0000-000000000001', 'granny', null, '00000000-0000-0000-0000-0000000000a1'),
  ('TEST-GERD',    '00000000-0000-0000-0000-000000000001', 'granny', null, '00000000-0000-0000-0000-0000000000a2'),
  ('TEST-SOLVEIG', '00000000-0000-0000-0000-000000000001', 'granny', null, '00000000-0000-0000-0000-0000000000a3'),
  ('TEST-ROMLING', '00000000-0000-0000-0000-000000000001', 'granny', null, '00000000-0000-0000-0000-0000000000a9');

insert into public.granny_telegram (granny_id, link_token)
select id, 'test-' || lower(name) from public.grannies
where game_id = '00000000-0000-0000-0000-000000000001' and not is_romling;
insert into public.granny_telegram (granny_id, link_token)
values ('00000000-0000-0000-0000-0000000000a9', 'test-romling');

-- Soner: tilfeldige testpunkter rundt Grimstad sentrum.
insert into public.zones (game_id, kind, number, label, geom, radius_m, opens_at_s, closes_at_s, mission) values
  ('00000000-0000-0000-0000-000000000001', 'area', null, 'Spillområdet (test)',
     'SRID=4326;POLYGON((8.565 58.330, 8.615 58.330, 8.615 58.352, 8.565 58.352, 8.565 58.330))', null, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'kaffekroken', null, 'Kaffekroken (test)', 'SRID=4326;POINT(8.5945 58.3410)', 40, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'bingo',       null, 'Bingo (test)',       'SRID=4326;POINT(8.5880 58.3372)', 30, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'nattevakt',   null, 'Nattevaktens post (test)', 'SRID=4326;POINT(8.5760 58.3345)', 40, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'nabovakt', 1, 'Nabovakt 1', 'SRID=4326;POINT(8.5810 58.3380)', 30, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'nabovakt', 2, 'Nabovakt 2', 'SRID=4326;POINT(8.5960 58.3460)', 30, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'nabovakt', 3, 'Nabovakt 3', 'SRID=4326;POINT(8.6060 58.3420)', 30, null, null, null),
  ('00000000-0000-0000-0000-000000000001', 'postkort', 1, 'Postkort 1 (test)', 'SRID=4326;POINT(8.5900 58.3440)', 40, 1800, 3000, 'Testoppdrag 1: hele laget i ett hopp.'),
  ('00000000-0000-0000-0000-000000000001', 'postkort', 2, 'Postkort 2 (test)', 'SRID=4326;POINT(8.5990 58.3395)', 40, 4800, 6000, 'Testoppdrag 2: lag en bokstav med kroppene.'),
  ('00000000-0000-0000-0000-000000000001', 'postkort', 3, 'Postkort 3 (test)', 'SRID=4326;POINT(8.5840 58.3415)', 40, 7500, 8700, 'Testoppdrag 3: gruppebilde.');
