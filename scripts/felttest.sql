-- Lager et felttest-spill med 6 testgrannies, ett lag og en spillederkode.
-- Kjør i Supabase SQL Editor (eller psql) mot produksjonsdatabasen.
-- Kodene som skrives ut deles med testerne. De legges ikke i repoet.
--
-- Spillet står i «setup», så klokka går ikke. Det trengs ikke for å måle
-- Telegram: måletabellen hos spilleder bruker tidspunktene fra Telegram.

with game as (
  insert into public.games (name) values ('Felttest ' || to_char(now() at time zone 'Europe/Oslo', 'YYYY-MM-DD HH24:MI'))
  returning id
),
grannies as (
  insert into public.grannies (game_id, name)
  select game.id, 'Tester ' || n from game, generate_series(1, 6) n
  returning id, game_id, name
),
team as (
  insert into public.teams (game_id, name, color)
  select id, 'Testlag', 'bla'::public.team_color from game
  returning id, game_id
),
codes as (
  insert into public.join_codes (code, game_id, role, team_id, granny_id)
  select 'FT-' || upper(encode(extensions.gen_random_bytes(3), 'hex')), game_id, 'granny'::public.player_role, null, id from grannies
  union all
  select 'FT-' || upper(encode(extensions.gen_random_bytes(3), 'hex')), game_id, 'team'::public.player_role, id, null from team
  union all
  select 'FT-ADMIN-' || upper(encode(extensions.gen_random_bytes(4), 'hex')), id, 'admin'::public.player_role, null, null from game
  returning code, role, granny_id
)
select c.role, coalesce(g.name, case c.role when 'team' then 'Testlag' else 'Spilleder' end) as hvem, c.code
from codes c left join grannies g on g.id = c.granny_id
order by c.role, hvem;

-- Etter testen: slett spillet og alle posisjoner (cascade).
-- delete from public.games where name like 'Felttest %';
