-- Where is granny? – grunnskjema
--
-- Prinsipper:
-- * Spilltid (game_s) er sekunder siden start, minus pauser. Alle regler med
--   varighet (blind, taxi, nedkjøling) lagres i spilltid, så pause fryser dem.
-- * Klienten skriver aldri direkte til tabellene. Alle handlinger går via
--   security definer-funksjoner som sjekker rolle, sone og tid.
-- * Hemmelige ting (posisjoner, Rømlingens navn, sladrehank, fotograf,
--   postkortsoner) er bare lesbare for spilleder. Lag og grannies får det de
--   har lov til å se via RPC-er.

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Typer
-- ---------------------------------------------------------------------------
create type public.game_status as enum ('setup', 'running', 'paused', 'ended');
create type public.player_role as enum ('granny', 'team', 'admin');
create type public.zone_kind as enum ('area', 'kaffekroken', 'bingo', 'nattevakt', 'nabovakt', 'postkort');
create type public.position_source as enum ('telegram', 'app');
create type public.catch_status as enum ('pending', 'confirmed', 'rejected', 'overridden', 'void');
create type public.photo_kind as enum ('fotoalbum', 'bingo', 'postkort');
create type public.review_status as enum ('pending', 'approved', 'rejected', 'auto');
create type public.team_color as enum ('rod', 'oransje', 'gul', 'lime', 'gronn', 'turkis', 'bla', 'marine', 'rosa', 'brun');

-- ---------------------------------------------------------------------------
-- Spill
-- ---------------------------------------------------------------------------
create or replace function public.int_array_is_sorted(a int[]) returns boolean
language sql immutable
set search_path = ''
as $$ select a = (select array_agg(x order by x) from unnest(a) x) $$;

create table public.games (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  status           public.game_status not null default 'setup',
  started_at       timestamptz,
  paused_at        timestamptz,
  ended_at         timestamptz,
  paused_total     interval not null default interval '0',
  duration_s       int not null default 9000,     -- 2:30
  head_start_s     int not null default 900,      -- 0:15
  romling_reveal_s int not null default 2700,     -- 0:45
  ping_schedule_s  int[] not null default '{900,1800,2700,3600,4500,5100,5700,6300,6900,7200,7500,7800,8100,8400,8700,9000}',
  rules            jsonb not null default '{
    "snitch_live_s": 60,
    "snitch_bonus_window_s": 600,
    "blind_s": 600,
    "reblind_cooldown_s": 900,
    "taxi_cooldown_s": 1800,
    "honnor_min_free_s": 4500,
    "honnor_max_rides": 2,
    "romling_retry_s": 1200,
    "nabovakt_search_m": 300,
    "nabovakt_cooldown_s": 3600,
    "out_of_area_grace_s": 60,
    "catch_confirm_timeout_s": 120,
    "telegram_stale_reminder_s": 60,
    "telegram_stale_admin_s": 180,
    "retention_days": 30
  }'::jsonb,
  created_at       timestamptz not null default now(),
  constraint ping_schedule_sorted check (public.int_array_is_sorted(ping_schedule_s))
);

create table public.teams (
  id                 uuid primary key default gen_random_uuid(),
  game_id            uuid not null references public.games on delete cascade,
  name               text not null,
  color              public.team_color not null,
  assigned_granny_id uuid,
  license_at_s       int,                 -- når laget knakk Rømlingen
  created_at         timestamptz not null default now(),
  unique (game_id, color)
);

create table public.grannies (
  id            uuid primary key default gen_random_uuid(),
  game_id       uuid not null references public.games on delete cascade,
  name          text not null,
  is_romling    boolean not null default false,
  caught_at_s   int,
  caught_by     uuid references public.teams on delete set null,
  catch_order   int,
  created_at    timestamptz not null default now()
);
create unique index one_romling_per_game on public.grannies (game_id) where is_romling;

alter table public.teams
  add constraint teams_assigned_granny_fk foreign key (assigned_granny_id) references public.grannies on delete set null;

-- Kobling mellom granny og Telegram. Bare spilleder og serveren ser denne.
create table public.granny_telegram (
  granny_id        uuid primary key references public.grannies on delete cascade,
  link_token       text not null unique default encode(extensions.gen_random_bytes(12), 'hex'),
  telegram_user_id bigint unique,
  chat_id          bigint,
  linked_at        timestamptz,
  last_live_period int
);

-- Innloggingskoder. Én per lag, én per granny, én for spilleder.
create table public.join_codes (
  code      text primary key check (code = upper(code)),
  game_id   uuid not null references public.games on delete cascade,
  role      public.player_role not null,
  team_id   uuid references public.teams on delete cascade,
  granny_id uuid references public.grannies on delete cascade,
  check (
    (role = 'team'   and team_id is not null and granny_id is null) or
    (role = 'granny' and granny_id is not null and team_id is null) or
    (role = 'admin'  and team_id is null and granny_id is null)
  )
);

-- En innlogget telefon. Flere telefoner kan dele samme lag.
create table public.players (
  user_id   uuid primary key references auth.users on delete cascade,
  game_id   uuid not null references public.games on delete cascade,
  role      public.player_role not null,
  team_id   uuid references public.teams on delete cascade,
  granny_id uuid references public.grannies on delete cascade,
  joined_at timestamptz not null default now()
);
create index players_game on public.players (game_id);

-- Soner. Spillområdet er et polygon; resten er punkt + radius.
create table public.zones (
  id          uuid primary key default gen_random_uuid(),
  game_id     uuid not null references public.games on delete cascade,
  kind        public.zone_kind not null,
  number      int,                  -- Nabovakt-punkt nr. / Postkort nr.
  label       text not null,
  geom        extensions.geography not null,
  radius_m    int,
  opens_at_s  int,                  -- postkort
  closes_at_s int,
  mission     text,                 -- postkort-oppdrag
  check (kind = 'area' or radius_m is not null)
);
create index zones_game on public.zones (game_id, kind);
create unique index one_area_per_game on public.zones (game_id) where kind = 'area';

-- ---------------------------------------------------------------------------
-- Hendelser i spillet
-- ---------------------------------------------------------------------------
create table public.positions (
  id          bigint generated always as identity primary key,
  game_id     uuid not null references public.games on delete cascade,
  granny_id   uuid references public.grannies on delete cascade,
  team_id     uuid references public.teams on delete cascade,
  user_id     uuid references auth.users on delete set null,
  source      public.position_source not null,
  geom        extensions.geography(Point, 4326) not null,
  accuracy_m  real,
  live_period int,
  recorded_at timestamptz not null default now(),
  game_s      int not null,
  check ((granny_id is null) <> (team_id is null))
);
create index positions_granny_time on public.positions (granny_id, game_s desc, id desc) where granny_id is not null;
create index positions_team_time on public.positions (team_id, game_s desc) where team_id is not null;

create table public.catches (
  id            uuid primary key default gen_random_uuid(),
  game_id       uuid not null references public.games on delete cascade,
  granny_id     uuid not null references public.grannies on delete cascade,
  team_id       uuid not null references public.teams on delete cascade,
  registered_by uuid references auth.users on delete set null,
  registered_at timestamptz not null default now(),
  registered_s  int not null,
  status        public.catch_status not null default 'pending',
  resolved_at   timestamptz,
  resolved_by   text check (resolved_by in ('granny', 'admin', 'timeout'))
);
create index catches_granny on public.catches (granny_id, status);

create table public.snitches (
  id               uuid primary key default gen_random_uuid(),
  game_id          uuid not null references public.games on delete cascade,
  snitch_granny_id uuid not null references public.grannies on delete cascade,
  target_granny_id uuid not null references public.grannies on delete cascade,
  at_s             int not null,
  live_until_s     int not null,
  bonus_awarded    boolean not null default false,
  check (snitch_granny_id <> target_granny_id)
);
create unique index one_snitch_per_granny on public.snitches (snitch_granny_id);

create table public.photos (
  id             uuid primary key default gen_random_uuid(),
  game_id        uuid not null references public.games on delete cascade,
  kind           public.photo_kind not null,
  granny_id      uuid references public.grannies on delete cascade,   -- fotograf (fotoalbum, bingo)
  team_id        uuid references public.teams on delete cascade,      -- postkort
  target_team_id uuid references public.teams on delete set null,     -- fotoalbum
  zone_id        uuid references public.zones on delete set null,
  storage_path   text not null,
  geom           extensions.geography(Point, 4326),
  submitted_at   timestamptz not null default now(),
  submitted_s    int not null,
  status         public.review_status not null default 'pending',
  reviewed_at    timestamptz
);

create table public.taxi_rides (
  id        uuid primary key default gen_random_uuid(),
  game_id   uuid not null references public.games on delete cascade,
  granny_id uuid not null references public.grannies on delete cascade,
  at_s      int not null
);

create table public.nabovakt_checkins (
  id      uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games on delete cascade,
  team_id uuid not null references public.teams on delete cascade,
  zone_id uuid not null references public.zones on delete cascade,
  at_s    int not null,
  hit     boolean not null
);

create table public.romling_attempts (
  id      uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games on delete cascade,
  team_id uuid not null references public.teams on delete cascade,
  at_s    int not null,
  guess   text not null,
  correct boolean not null
);

create table public.blinds (
  id       uuid primary key default gen_random_uuid(),
  game_id  uuid not null references public.games on delete cascade,
  team_id  uuid not null references public.teams on delete cascade,
  photo_id uuid references public.photos on delete set null,
  from_s   int not null,
  until_s  int not null
);

-- Alle poeng som rader, så overstyring og oppsummering blir sporbar.
create table public.points_ledger (
  id         bigint generated always as identity primary key,
  game_id    uuid not null references public.games on delete cascade,
  team_id    uuid references public.teams on delete cascade,
  granny_id  uuid references public.grannies on delete cascade,
  delta      int not null,
  reason     text not null,
  ref_id     uuid,
  at_s       int not null,
  created_by text not null default 'system',
  check ((team_id is null) <> (granny_id is null))
);

-- ---------------------------------------------------------------------------
-- Spillklokke
-- ---------------------------------------------------------------------------
create or replace function public.game_seconds(g public.games, at timestamptz default now())
returns int
language sql stable
set search_path = ''
as $$
  select case
    when g.started_at is null then 0
    else greatest(0, least(g.duration_s,
      floor(extract(epoch from (coalesce(g.ended_at, g.paused_at, at) - g.started_at - g.paused_total)))::int))
  end
$$;

create or replace function public.last_ping_s(g public.games, s int)
returns int
language sql immutable
set search_path = ''
as $$
  select max(p) from unnest(g.ping_schedule_s) p where p <= s
$$;

create or replace function public.next_ping_s(g public.games, s int)
returns int
language sql immutable
set search_path = ''
as $$
  select min(p) from unnest(g.ping_schedule_s) p where p > s
$$;

-- Fyll game_s automatisk når den ikke er satt.
create or replace function public.tg_fill_game_s()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  g public.games;
begin
  if new.game_s is null then
    select * into g from public.games where id = new.game_id;
    new.game_s := public.game_seconds(g, new.recorded_at);
  end if;
  return new;
end
$$;
create trigger positions_game_s before insert on public.positions
  for each row execute function public.tg_fill_game_s();

-- ---------------------------------------------------------------------------
-- Hvem er jeg?
-- ---------------------------------------------------------------------------
create or replace function public.me()
returns public.players
language sql stable security definer
set search_path = ''
as $$
  select * from public.players where user_id = (select auth.uid())
$$;

create or replace function public.my_game_id() returns uuid
language sql stable security definer set search_path = ''
as $$ select game_id from public.players where user_id = (select auth.uid()) $$;

create or replace function public.my_role() returns public.player_role
language sql stable security definer set search_path = ''
as $$ select role from public.players where user_id = (select auth.uid()) $$;

create or replace function public.my_team_id() returns uuid
language sql stable security definer set search_path = ''
as $$ select team_id from public.players where user_id = (select auth.uid()) $$;

create or replace function public.my_granny_id() returns uuid
language sql stable security definer set search_path = ''
as $$ select granny_id from public.players where user_id = (select auth.uid()) $$;

create or replace function public.is_admin_of(gid uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.players
                 where user_id = (select auth.uid()) and game_id = gid and role = 'admin')
$$;

create or replace function public.i_am_romling() returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select g.is_romling from public.players p join public.grannies g on g.id = p.granny_id
                   where p.user_id = (select auth.uid())), false)
$$;

create or replace function public.team_has_license(tid uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((select license_at_s is not null from public.teams where id = tid), false) $$;

-- ---------------------------------------------------------------------------
-- Synlighet for soner
-- ---------------------------------------------------------------------------
create or replace function public.zone_visible(z public.zones) returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
  g public.games;
  is_rom boolean;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.game_id <> z.game_id then return false; end if;
  if p.role = 'admin' then return true; end if;
  if z.kind = 'postkort' then return false; end if;     -- alltid skjult
  if z.kind in ('area', 'nabovakt') then return true; end if;

  if p.role = 'granny' then
    select is_romling into is_rom from public.grannies where id = p.granny_id;
    if is_rom then
      return z.kind = 'nattevakt';                       -- Rømlingen vet hvor posten er
    end if;
    return z.kind in ('kaffekroken', 'bingo');
  end if;

  -- lag
  if z.kind = 'nattevakt' then
    select * into g from public.games where id = z.game_id;
    return public.game_seconds(g) >= g.romling_reveal_s;
  end if;
  return false;
end
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.games             enable row level security;
alter table public.teams             enable row level security;
alter table public.grannies          enable row level security;
alter table public.granny_telegram   enable row level security;
alter table public.join_codes        enable row level security;
alter table public.players           enable row level security;
alter table public.zones             enable row level security;
alter table public.positions         enable row level security;
alter table public.catches           enable row level security;
alter table public.snitches          enable row level security;
alter table public.photos            enable row level security;
alter table public.taxi_rides        enable row level security;
alter table public.nabovakt_checkins enable row level security;
alter table public.romling_attempts  enable row level security;
alter table public.blinds            enable row level security;
alter table public.points_ledger     enable row level security;

-- Ingen skrivetilgang for klienter. Alt skrives via RPC-er under.
create policy games_read on public.games for select to authenticated
  using (id = (select public.my_game_id()));

create policy teams_read on public.teams for select to authenticated
  using (game_id = (select public.my_game_id()));

create policy grannies_read on public.grannies for select to authenticated
  using (
    game_id = (select public.my_game_id()) and (
      not is_romling
      or (select public.my_role()) = 'admin'
      or id = (select public.my_granny_id())
      or ((select public.my_role()) = 'team' and public.team_has_license((select public.my_team_id())))
    )
    -- Rømlingen ser bare seg selv
    and (not (select public.i_am_romling()) or id = (select public.my_granny_id()))
  );

create policy players_read_self on public.players for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin_of(game_id));

create policy join_codes_admin on public.join_codes for select to authenticated
  using (public.is_admin_of(game_id));

create policy granny_telegram_admin on public.granny_telegram for select to authenticated
  using (exists (select 1 from public.grannies g where g.id = granny_id and public.is_admin_of(g.game_id)));

create policy zones_read on public.zones for select to authenticated
  using (public.zone_visible(zones));

create policy positions_admin on public.positions for select to authenticated
  using (public.is_admin_of(game_id));

create policy catches_read on public.catches for select to authenticated
  using (public.is_admin_of(game_id)
         or team_id = (select public.my_team_id())
         or granny_id = (select public.my_granny_id()));

create policy snitches_read on public.snitches for select to authenticated
  using (public.is_admin_of(game_id) or snitch_granny_id = (select public.my_granny_id()));

create policy photos_read on public.photos for select to authenticated
  using (public.is_admin_of(game_id)
         or granny_id = (select public.my_granny_id())
         or team_id = (select public.my_team_id()));

create policy taxi_read on public.taxi_rides for select to authenticated
  using (public.is_admin_of(game_id) or granny_id = (select public.my_granny_id()));

create policy nabovakt_read on public.nabovakt_checkins for select to authenticated
  using (public.is_admin_of(game_id) or team_id = (select public.my_team_id()));

create policy romling_attempts_read on public.romling_attempts for select to authenticated
  using (public.is_admin_of(game_id) or team_id = (select public.my_team_id()));

create policy blinds_read on public.blinds for select to authenticated
  using (public.is_admin_of(game_id) or team_id = (select public.my_team_id()));

create policy ledger_admin on public.points_ledger for select to authenticated
  using (public.is_admin_of(game_id));

-- Soner som GeoJSON for kartet. security_invoker gjør at RLS på zones gjelder.
create view public.zones_geo with (security_invoker = true) as
  select id, game_id, kind, number, label, radius_m, opens_at_s, closes_at_s,
         extensions.st_asgeojson(geom)::jsonb as geojson
  from public.zones;
grant select on public.zones_geo to authenticated;

-- ---------------------------------------------------------------------------
-- RPC: bli med
-- ---------------------------------------------------------------------------
create or replace function public.join_game(p_code text)
returns public.players
language plpgsql security definer
set search_path = ''
as $$
declare
  c public.join_codes;
  result public.players;
begin
  if (select auth.uid()) is null then
    raise exception 'Ikke innlogget' using errcode = '28000';
  end if;

  select * into c from public.join_codes where code = upper(trim(p_code));
  if c is null then
    raise exception 'Ukjent kode' using errcode = 'P0002';
  end if;

  insert into public.players (user_id, game_id, role, team_id, granny_id)
  values ((select auth.uid()), c.game_id, c.role, c.team_id, c.granny_id)
  on conflict (user_id) do update
    set game_id = excluded.game_id, role = excluded.role,
        team_id = excluded.team_id, granny_id = excluded.granny_id, joined_at = now()
  returning * into result;

  return result;
end
$$;

-- ---------------------------------------------------------------------------
-- RPC: spilltilstand (klokke, rolle, blind)
-- ---------------------------------------------------------------------------
create or replace function public.game_state()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
  g public.games;
  s int;
  blind_until int;
  t public.teams;
  gr public.grannies;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null then return null; end if;
  select * into g from public.games where id = p.game_id;
  s := public.game_seconds(g);

  if p.team_id is not null then
    select * into t from public.teams where id = p.team_id;
    select max(until_s) into blind_until from public.blinds where team_id = p.team_id and from_s <= s and until_s > s;
  end if;
  if p.granny_id is not null then
    select * into gr from public.grannies where id = p.granny_id;
  end if;

  return jsonb_build_object(
    'server_time', now(),
    'game_id', g.id,
    'game_name', g.name,
    'status', g.status,
    'game_s', s,
    'duration_s', g.duration_s,
    'head_start_s', g.head_start_s,
    'romling_reveal_s', g.romling_reveal_s,
    'ping_schedule_s', to_jsonb(g.ping_schedule_s),
    'last_ping_s', public.last_ping_s(g, s),
    'next_ping_s', public.next_ping_s(g, s),
    'role', p.role,
    'team', case when t.id is null then null else jsonb_build_object(
      'id', t.id, 'name', t.name, 'color', t.color,
      'assigned_granny_id', t.assigned_granny_id,
      'assigned_granny_name', (select name from public.grannies where id = t.assigned_granny_id),
      'has_license', t.license_at_s is not null,
      'blind_until_s', blind_until) end,
    'granny', case when gr.id is null then null else jsonb_build_object(
      'id', gr.id, 'name', gr.name, 'is_romling', gr.is_romling,
      'caught', gr.caught_at_s is not null, 'caught_at_s', gr.caught_at_s) end
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Posisjoner
-- ---------------------------------------------------------------------------

-- Fra appens egen GPS (lag og grannies, mens appen er åpen).
create or replace function public.report_position(p_lat double precision, p_lng double precision, p_accuracy real default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role = 'admin' then
    raise exception 'Bare spillere sender posisjon' using errcode = '42501';
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Ugyldig posisjon' using errcode = '22023';
  end if;

  insert into public.positions (game_id, granny_id, team_id, user_id, source, geom, accuracy_m)
  values (p.game_id, p.granny_id, p.team_id, p.user_id, 'app',
          extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
          p_accuracy);
end
$$;

-- Siste posisjon for en granny ved eller før et gitt tidspunkt i spilltid.
create or replace function public.granny_position_at(p_granny uuid, p_s int)
returns public.positions
language sql stable security definer
set search_path = ''
as $$
  select * from public.positions
  where granny_id = p_granny and game_s <= p_s
  order by game_s desc, id desc
  limit 1
$$;

-- Er grannyen live akkurat nå (sladret på, eller utenfor området for lenge)?
create or replace function public.granny_live_reason(p_granny uuid, p_s int)
returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
  g public.games;
  gr public.grannies;
  latest public.positions;
  area extensions.geography;
  last_inside int;
begin
  select * into gr from public.grannies where id = p_granny;
  select * into g from public.games where id = gr.game_id;

  if exists (select 1 from public.snitches where target_granny_id = p_granny and at_s <= p_s and live_until_s > p_s) then
    return 'sladret';
  end if;

  select geom into area from public.zones where game_id = g.id and kind = 'area';
  if area is null then return null; end if;

  latest := public.granny_position_at(p_granny, p_s);
  if latest is null or extensions.st_covers(area, latest.geom) then return null; end if;

  select max(game_s) into last_inside from public.positions
  where granny_id = p_granny and game_s <= p_s and extensions.st_covers(area, geom);

  if p_s - coalesce(last_inside, 0) >= (g.rules->>'out_of_area_grace_s')::int then
    return 'utenfor';
  end if;
  return null;
end
$$;

-- Kartet til et lag: posisjonene fra siste ping, pluss grannies som er live.
create or replace function public.team_map()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
  g public.games;
  t public.teams;
  s int;
  ping int;
  blind_until int;
  markers jsonb := '[]'::jsonb;
  gr public.grannies;
  pos public.positions;
  live text;
  show_s int;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'team' then
    raise exception 'Bare for lag' using errcode = '42501';
  end if;
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id;
  s := public.game_seconds(g);
  ping := public.last_ping_s(g, s);

  select max(until_s) into blind_until from public.blinds where team_id = t.id and from_s <= s and until_s > s;
  if blind_until is not null then
    return jsonb_build_object('game_s', s, 'ping_s', ping, 'blind_until_s', blind_until, 'markers', '[]'::jsonb);
  end if;

  for gr in select * from public.grannies where game_id = g.id order by name loop
    -- Fanget før dette tidspunktet: vises ikke.
    continue when gr.caught_at_s is not null and gr.caught_at_s <= s;
    -- Rømlingen finnes ikke for lagene før 0:45.
    continue when gr.is_romling and s < g.romling_reveal_s;

    live := case when gr.is_romling then null else public.granny_live_reason(gr.id, s) end;
    if live is not null then
      show_s := s;
    elsif ping is not null and (not gr.is_romling or ping >= g.romling_reveal_s) then
      show_s := ping;
    else
      continue;
    end if;

    pos := public.granny_position_at(gr.id, show_s);
    continue when pos is null;

    markers := markers || jsonb_build_object(
      'kind', case
        when gr.is_romling and not public.team_has_license(t.id) then 'romling'
        when gr.id = t.assigned_granny_id then 'own_granny'
        when live is not null then 'live'
        else 'granny' end,
      'id',   case when gr.is_romling and not public.team_has_license(t.id) then null else gr.id end,
      'name', case when gr.is_romling and not public.team_has_license(t.id) then null else gr.name end,
      'live_reason', live,
      'lat', extensions.st_y(pos.geom::extensions.geometry),
      'lng', extensions.st_x(pos.geom::extensions.geometry),
      'accuracy_m', pos.accuracy_m,
      'at_s', show_s,
      'age_s', show_s - pos.game_s
    );
  end loop;

  return jsonb_build_object('game_s', s, 'ping_s', ping, 'blind_until_s', null, 'markers', markers);
end
$$;

-- Spillederens live-oversikt: alle grannies med siste posisjon og alder.
create or replace function public.admin_live()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
  g public.games;
  s int;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'admin' then
    raise exception 'Bare for spilleder' using errcode = '42501';
  end if;
  select * into g from public.games where id = p.game_id;
  s := public.game_seconds(g);

  return jsonb_build_object(
    'game_s', s,
    'grannies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', gr.id, 'name', gr.name, 'is_romling', gr.is_romling,
        'caught_at_s', gr.caught_at_s,
        'telegram_linked', gt.telegram_user_id is not null,
        'lat', extensions.st_y(lp.geom::extensions.geometry),
        'lng', extensions.st_x(lp.geom::extensions.geometry),
        'source', lp.source,
        'age_s', extract(epoch from now() - lp.recorded_at)::int,
        'live_reason', public.granny_live_reason(gr.id, s)
      ) order by gr.name)
      from public.grannies gr
      left join public.granny_telegram gt on gt.granny_id = gr.id
      left join lateral (
        select * from public.positions where granny_id = gr.id order by recorded_at desc, id desc limit 1
      ) lp on true
      where gr.game_id = g.id
    ), '[]'::jsonb),
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'color', t.color,
        'phones', (select count(*) from public.players pl where pl.team_id = t.id),
        'lat', extensions.st_y(lp.geom::extensions.geometry),
        'lng', extensions.st_x(lp.geom::extensions.geometry),
        'age_s', extract(epoch from now() - lp.recorded_at)::int
      ) order by t.name)
      from public.teams t
      left join lateral (
        select * from public.positions where team_id = t.id order by recorded_at desc, id desc limit 1
      ) lp on true
      where t.game_id = g.id
    ), '[]'::jsonb)
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Telegram
-- ---------------------------------------------------------------------------

-- Grannyens egen lenke til boten (F2b) og status.
create or replace function public.my_telegram()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  gid uuid := public.my_granny_id();
  gt public.granny_telegram;
  last_at timestamptz;
begin
  if gid is null then
    raise exception 'Bare for grannies' using errcode = '42501';
  end if;
  insert into public.granny_telegram (granny_id) values (gid) on conflict do nothing;
  select * into gt from public.granny_telegram where granny_id = gid;
  select max(recorded_at) into last_at from public.positions where granny_id = gid and source = 'telegram';
  return jsonb_build_object(
    'link_token', gt.link_token,
    'linked', gt.telegram_user_id is not null,
    'last_position_age_s', case when last_at is null then null else extract(epoch from now() - last_at)::int end
  );
end
$$;

-- Kalles av webhooken (service_role) når noen trykker /start <token>.
create or replace function public.telegram_link(p_token text, p_user_id bigint, p_chat_id bigint)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  gt public.granny_telegram;
  gname text;
begin
  -- Samme Telegram-konto kan bare være én granny.
  update public.granny_telegram set telegram_user_id = null, chat_id = null
  where telegram_user_id = p_user_id and link_token <> p_token;

  update public.granny_telegram
     set telegram_user_id = p_user_id, chat_id = p_chat_id, linked_at = now()
   where link_token = p_token
  returning * into gt;

  if gt is null then return jsonb_build_object('ok', false); end if;
  select name into gname from public.grannies where id = gt.granny_id;
  return jsonb_build_object('ok', true, 'granny_name', gname);
end
$$;

-- Kalles av webhooken for hver posisjon (message og edited_message).
create or replace function public.telegram_ingest_location(
  p_user_id bigint, p_lat double precision, p_lng double precision,
  p_accuracy real default null, p_live_period int default null, p_at timestamptz default now())
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  gt public.granny_telegram;
  gr public.grannies;
begin
  select * into gt from public.granny_telegram where telegram_user_id = p_user_id;
  if gt is null then return jsonb_build_object('ok', false, 'reason', 'not_linked'); end if;
  select * into gr from public.grannies where id = gt.granny_id;

  -- Telegram kan levere forsinket (f.eks. etter et webhook-avbrudd). Bruk
  -- tidspunktet fra meldingen, men aldri et tidspunkt i fremtiden.
  insert into public.positions (game_id, granny_id, source, geom, accuracy_m, live_period, recorded_at)
  values (gr.game_id, gr.id, 'telegram',
          extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
          p_accuracy, p_live_period, least(p_at, now()));

  if p_live_period is not null then
    update public.granny_telegram set last_live_period = p_live_period where granny_id = gr.id;
  end if;
  return jsonb_build_object('ok', true, 'is_live', p_live_period is not null);
end
$$;

-- ---------------------------------------------------------------------------
-- Spilleder: start, pause, fortsett, avslutt
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_status(p_action text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players;
  g public.games;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'admin' then
    raise exception 'Bare for spilleder' using errcode = '42501';
  end if;
  select * into g from public.games where id = p.game_id for update;

  case p_action
    when 'start' then
      if g.status <> 'setup' then raise exception 'Spillet er allerede startet'; end if;
      update public.games set status = 'running', started_at = now() where id = g.id;
    when 'pause' then
      if g.status <> 'running' then raise exception 'Spillet går ikke'; end if;
      update public.games set status = 'paused', paused_at = now() where id = g.id;
    when 'resume' then
      if g.status <> 'paused' then raise exception 'Spillet er ikke pauset'; end if;
      update public.games set status = 'running', paused_total = paused_total + (now() - paused_at), paused_at = null where id = g.id;
    when 'end' then
      if g.status not in ('running', 'paused') then raise exception 'Spillet går ikke'; end if;
      update public.games set status = 'ended', ended_at = coalesce(paused_at, now()) where id = g.id;
    else
      raise exception 'Ukjent handling: %', p_action;
  end case;

  return public.game_state();
end
$$;

-- ---------------------------------------------------------------------------
-- Tilganger for funksjoner
-- ---------------------------------------------------------------------------
-- Supabase gir anon og authenticated tilgang til alt som standard. Vi strammer inn.
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.join_game(text),
  public.game_state(),
  public.report_position(double precision, double precision, real),
  public.team_map(),
  public.admin_live(),
  public.my_telegram(),
  public.admin_set_status(text)
to authenticated;

-- Hjelpere som RLS-policyene trenger.
grant execute on function
  public.me(), public.my_game_id(), public.my_role(), public.my_team_id(), public.my_granny_id(),
  public.i_am_romling(), public.is_admin_of(uuid), public.int_array_is_sorted(int[]), public.team_has_license(uuid), public.zone_visible(public.zones),
  public.game_seconds(public.games, timestamptz), public.last_ping_s(public.games, int), public.next_ping_s(public.games, int)
to authenticated;

-- Bare webhooken (service_role) kan koble Telegram og sende inn posisjon.
grant execute on function
  public.telegram_link(text, bigint, bigint),
  public.telegram_ingest_location(bigint, double precision, double precision, real, int, timestamptz)
to service_role;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
