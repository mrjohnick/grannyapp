-- Resten av spillet: varsler, taxi, nabovakt, Rømling-lisens, sladrehank,
-- bilder (Fotoalbum, Bingo, Postkort), spilleders oppsett, oppsummering
-- og sletting etter 30 dager.
--
-- Varsler: Alt som skal ut til spillerne, skrives som rader i public.events.
-- Appen henter dem jevnlig (my_events), og game-worker sender dem som Web
-- Push. Tidsstyrte varsler (ping, postkort, 0:45, blindhet over) lages av
-- tick_games(), som pg_cron kjører hvert 15. sekund (se neste migrasjon).

-- ---------------------------------------------------------------------------
-- Tabeller
-- ---------------------------------------------------------------------------
create table public.events (
  id         bigint generated always as identity primary key,
  game_id    uuid not null references public.games on delete cascade,
  at_s       int not null,
  created_at timestamptz not null default now(),
  audience   text not null check (audience in ('all', 'teams', 'grannies', 'team', 'granny', 'admin')),
  team_id    uuid references public.teams on delete cascade,
  granny_id  uuid references public.grannies on delete cascade,
  kind       text not null,
  title      text not null,
  body       text,
  data       jsonb,
  dedupe_key text,
  pushed_at  timestamptz,
  check (audience <> 'team' or team_id is not null),
  check (audience <> 'granny' or granny_id is not null)
);
create index events_game on public.events (game_id, id);
create index events_unpushed on public.events (created_at) where pushed_at is null;
create unique index events_dedupe on public.events (game_id, dedupe_key) where dedupe_key is not null;

create table public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references auth.users on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index push_subscriptions_user on public.push_subscriptions (user_id);

-- Innstillinger for serveren (f.eks. adressen til game-worker). Ikke hemmelig,
-- men heller ikke lesbar for klienter.
create table public.app_settings (
  key   text primary key,
  value text not null
);

-- Spill som er slettet, så game-worker kan rydde bildene i Storage.
create table public.purged_games (
  game_id            uuid primary key,
  purged_at          timestamptz not null default now(),
  storage_cleaned_at timestamptz
);

alter table public.photos add column distance_m real;   -- postkort: avstand til den skjulte sonen
alter table public.photos add column note text;          -- spilleders kommentar ved avvisning

create index photos_game_kind on public.photos (game_id, kind, status);
create index taxi_granny on public.taxi_rides (granny_id, at_s desc);
create index snitches_target on public.snitches (target_granny_id, live_until_s);
create index blinds_team on public.blinds (team_id, until_s);

alter table public.events             enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.app_settings       enable row level security;
alter table public.purged_games       enable row level security;
-- Ingen policyer: klienter leser varsler via my_events().

-- ---------------------------------------------------------------------------
-- Interne hjelpere
-- ---------------------------------------------------------------------------

-- Innlogget spiller, med sjekk av rolle. Kaster feil hvis rollen ikke stemmer.
create or replace function public._player(p_role public.player_role default null)
returns public.players
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null then raise exception 'Ikke med i et spill' using errcode = '42501'; end if;
  if p_role is not null and p.role <> p_role then
    raise exception '%', case p_role when 'admin' then 'Bare for spilleder' when 'team' then 'Bare for lag' else 'Bare for grannies' end
      using errcode = '42501';
  end if;
  return p;
end
$$;

-- 2700 → «0:45»
create or replace function public._fmt(s int) returns text
language sql immutable set search_path = ''
as $$ select (s / 3600)::text || ':' || lpad(((s % 3600) / 60)::text, 2, '0') $$;

create or replace function public._point(p_lat double precision, p_lng double precision)
returns extensions.geography
language sql immutable set search_path = ''
as $$ select extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography $$;

-- Står spilleren i sonen? Litt slingringsmonn for GPS-unøyaktighet (maks 25 m).
create or replace function public._in_zone(z public.zones, p_lat double precision, p_lng double precision, p_accuracy real)
returns boolean
language sql stable set search_path = ''
as $$
  select p_lat is not null and p_lng is not null and z.radius_m is not null
     and extensions.st_dwithin(z.geom, public._point(p_lat, p_lng), z.radius_m + least(coalesce(p_accuracy, 0), 25))
$$;

-- Lagre posisjonen som fulgte med en handling.
create or replace function public._record_position(p public.players, p_lat double precision, p_lng double precision, p_accuracy real)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_lat is null or p_lng is null or p.role = 'admin' then return; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Ugyldig posisjon' using errcode = '22023';
  end if;
  insert into public.positions (game_id, granny_id, team_id, user_id, source, geom, accuracy_m)
  values (p.game_id, p.granny_id, p.team_id, p.user_id, 'app', public._point(p_lat, p_lng), p_accuracy);
end
$$;

-- Legg ut et varsel. Med dedupe_key lages det bare én gang per spill.
create or replace function public._emit(
  p_game uuid, p_s int, p_audience text, p_kind text, p_title text, p_body text default null,
  p_team uuid default null, p_granny uuid default null, p_data jsonb default null, p_dedupe text default null)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.events (game_id, at_s, audience, team_id, granny_id, kind, title, body, data, dedupe_key)
  values (p_game, p_s, p_audience, p_team, p_granny, p_kind, p_title, p_body, p_data, p_dedupe)
  on conflict (game_id, dedupe_key) where dedupe_key is not null do nothing
$$;

create or replace function public._team_blind_at(p_team uuid, p_s int) returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.blinds where team_id = p_team and from_s <= p_s and until_s > p_s) $$;

-- Skal spilleren se dette varselet? Blinde lag får ikke kart-, ping- eller taxivarsler.
create or replace function public._event_for(e public.events, p public.players)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select e.game_id = p.game_id and case
    when p.role = 'admin' then true
    when e.audience = 'all' then true
    when e.audience = 'teams' then p.role = 'team'
      and not (e.kind in ('ping', 'taxi', 'bingo', 'snitch') and public._team_blind_at(p.team_id, e.at_s))
    when e.audience = 'grannies' then p.role = 'granny'
    when e.audience = 'team' then p.team_id = e.team_id
    when e.audience = 'granny' then p.granny_id = e.granny_id
    else false
  end
$$;

create or replace function public._normalize_name(t text) returns text
language sql immutable set search_path = ''
as $$ select lower(regexp_replace(trim(coalesce(t, '')), '\s+', ' ', 'g')) $$;

create or replace function public._random_code(p_prefix text) returns text
language sql volatile set search_path = ''
as $$
  -- Uten tegn som er lette å forveksle (0/O, 1/I/L).
  select p_prefix || '-' || string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
  from generate_series(1, 6)
$$;

-- Plasseringspoeng for grannies (fanget som nr. 1 → 0p … aldri fanget → 20p).
create or replace function public.placement_points(p_order int) returns int
language sql immutable set search_path = ''
as $$
  select case when p_order is null then 20
              else ('{0,1,2,3,4,5,7,9,12,15}'::int[])[least(greatest(p_order, 1), 10)] end
$$;

-- ---------------------------------------------------------------------------
-- Varsler til appen
-- ---------------------------------------------------------------------------
create or replace function public.my_events(p_after bigint default 0)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id, 'at_s', e.at_s, 'kind', e.kind, 'title', e.title, 'body', e.body,
      'audience', e.audience, 'data', e.data, 'created_at', e.created_at
    ) order by e.id)
    from (
      select * from public.events e
      where e.game_id = p.game_id and e.id > coalesce(p_after, 0)
        and e.created_at > now() - interval '15 minutes'
        and public._event_for(e, p)
      order by e.id
      limit 50
    ) e
  ), '[]'::jsonb);
end
$$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public._player();
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then
    raise exception 'Ugyldig push-adresse' using errcode = '22023';
  end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, (select auth.uid()), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end
$$;

-- ---------------------------------------------------------------------------
-- Fangst, nå med varsler (samme logikk som i 20261111090000_catches.sql)
-- ---------------------------------------------------------------------------
create or replace function public.finalize_catch(p_catch uuid, p_by text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  c  public.catches;
  gr public.grannies;
  t  public.teams;
  g  public.games;
  s  record;
  pts int;
begin
  select * into c from public.catches where id = p_catch for update;
  if c is null then raise exception 'Fant ikke fangsten' using errcode = 'P0002'; end if;
  select * into gr from public.grannies where id = c.granny_id for update;
  if gr.caught_at_s is not null then raise exception 'Hun er allerede fanget' using errcode = 'P0001'; end if;
  select * into t from public.teams where id = c.team_id;
  select * into g from public.games where id = c.game_id;

  update public.catches set status = 'confirmed', resolved_at = now(), resolved_by = p_by,
         admin_reviewed_at = case when p_by = 'admin' then now() else admin_reviewed_at end
   where id = c.id;
  update public.catches set status = 'void', resolved_at = now(), resolved_by = p_by
   where granny_id = gr.id and status = 'pending' and id <> c.id;

  update public.grannies set caught_at_s = c.registered_s, caught_by = c.team_id where id = gr.id;

  with o as (
    select x.id, row_number() over (order by x.caught_at_s, cc.registered_at) as rn
    from public.grannies x
    join public.catches cc on cc.granny_id = x.id and cc.status = 'confirmed'
    where x.game_id = g.id and x.caught_at_s is not null and not x.is_romling
  )
  update public.grannies x set catch_order = o.rn from o where x.id = o.id;

  pts := case when gr.is_romling then 20 when t.assigned_granny_id = gr.id then 15 else 10 end;
  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  values (g.id, t.id, pts, case when gr.is_romling then 'romling' else 'fangst' end, c.id, c.registered_s);

  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  select g.id, t.id, 2, 'fotoalbum_tilbake', ph.id, c.registered_s
  from public.photos ph
  where ph.kind = 'fotoalbum' and ph.status = 'approved'
    and ph.granny_id = gr.id and ph.target_team_id = t.id
    and not exists (select 1 from public.points_ledger l where l.reason = 'fotoalbum_tilbake' and l.ref_id = ph.id);

  for s in
    select * from public.snitches
    where target_granny_id = gr.id and not bonus_awarded
      and c.registered_s - at_s between 0 and (g.rules->>'snitch_bonus_window_s')::int
  loop
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s)
    values (g.id, s.snitch_granny_id, 3, 'sladrehank', s.id, c.registered_s);
    update public.snitches set bonus_awarded = true where id = s.id;
    perform public._emit(g.id, c.registered_s, 'granny', 'snitch_bonus', 'Sladringen lønte seg',
      format('%s ble fanget. Du får 3p.', gr.name), p_granny => s.snitch_granny_id);
  end loop;

  if not gr.is_romling
     and c.registered_s >= (g.rules->>'honnor_min_free_s')::int
     and (select count(*) from public.taxi_rides where granny_id = gr.id) <= (g.rules->>'honnor_max_rides')::int
  then
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s)
    values (g.id, gr.id, 3, 'honnorrabatt', c.id, c.registered_s);
  end if;

  perform public._emit(g.id, c.registered_s, 'all', 'catch_confirmed',
    format('%s er fanget av %s.', case when gr.is_romling then 'Rømlingen ' || gr.name else gr.name end, t.name),
    null, p_data => jsonb_build_object('granny_id', gr.id, 'team_id', t.id),
    p_dedupe => 'catch_confirmed:' || gr.id);
end
$$;

create or replace function public.register_catch(p_granny uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players;
  g  public.games;
  gr public.grannies;
  t  public.teams;
  s  int;
  c  public.catches;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'team' then raise exception 'Bare lag kan registrere fangst' using errcode = '42501'; end if;
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  if s < g.head_start_s then raise exception 'Jakten har ikke startet' using errcode = 'P0001'; end if;

  select * into gr from public.grannies where id = p_granny and game_id = g.id;
  if gr is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  if gr.caught_at_s is not null then raise exception 'Hun er allerede fanget' using errcode = 'P0001'; end if;
  if gr.is_romling and (s < g.romling_reveal_s or t.license_at_s is null) then
    raise exception 'Krever lisens' using errcode = 'P0001';
  end if;

  select * into c from public.catches where granny_id = gr.id and team_id = t.id and status = 'pending';
  if c is null then
    insert into public.catches (game_id, granny_id, team_id, registered_by, registered_s)
    values (g.id, gr.id, t.id, p.user_id, s)
    returning * into c;
    perform public._emit(g.id, s, 'granny', 'catch_registered',
      format('%s sier de har fanget deg.', t.name), 'Bekreft i appen.', p_granny => gr.id,
      p_data => jsonb_build_object('catch_id', c.id));
  end if;

  return jsonb_build_object('id', c.id, 'granny_name', gr.name, 'registered_s', c.registered_s);
end
$$;

-- ---------------------------------------------------------------------------
-- Kart: sladrehankens anonyme markør, og Bingo gjør grannyen synlig i 60 sek
-- ---------------------------------------------------------------------------
create or replace function public._snitch_markers(p_game uuid, p_s int)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind', 'anonym', 'id', null, 'name', null, 'live_reason', null,
    'lat', extensions.st_y(z.geom::extensions.geometry), 'lng', extensions.st_x(z.geom::extensions.geometry),
    'accuracy_m', null, 'at_s', sn.at_s, 'age_s', p_s - sn.at_s)), '[]'::jsonb)
  from public.snitches sn
  join public.games g on g.id = sn.game_id
  join public.zones z on z.game_id = sn.game_id and z.kind = 'kaffekroken'
  where sn.game_id = p_game and sn.at_s <= p_s and p_s < sn.at_s + (g.rules->>'snitch_live_s')::int
$$;

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
  if exists (select 1 from public.photos where granny_id = p_granny and kind = 'bingo' and status = 'auto'
             and submitted_s <= p_s and p_s < submitted_s + 60) then
    return 'bingo';
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
    continue when gr.caught_at_s is not null and gr.caught_at_s <= s;
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

  markers := markers || public._snitch_markers(g.id, s);
  return jsonb_build_object('game_s', s, 'ping_s', ping, 'blind_until_s', null, 'markers', markers);
end
$$;

-- Grannyens kart: bare den anonyme sladremarkøren kommer i tillegg til sonene.
create or replace function public.granny_map()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('granny');
  g public.games;
  s int;
begin
  select * into g from public.games where id = p.game_id;
  s := public.game_seconds(g);
  return jsonb_build_object('game_s', s, 'markers', public._snitch_markers(g.id, s));
end
$$;

-- ---------------------------------------------------------------------------
-- Granny: status, taxi, sladrehank
-- ---------------------------------------------------------------------------
create or replace function public.granny_status()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('granny');
  g  public.games;
  gr public.grannies;
  s  int;
  rides int;
  last_taxi int;
  last_album int;
  album_pending boolean;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id;
  s := public.game_seconds(g);
  select count(*), max(at_s) into rides, last_taxi from public.taxi_rides where granny_id = gr.id;
  select max(submitted_s), bool_or(status = 'pending') into last_album, album_pending
    from public.photos where granny_id = gr.id and kind = 'fotoalbum' and status <> 'rejected';

  return jsonb_build_object(
    'game_s', s,
    'points', coalesce((select sum(delta) from public.points_ledger where granny_id = gr.id), 0),
    'taxi_rides', rides,
    'next_taxi_s', case when last_taxi is null then null else last_taxi + (g.rules->>'taxi_cooldown_s')::int end,
    'honnor_max_rides', (g.rules->>'honnor_max_rides')::int,
    'honnor_min_free_s', (g.rules->>'honnor_min_free_s')::int,
    'snitch_used', exists (select 1 from public.snitches where snitch_granny_id = gr.id),
    'fotoalbum_next_s', case when last_album is null then null else last_album + 3600 end,
    'fotoalbum_pending', coalesce(album_pending, false),
    'bingo_done', exists (select 1 from public.photos where granny_id = gr.id and kind = 'bingo' and status in ('auto', 'approved')),
    'bingo_points_next', least(2 + (select count(*) from public.photos where game_id = g.id and kind = 'bingo' and status in ('auto', 'approved'))::int, 5),
    'license_given', exists (select 1 from public.teams where game_id = g.id and license_at_s is not null),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color) order by t.name)
                       from public.teams t where t.game_id = g.id), '[]'::jsonb),
    'targets', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.name)
                         from public.grannies x
                         where x.game_id = g.id and not x.is_romling and x.caught_at_s is null and x.id <> gr.id), '[]'::jsonb)
  );
end
$$;

create or replace function public._granny_can_act(p public.players, g public.games, gr public.grannies)
returns int
language plpgsql stable security definer set search_path = ''
as $$
begin
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  if gr.caught_at_s is not null then raise exception 'Du er fanget' using errcode = 'P0001'; end if;
  return public.game_seconds(g);
end
$$;

create or replace function public.granny_taxi(p_lat double precision default null, p_lng double precision default null, p_accuracy real default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('granny');
  g  public.games;
  gr public.grannies;
  s  int;
  last_taxi int;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id for update;
  s := public._granny_can_act(p, g, gr);
  perform public._record_position(p, p_lat, p_lng, p_accuracy);

  select max(at_s) into last_taxi from public.taxi_rides where granny_id = gr.id;
  if last_taxi is not null and s - last_taxi < (g.rules->>'taxi_cooldown_s')::int then
    raise exception 'Taxi er sperret' using errcode = 'P0001';
  end if;

  insert into public.taxi_rides (game_id, granny_id, at_s) values (g.id, gr.id, s);
  perform public._emit(g.id, s, 'teams', 'taxi', 'En granny har tatt taxi.');
  return public.granny_status();
end
$$;

create or replace function public.granny_snitch(p_target uuid, p_lat double precision, p_lng double precision, p_accuracy real default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('granny');
  g  public.games;
  gr public.grannies;
  target public.grannies;
  z  public.zones;
  s  int;
  live_s int;
  until_s int;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id for update;
  s := public._granny_can_act(p, g, gr);
  if gr.is_romling then raise exception 'Rømlingen kan ikke sladre' using errcode = 'P0001'; end if;
  if s < g.head_start_s then raise exception 'Jakten har ikke startet' using errcode = 'P0001'; end if;
  if exists (select 1 from public.snitches where snitch_granny_id = gr.id) then
    raise exception 'Du har allerede sladret' using errcode = 'P0001';
  end if;

  perform public._record_position(p, p_lat, p_lng, p_accuracy);
  select * into z from public.zones where game_id = g.id and kind = 'kaffekroken' limit 1;
  if z is null or not public._in_zone(z, p_lat, p_lng, p_accuracy) then
    raise exception 'Du må stå i Kaffekroken' using errcode = 'P0001';
  end if;

  select * into target from public.grannies where id = p_target and game_id = g.id;
  if target is null or target.is_romling or target.caught_at_s is not null or target.id = gr.id then
    raise exception 'Du kan ikke sladre på henne' using errcode = 'P0001';
  end if;

  -- Flere sladringer på samme granny: tiden legges sammen.
  live_s := (g.rules->>'snitch_live_s')::int;
  select greatest(s, coalesce(max(x.live_until_s), s)) + live_s into until_s
    from public.snitches x where x.target_granny_id = target.id and x.live_until_s > s;

  insert into public.snitches (game_id, snitch_granny_id, target_granny_id, at_s, live_until_s)
  values (g.id, gr.id, target.id, s, until_s);

  perform public._emit(g.id, s, 'teams', 'snitch', 'Noen har sladret.',
    format('%s er live i %s sekunder.', target.name, until_s - s), p_data => jsonb_build_object('granny_id', target.id));
  perform public._emit(g.id, s, 'granny', 'snitch_target', 'Noen har sladret på deg.',
    format('Du er live i %s sekunder.', until_s - s), p_granny => target.id);
  return public.granny_status();
end
$$;

-- ---------------------------------------------------------------------------
-- Bilder: Fotoalbumet (granny), Bingo (granny), Postkort (lag)
-- ---------------------------------------------------------------------------
-- Klienten laster opp til Storage under «<game_id>/…», og kaller så submit_photo.
create or replace function public.submit_photo(
  p_kind public.photo_kind, p_path text,
  p_lat double precision default null, p_lng double precision default null, p_accuracy real default null,
  p_target_team uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player();
  g  public.games;
  gr public.grannies;
  t  public.teams;
  z  public.zones;
  s  int;
  last_album int;
  n  int;
  pts int;
  ph public.photos;
  dist real;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);

  if p_path is null or p_path not like g.id::text || '/%' or p_path like '%..%'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'photos' and o.name = p_path) then
    raise exception 'Fant ikke bildet' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.photos where storage_path = p_path) then
    raise exception 'Bildet er allerede sendt' using errcode = 'P0001';
  end if;
  perform public._record_position(p, p_lat, p_lng, p_accuracy);

  if p_kind in ('fotoalbum', 'bingo') then
    if p.role <> 'granny' then raise exception 'Bare for grannies' using errcode = '42501'; end if;
    select * into gr from public.grannies where id = p.granny_id for update;
    perform public._granny_can_act(p, g, gr);
    if gr.is_romling then raise exception 'Rømlingen gjør ikke oppgaver' using errcode = 'P0001'; end if;
  else
    if p.role <> 'team' then raise exception 'Bare for lag' using errcode = '42501'; end if;
    select * into t from public.teams where id = p.team_id;
  end if;

  if p_kind = 'fotoalbum' then
    select max(submitted_s) into last_album from public.photos
     where granny_id = gr.id and kind = 'fotoalbum' and status <> 'rejected';
    if last_album is not null and s - last_album < 3600 then
      raise exception 'Fotoalbumet er sperret' using errcode = 'P0001';
    end if;
    if p_target_team is not null and not exists (select 1 from public.teams where id = p_target_team and game_id = g.id) then
      raise exception 'Ukjent lag' using errcode = 'P0002';
    end if;
    insert into public.photos (game_id, kind, granny_id, target_team_id, storage_path, geom, submitted_s)
    values (g.id, 'fotoalbum', gr.id, p_target_team, p_path,
            case when p_lat is null then null else public._point(p_lat, p_lng) end, s)
    returning * into ph;
    perform public._emit(g.id, s, 'admin', 'photo_pending', 'Nytt bilde til Fotoalbumet', format('Fra %s.', gr.name),
      p_data => jsonb_build_object('photo_id', ph.id));

  elsif p_kind = 'bingo' then
    if exists (select 1 from public.photos where granny_id = gr.id and kind = 'bingo' and status in ('auto', 'approved')) then
      raise exception 'Du har allerede tatt Bingo' using errcode = 'P0001';
    end if;
    select * into z from public.zones where game_id = g.id and kind = 'bingo' limit 1;
    if z is null or not public._in_zone(z, p_lat, p_lng, p_accuracy) then
      raise exception 'Du må stå i Bingo-sonen' using errcode = 'P0001';
    end if;
    select count(*) into n from public.photos where game_id = g.id and kind = 'bingo' and status in ('auto', 'approved');
    pts := least(2 + n, 5);
    insert into public.photos (game_id, kind, granny_id, zone_id, storage_path, geom, submitted_s, status, reviewed_at)
    values (g.id, 'bingo', gr.id, z.id, p_path, public._point(p_lat, p_lng), s, 'auto', now())
    returning * into ph;
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s)
    values (g.id, gr.id, pts, 'bingo', ph.id, s);
    perform public._emit(g.id, s, 'teams', 'bingo', 'Bingo!',
      'En granny står ved et hemmelig sted. Hun er på kartet i 60 sekunder.',
      p_data => jsonb_build_object('lat', p_lat, 'lng', p_lng));
    perform public._emit(g.id, s, 'granny', 'bingo_ok', format('Bingo! Du får %sp.', pts), null, p_granny => gr.id);

  else -- postkort
    if s < g.head_start_s then raise exception 'Jakten har ikke startet' using errcode = 'P0001'; end if;
    select * into z from public.zones
     where game_id = g.id and kind = 'postkort' and opens_at_s <= s and s < closes_at_s
     order by opens_at_s desc limit 1;
    if z is null then raise exception 'Ingen postkort er åpne' using errcode = 'P0001'; end if;
    if exists (select 1 from public.photos where zone_id = z.id and status = 'approved') then
      raise exception 'Postkortet er allerede tatt' using errcode = 'P0001';
    end if;
    if p_lat is not null then
      dist := extensions.st_distance(z.geom, public._point(p_lat, p_lng));
    end if;
    insert into public.photos (game_id, kind, team_id, zone_id, storage_path, geom, submitted_s, distance_m)
    values (g.id, 'postkort', t.id, z.id, p_path,
            case when p_lat is null then null else public._point(p_lat, p_lng) end, s, dist)
    returning * into ph;
    perform public._emit(g.id, s, 'admin', 'photo_pending', format('Postkort %s fra %s', z.number, t.name),
      case when dist is null then 'Uten posisjon.' else format('%s m fra stedet.', round(dist)) end,
      p_data => jsonb_build_object('photo_id', ph.id));
  end if;

  return jsonb_build_object('id', ph.id, 'status', ph.status);
end
$$;

-- Hvem kan se et bilde i Storage? Brukes av Storage-policyen under.
create or replace function public.can_view_photo(p_name text)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
  ph public.photos;
  g public.games;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null then return false; end if;
  select * into ph from public.photos where storage_path = p_name;
  if ph is null then
    -- Opplastet, men ikke sendt inn ennå: bare spilleder.
    return p.role = 'admin' and p_name like p.game_id::text || '/%';
  end if;
  if ph.game_id <> p.game_id then return false; end if;
  if p.role = 'admin' then return true; end if;
  if ph.granny_id is not null and ph.granny_id = p.granny_id then return true; end if;
  if ph.team_id is not null and ph.team_id = p.team_id then return true; end if;
  -- Laget i Fotoalbumet får se bildet når blindheten er over.
  if ph.kind = 'fotoalbum' and ph.status = 'approved' and ph.target_team_id = p.team_id then
    select * into g from public.games where id = ph.game_id;
    return not exists (select 1 from public.blinds b where b.photo_id = ph.id and b.until_s > public.game_seconds(g));
  end if;
  return false;
end
$$;

create or replace function public.can_upload_photo(p_name text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.players p join public.games g on g.id = p.game_id
    where p.user_id = (select auth.uid()) and p.role in ('granny', 'team') and g.status = 'running'
      and p_name like p.game_id::text || '/%' and p_name ~ '^[0-9a-f-]+/[0-9a-zA-Z_-]+\.(jpg|webp)$')
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 8388608, '{image/jpeg,image/webp}')
on conflict (id) do nothing;

create policy photos_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.can_upload_photo(name));
create policy photos_read on storage.objects for select to authenticated
  using (bucket_id = 'photos' and public.can_view_photo(name));

-- Spilleder: bildekø
create or replace function public.admin_photos()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ph.id, 'kind', ph.kind, 'status', ph.status, 'storage_path', ph.storage_path,
      'submitted_at', ph.submitted_at, 'submitted_s', ph.submitted_s,
      'granny_id', gr.id, 'granny_name', gr.name,
      'team_id', t.id, 'team_name', t.name, 'team_color', t.color,
      'target_team_id', tt.id, 'target_team_name', tt.name,
      'postkort_number', z.number, 'mission', z.mission, 'distance_m', ph.distance_m,
      'zone_radius_m', z.radius_m,
      'competing', case when ph.kind = 'postkort' then
        (select count(*) from public.photos x where x.zone_id = ph.zone_id and x.status = 'pending')::int else null end
    ) order by ph.submitted_at)
    from public.photos ph
    left join public.grannies gr on gr.id = ph.granny_id
    left join public.teams t on t.id = ph.team_id
    left join public.teams tt on tt.id = ph.target_team_id
    left join public.zones z on z.id = ph.zone_id
    where ph.game_id = p.game_id and ph.status = 'pending'
  ), '[]'::jsonb);
end
$$;

create or replace function public.admin_review_photo(p_photo uuid, p_approve boolean, p_target_team uuid default null, p_note text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('admin');
  ph public.photos;
  g  public.games;
  t  public.teams;
  gr public.grannies;
  z  public.zones;
  s  int;
  tid uuid;
begin
  select * into ph from public.photos where id = p_photo and game_id = p.game_id for update;
  if ph is null then raise exception 'Fant ikke bildet' using errcode = 'P0002'; end if;
  if ph.status <> 'pending' then raise exception 'Bildet er allerede behandlet' using errcode = 'P0001'; end if;
  select * into g from public.games where id = ph.game_id;
  s := public.game_seconds(g);

  if not p_approve then
    update public.photos set status = 'rejected', reviewed_at = now(), note = p_note where id = ph.id;
    if ph.granny_id is not null then
      perform public._emit(g.id, s, 'granny', 'photo_rejected', 'Bildet ble ikke godkjent', p_note, p_granny => ph.granny_id);
    else
      perform public._emit(g.id, s, 'team', 'photo_rejected', 'Postkortet ble ikke godkjent', p_note, p_team => ph.team_id);
    end if;
    return;
  end if;

  if ph.kind = 'fotoalbum' then
    tid := coalesce(p_target_team, ph.target_team_id);
    select * into t from public.teams where id = tid and game_id = g.id;
    if t is null then raise exception 'Velg laget på bildet' using errcode = 'P0001'; end if;
    -- Et lag kan ikke blindes igjen før 15 min etter at forrige blindhet er over.
    if exists (select 1 from public.blinds where team_id = t.id
               and until_s + (g.rules->>'reblind_cooldown_s')::int > s) then
      raise exception 'Laget kan ikke blindes ennå' using errcode = 'P0001';
    end if;
    select * into gr from public.grannies where id = ph.granny_id;

    update public.photos set status = 'approved', reviewed_at = now(), target_team_id = t.id where id = ph.id;
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s) values (g.id, gr.id, 2, 'fotoalbum', ph.id, s);
    insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, -2, 'fotoalbum', ph.id, s);
    -- Har laget allerede fanget fotografen, får det poengene tilbake med en gang.
    if gr.caught_by = t.id then
      insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, 2, 'fotoalbum_tilbake', ph.id, s);
    end if;
    insert into public.blinds (game_id, team_id, photo_id, from_s, until_s)
    values (g.id, t.id, ph.id, s, s + (g.rules->>'blind_s')::int);

    perform public._emit(g.id, s, 'team', 'blind', 'Dere er tatt med i Fotoalbumet.',
      format('Dere er blinde i %s minutter.', (g.rules->>'blind_s')::int / 60), p_team => t.id);
    perform public._emit(g.id, s, 'granny', 'photo_approved', 'Fotoalbumet: godkjent!',
      format('Du får 2p, og %s er blinde i %s minutter.', t.name, (g.rules->>'blind_s')::int / 60), p_granny => gr.id);

  elsif ph.kind = 'postkort' then
    select * into z from public.zones where id = ph.zone_id;
    if exists (select 1 from public.photos where zone_id = ph.zone_id and status = 'approved') then
      raise exception 'Postkortet er allerede tatt' using errcode = 'P0001';
    end if;
    select * into t from public.teams where id = ph.team_id;
    update public.photos set status = 'approved', reviewed_at = now() where id = ph.id;
    insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, 2, 'postkort', ph.id, s);
    perform public._emit(g.id, s, 'teams', 'postkort_won', format('Postkort %s er tatt av %s.', z.number, t.name),
      p_dedupe => 'postkort_won:' || z.id);

  else
    update public.photos set status = 'approved', reviewed_at = now() where id = ph.id;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Lag: status, Nabovakten, Rømlingen
-- ---------------------------------------------------------------------------
create or replace function public.team_status()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('team');
  g public.games;
  t public.teams;
  s int;
  last_wrong int;
begin
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id;
  s := public.game_seconds(g);
  select max(at_s) into last_wrong from public.romling_attempts where team_id = t.id and not correct;

  return jsonb_build_object(
    'game_s', s,
    'points', coalesce((select sum(delta) from public.points_ledger where team_id = t.id), 0),
    'has_license', t.license_at_s is not null,
    'romling_name', case when t.license_at_s is not null
                         then (select name from public.grannies where game_id = g.id and is_romling) end,
    'romling_next_try_s', case when last_wrong is null then null else last_wrong + (g.rules->>'romling_retry_s')::int end,
    'romling_attempts', (select count(*) from public.romling_attempts where team_id = t.id),
    'nabovakt', coalesce((
      select jsonb_agg(jsonb_build_object('zone_id', z.id, 'number', z.number, 'label', z.label,
        'next_s', (select max(c.at_s) from public.nabovakt_checkins c where c.team_id = t.id and c.zone_id = z.id)
                  + (g.rules->>'nabovakt_cooldown_s')::int) order by z.number)
      from public.zones z where z.game_id = g.id and z.kind = 'nabovakt'), '[]'::jsonb),
    'postcards', coalesce((
      select jsonb_agg(jsonb_build_object(
        'zone_id', z.id, 'number', z.number, 'mission', z.mission,
        'opens_at_s', z.opens_at_s, 'closes_at_s', z.closes_at_s,
        'won_by', (select tw.name from public.photos x join public.teams tw on tw.id = x.team_id
                   where x.zone_id = z.id and x.status = 'approved' limit 1),
        'my_status', (select x.status from public.photos x where x.zone_id = z.id and x.team_id = t.id
                      order by x.submitted_at desc limit 1)
      ) order by z.opens_at_s)
      from public.zones z
      where z.game_id = g.id and z.kind = 'postkort' and z.opens_at_s <= s), '[]'::jsonb),
    'album_photos', coalesce((
      select jsonb_agg(jsonb_build_object('id', ph.id, 'storage_path', ph.storage_path, 'at_s', b.from_s) order by b.from_s desc)
      from public.photos ph join public.blinds b on b.photo_id = ph.id
      where ph.target_team_id = t.id and ph.status = 'approved' and b.until_s <= s), '[]'::jsonb),
    'scoreboard', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'color', x.color,
        'points', x.points, 'catches', x.catches) order by x.points desc, x.catches desc, x.name)
      from (
        select tt.id, tt.name, tt.color,
          coalesce((select sum(delta) from public.points_ledger l where l.team_id = tt.id), 0)::int as points,
          (select count(*) from public.grannies gg where gg.caught_by = tt.id)::int as catches
        from public.teams tt where tt.game_id = g.id
      ) x), '[]'::jsonb)
  );
end
$$;

create or replace function public.team_nabovakt(p_zone uuid, p_lat double precision, p_lng double precision, p_accuracy real default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('team');
  g public.games;
  t public.teams;
  z public.zones;
  s int;
  last_s int;
  seen uuid[];
  gr record;
  hit boolean;
begin
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id for update;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  if s < g.head_start_s then raise exception 'Jakten har ikke startet' using errcode = 'P0001'; end if;

  select * into z from public.zones where id = p_zone and game_id = g.id and kind = 'nabovakt';
  if z is null then raise exception 'Ukjent punkt' using errcode = 'P0002'; end if;
  select max(at_s) into last_s from public.nabovakt_checkins where team_id = t.id and zone_id = z.id;
  if last_s is not null and s - last_s < (g.rules->>'nabovakt_cooldown_s')::int then
    raise exception 'Punktet er brukt' using errcode = 'P0001';
  end if;

  perform public._record_position(p, p_lat, p_lng, p_accuracy);
  if not public._in_zone(z, p_lat, p_lng, p_accuracy) then
    raise exception 'Dere må stå ved punktet' using errcode = 'P0001';
  end if;

  -- Grannies (ikke Rømlingen) med en posisjon fra de siste 10 min innenfor søkeradien.
  select coalesce(array_agg(x.id), '{}') into seen
  from public.grannies x
  cross join lateral public.granny_position_at(x.id, s) pos
  where x.game_id = g.id and not x.is_romling and x.caught_at_s is null
    and pos.id is not null and pos.game_s >= s - 600
    and extensions.st_dwithin(z.geom, pos.geom, (g.rules->>'nabovakt_search_m')::int);
  hit := cardinality(seen) > 0;

  insert into public.nabovakt_checkins (game_id, team_id, zone_id, at_s, hit) values (g.id, t.id, z.id, s, hit);

  perform public._emit(g.id, s, 'team', 'nabovakt_result',
    case when hit then format('Ja, det er en granny innenfor %s m.', g.rules->>'nabovakt_search_m') else 'Nei, ingen grannies her.' end,
    format('Nabovakt-punkt %s.', z.number), p_team => t.id);
  for gr in select unnest(seen) as id loop
    perform public._emit(g.id, s, 'granny', 'nabovakt_seen', format('Nabovakten har sett deg ved punkt %s.', z.number),
      null, p_granny => gr.id);
  end loop;

  return jsonb_build_object('hit', hit, 'number', z.number,
    'next_s', s + (g.rules->>'nabovakt_cooldown_s')::int);
end
$$;

create or replace function public.team_romling_guess(p_guess text, p_lat double precision, p_lng double precision, p_accuracy real default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('team');
  g public.games;
  t public.teams;
  z public.zones;
  rom public.grannies;
  s int;
  last_wrong int;
  ok boolean;
begin
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id for update;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  if s < g.romling_reveal_s then raise exception 'Rømlingen er ikke annonsert' using errcode = 'P0001'; end if;
  if t.license_at_s is not null then raise exception 'Dere har allerede lisens' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_guess, ''))) = 0 then raise exception 'Skriv et navn' using errcode = '22023'; end if;

  select max(at_s) into last_wrong from public.romling_attempts where team_id = t.id and not correct;
  if last_wrong is not null and s - last_wrong < (g.rules->>'romling_retry_s')::int then
    raise exception 'Vent til neste forsøk' using errcode = 'P0001';
  end if;

  perform public._record_position(p, p_lat, p_lng, p_accuracy);
  select * into z from public.zones where game_id = g.id and kind = 'nattevakt' limit 1;
  if z is null or not public._in_zone(z, p_lat, p_lng, p_accuracy) then
    raise exception 'Dere må stå ved Nattevaktens post' using errcode = 'P0001';
  end if;

  select * into rom from public.grannies where game_id = g.id and is_romling;
  if rom is null then raise exception 'Det er ingen Rømling i dette spillet' using errcode = 'P0002'; end if;
  ok := public._normalize_name(p_guess) = public._normalize_name(rom.name);

  insert into public.romling_attempts (game_id, team_id, at_s, guess, correct) values (g.id, t.id, s, left(p_guess, 100), ok);
  if not ok then
    return jsonb_build_object('correct', false, 'next_try_s', s + (g.rules->>'romling_retry_s')::int);
  end if;

  update public.teams set license_at_s = s where id = t.id;
  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, 3, 'romling_navn', t.id, s);
  perform public._emit(g.id, s, 'granny', 'license', 'Et lag har knekt koden og kan nå jakte deg.', null, p_granny => rom.id);
  return jsonb_build_object('correct', true, 'name', rom.name);
end
$$;

-- ---------------------------------------------------------------------------
-- Slutt og tidsstyrte hendelser
-- ---------------------------------------------------------------------------
create or replace function public._end_game(p_game uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games;
  s int;
begin
  select * into g from public.games where id = p_game for update;
  if g.status not in ('running', 'paused') then return; end if;
  update public.games set status = 'ended',
         ended_at = coalesce(paused_at, least(now(), started_at + paused_total + make_interval(secs => duration_s)))
   where id = g.id;
  select * into g from public.games where id = p_game;
  s := public.game_seconds(g);

  -- Honnørrabatt for grannies som aldri ble fanget.
  insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s)
  select g.id, gr.id, 3, 'honnorrabatt', gr.id, s
  from public.grannies gr
  where gr.game_id = g.id and not gr.is_romling and gr.caught_at_s is null
    and s >= (g.rules->>'honnor_min_free_s')::int
    and (select count(*) from public.taxi_rides r where r.granny_id = gr.id) <= (g.rules->>'honnor_max_rides')::int
    and not exists (select 1 from public.points_ledger l where l.granny_id = gr.id and l.reason = 'honnorrabatt');

  -- Krav som aldri ble avgjort, faller bort.
  update public.catches set status = 'void', resolved_at = now(), resolved_by = 'timeout'
   where game_id = g.id and status = 'pending';

  perform public._emit(g.id, s, 'all', 'end', 'Spillet er over.', 'Se oppsummeringen i appen.', p_dedupe => 'end');
end
$$;

create or replace function public.admin_set_status(p_action text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
begin
  select * into g from public.games where id = p.game_id for update;

  case p_action
    when 'start' then
      if g.status <> 'setup' then raise exception 'Spillet er allerede startet'; end if;
      update public.games set status = 'running', started_at = now() where id = g.id;
      perform public._emit(g.id, 0, 'all', 'start', 'Spillet har startet!',
        format('Grannyene har %s minutter forsprang.', g.head_start_s / 60), p_dedupe => 'start');
    when 'pause' then
      if g.status <> 'running' then raise exception 'Spillet går ikke'; end if;
      update public.games set status = 'paused', paused_at = now() where id = g.id;
      perform public._emit(g.id, public.game_seconds(g), 'all', 'pause', 'Pause', 'Spillklokka står stille.');
    when 'resume' then
      if g.status <> 'paused' then raise exception 'Spillet er ikke pauset'; end if;
      update public.games set status = 'running', paused_total = paused_total + (now() - paused_at), paused_at = null where id = g.id;
      perform public._emit(g.id, public.game_seconds(g), 'all', 'resume', 'Spillet fortsetter.');
    when 'end' then
      if g.status not in ('running', 'paused') then raise exception 'Spillet går ikke'; end if;
      perform public._end_game(g.id);
    else
      raise exception 'Ukjent handling: %', p_action;
  end case;

  return public.game_state();
end
$$;

-- Kjøres av pg_cron. Lager varsler som kommer av at tiden går.
create or replace function public.tick_games()
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games;
  s int;
  ping int;
  z public.zones;
  b public.blinds;
  c record;
  nv text;
begin
  for g in select * from public.games where status = 'running' loop
    s := public.game_seconds(g);
    if s >= g.duration_s then
      perform public._end_game(g.id);
      continue;
    end if;

    for ping in select x from unnest(g.ping_schedule_s) x where x <= s and x > s - 120 loop
      perform public._emit(g.id, ping, 'teams', 'ping', 'Ping!', 'Kartet er oppdatert med nye posisjoner.',
        p_dedupe => 'ping:' || ping);
    end loop;

    if s >= g.romling_reveal_s and s < g.romling_reveal_s + 600
       and exists (select 1 from public.grannies where game_id = g.id and is_romling) then
      select label into nv from public.zones where game_id = g.id and kind = 'nattevakt' limit 1;
      perform public._emit(g.id, g.romling_reveal_s, 'teams', 'romling_reveal', 'Oi. Enda en har rømt.',
        format('Vi vet ikke hvem, men nattevakten så noe. Gå til %s og hjelp oss å fange henne.', coalesce(nv, 'Nattevaktens post')),
        p_dedupe => 'romling_reveal');
    end if;

    for z in select * from public.zones where game_id = g.id and kind = 'postkort'
             and opens_at_s <= s and s < closes_at_s and s < opens_at_s + 600 loop
      perform public._emit(g.id, z.opens_at_s, 'teams', 'postkort_open', format('Postkort %s', z.number),
        format('%s Åpent til %s.', z.mission, public._fmt(z.closes_at_s)),
        p_data => jsonb_build_object('zone_id', z.id), p_dedupe => 'postkort_open:' || z.id);
    end loop;

    for z in select * from public.zones zz where zz.game_id = g.id and zz.kind = 'postkort'
             and zz.closes_at_s <= s and s < zz.closes_at_s + 600
             and not exists (select 1 from public.photos x where x.zone_id = zz.id and x.status = 'approved') loop
      perform public._emit(g.id, z.closes_at_s, 'teams', 'postkort_closed', format('Postkort %s er borte.', z.number),
        'Ingen lag klarte det i tide.', p_dedupe => 'postkort_closed:' || z.id);
    end loop;

    for b in select * from public.blinds where game_id = g.id and until_s <= s and until_s > s - 600 loop
      perform public._emit(g.id, b.until_s, 'team', 'blind_over', 'Dere ser igjen.',
        'Kartet er tilbake. Bildet fra Fotoalbumet ligger under Poeng.',
        p_team => b.team_id, p_data => jsonb_build_object('photo_id', b.photo_id), p_dedupe => 'blind_over:' || b.id);
    end loop;

    for c in select cc.id, gr.name as granny, t.name as team from public.catches cc
             join public.grannies gr on gr.id = cc.granny_id join public.teams t on t.id = cc.team_id
             where cc.game_id = g.id and cc.status = 'pending'
               and now() - cc.registered_at > make_interval(secs => (g.rules->>'catch_confirm_timeout_s')::int) loop
      perform public._emit(g.id, s, 'admin', 'catch_overdue', 'Fangst ikke bekreftet',
        format('%s har ikke svart på at %s fanget henne. Avgjør i appen.', c.granny, c.team),
        p_dedupe => 'catch_overdue:' || c.id);
    end loop;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Spilleder: varsler og poeng
-- ---------------------------------------------------------------------------
create or replace function public.admin_broadcast(p_audience text, p_text text, p_team uuid default null, p_granny uuid default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
begin
  if p_audience not in ('all', 'teams', 'grannies', 'team', 'granny') then raise exception 'Ugyldig mottaker'; end if;
  if length(trim(coalesce(p_text, ''))) = 0 then raise exception 'Skriv en melding'; end if;
  if p_team is not null and not exists (select 1 from public.teams where id = p_team and game_id = p.game_id) then raise exception 'Ukjent lag'; end if;
  if p_granny is not null and not exists (select 1 from public.grannies where id = p_granny and game_id = p.game_id) then raise exception 'Ukjent granny'; end if;
  select * into g from public.games where id = p.game_id;
  perform public._emit(g.id, public.game_seconds(g), p_audience, 'message', 'Fra spilleder', left(p_text, 500),
    p_team => case when p_audience = 'team' then p_team end,
    p_granny => case when p_audience = 'granny' then p_granny end);
end
$$;

create or replace function public.admin_adjust_points(p_delta int, p_reason text, p_team uuid default null, p_granny uuid default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
begin
  if (p_team is null) = (p_granny is null) then raise exception 'Velg ett lag eller én granny'; end if;
  if p_delta = 0 or abs(p_delta) > 100 then raise exception 'Ugyldig poengsum'; end if;
  if p_team is not null and not exists (select 1 from public.teams where id = p_team and game_id = p.game_id) then raise exception 'Ukjent lag'; end if;
  if p_granny is not null and not exists (select 1 from public.grannies where id = p_granny and game_id = p.game_id) then raise exception 'Ukjent granny'; end if;
  select * into g from public.games where id = p.game_id;
  insert into public.points_ledger (game_id, team_id, granny_id, delta, reason, at_s, created_by)
  values (g.id, p_team, p_granny, p_delta, 'spilleder: ' || left(coalesce(nullif(trim(p_reason), ''), 'justering'), 100),
          public.game_seconds(g), 'admin');
end
$$;

-- ---------------------------------------------------------------------------
-- Spilleder: oppsett (S2)
-- ---------------------------------------------------------------------------
create or replace function public.admin_setup()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
begin
  select * into g from public.games where id = p.game_id;
  return jsonb_build_object(
    'game', jsonb_build_object('id', g.id, 'name', g.name, 'status', g.status, 'duration_s', g.duration_s,
      'head_start_s', g.head_start_s, 'romling_reveal_s', g.romling_reveal_s,
      'ping_schedule_s', to_jsonb(g.ping_schedule_s), 'rules', g.rules),
    'grannies', coalesce((select jsonb_agg(jsonb_build_object('id', gr.id, 'name', gr.name, 'is_romling', gr.is_romling,
        'code', (select code from public.join_codes jc where jc.granny_id = gr.id limit 1),
        'telegram_linked', gt.telegram_user_id is not null,
        'phones', (select count(*) from public.players pl where pl.granny_id = gr.id)) order by gr.is_romling, gr.name)
      from public.grannies gr left join public.granny_telegram gt on gt.granny_id = gr.id
      where gr.game_id = g.id), '[]'::jsonb),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color,
        'assigned_granny_id', t.assigned_granny_id,
        'code', (select code from public.join_codes jc where jc.team_id = t.id limit 1),
        'phones', (select count(*) from public.players pl where pl.team_id = t.id)) order by t.name)
      from public.teams t where t.game_id = g.id), '[]'::jsonb),
    'admin_codes', coalesce((select jsonb_agg(code) from public.join_codes where game_id = g.id and role = 'admin'), '[]'::jsonb),
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'kind', z.kind, 'number', z.number, 'label', z.label,
        'radius_m', z.radius_m, 'opens_at_s', z.opens_at_s, 'closes_at_s', z.closes_at_s, 'mission', z.mission,
        'geojson', extensions.st_asgeojson(z.geom)::jsonb) order by z.kind, z.number)
      from public.zones z where z.game_id = g.id), '[]'::jsonb)
  );
end
$$;

create or replace function public._admin_game_for_setup(p_require_setup boolean)
returns public.games
language plpgsql security definer set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
begin
  select * into g from public.games where id = p.game_id for update;
  if p_require_setup and g.status <> 'setup' then
    raise exception 'Kan bare endres før spillet starter' using errcode = 'P0001';
  end if;
  return g;
end
$$;

create or replace function public.admin_update_game(p_settings jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(false);
  timing boolean := p_settings ?| array['duration_s', 'head_start_s', 'romling_reveal_s', 'ping_schedule_s', 'rules'];
  sched int[];
begin
  if timing and g.status <> 'setup' then
    raise exception 'Tidene kan bare endres før spillet starter' using errcode = 'P0001';
  end if;
  if p_settings ? 'ping_schedule_s' then
    select array_agg(x::int order by x::int) into sched from jsonb_array_elements_text(p_settings->'ping_schedule_s') x;
  end if;
  update public.games set
    name             = coalesce(nullif(trim(p_settings->>'name'), ''), name),
    duration_s       = coalesce((p_settings->>'duration_s')::int, duration_s),
    head_start_s     = coalesce((p_settings->>'head_start_s')::int, head_start_s),
    romling_reveal_s = coalesce((p_settings->>'romling_reveal_s')::int, romling_reveal_s),
    ping_schedule_s  = coalesce(sched, ping_schedule_s),
    rules            = rules || coalesce(p_settings->'rules', '{}'::jsonb)
  where id = g.id;
end
$$;

create or replace function public.admin_save_granny(p_id uuid, p_name text, p_is_romling boolean default false)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(false);
  gid uuid;
begin
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Skriv et navn'; end if;
  if p_is_romling then
    update public.grannies set is_romling = false where game_id = g.id and is_romling and id is distinct from p_id;
  end if;
  if p_id is null then
    if g.status <> 'setup' then raise exception 'Kan bare endres før spillet starter' using errcode = 'P0001'; end if;
    insert into public.grannies (game_id, name, is_romling) values (g.id, trim(p_name), p_is_romling) returning id into gid;
    insert into public.join_codes (code, game_id, role, granny_id) values (public._random_code('G'), g.id, 'granny', gid);
    insert into public.granny_telegram (granny_id) values (gid);
  else
    update public.grannies set name = trim(p_name), is_romling = p_is_romling
     where id = p_id and game_id = g.id returning id into gid;
    if gid is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  end if;
  return gid;
end
$$;

create or replace function public.admin_save_team(p_id uuid, p_name text, p_color public.team_color, p_assigned uuid default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(false);
  tid uuid;
begin
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Skriv et navn'; end if;
  if p_assigned is not null and not exists (select 1 from public.grannies where id = p_assigned and game_id = g.id and not is_romling) then
    raise exception 'Ukjent granny';
  end if;
  if exists (select 1 from public.teams where game_id = g.id and color = p_color and id is distinct from p_id) then
    raise exception 'Fargen er tatt av et annet lag';
  end if;
  if p_id is null then
    if g.status <> 'setup' then raise exception 'Kan bare endres før spillet starter' using errcode = 'P0001'; end if;
    insert into public.teams (game_id, name, color, assigned_granny_id) values (g.id, trim(p_name), p_color, p_assigned) returning id into tid;
    insert into public.join_codes (code, game_id, role, team_id) values (public._random_code('L'), g.id, 'team', tid);
  else
    update public.teams set name = trim(p_name), color = p_color, assigned_granny_id = p_assigned
     where id = p_id and game_id = g.id returning id into tid;
    if tid is null then raise exception 'Fant ikke laget' using errcode = 'P0002'; end if;
  end if;
  return tid;
end
$$;

create or replace function public.admin_save_zone(
  p_id uuid, p_kind public.zone_kind, p_label text, p_geojson jsonb, p_radius_m int default null,
  p_number int default null, p_opens_at_s int default null, p_closes_at_s int default null, p_mission text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(false);
  v_geom extensions.geography;
  zid uuid;
begin
  v_geom := extensions.st_setsrid(extensions.st_geomfromgeojson(p_geojson::text), 4326)::extensions.geography;
  if p_kind = 'area' and extensions.geometrytype(v_geom::extensions.geometry) <> 'POLYGON' then raise exception 'Spillområdet må være et polygon'; end if;
  if p_kind <> 'area' and extensions.geometrytype(v_geom::extensions.geometry) <> 'POINT' then raise exception 'Sonen må være et punkt'; end if;
  if p_kind <> 'area' and coalesce(p_radius_m, 0) <= 0 then raise exception 'Sett radius'; end if;
  if p_kind = 'postkort' and (p_opens_at_s is null or p_closes_at_s is null or p_closes_at_s <= p_opens_at_s) then
    raise exception 'Postkort trenger åpne- og stengetid';
  end if;

  if p_id is null then
    if p_kind = 'area' then delete from public.zones where game_id = g.id and kind = 'area'; end if;
    insert into public.zones (game_id, kind, number, label, geom, radius_m, opens_at_s, closes_at_s, mission)
    values (g.id, p_kind, p_number, coalesce(nullif(trim(p_label), ''), p_kind::text), v_geom,
            case when p_kind = 'area' then null else p_radius_m end, p_opens_at_s, p_closes_at_s, p_mission)
    returning id into zid;
  else
    update public.zones set kind = p_kind, number = p_number, label = coalesce(nullif(trim(p_label), ''), label), geom = v_geom,
           radius_m = case when p_kind = 'area' then null else p_radius_m end,
           opens_at_s = p_opens_at_s, closes_at_s = p_closes_at_s, mission = p_mission
     where id = p_id and game_id = g.id returning id into zid;
    if zid is null then raise exception 'Fant ikke sonen' using errcode = 'P0002'; end if;
  end if;
  return zid;
end
$$;

create or replace function public.admin_delete(p_kind text, p_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(p_kind <> 'zone');
begin
  case p_kind
    when 'granny' then delete from public.grannies where id = p_id and game_id = g.id;
    when 'team'   then delete from public.teams where id = p_id and game_id = g.id;
    when 'zone'   then delete from public.zones where id = p_id and game_id = g.id;
    else raise exception 'Ukjent type';
  end case;
end
$$;

-- ---------------------------------------------------------------------------
-- Oppsummering (alle anonyme handlinger avsløres)
-- ---------------------------------------------------------------------------
create or replace function public.game_summary()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player();
  g public.games;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'ended' and p.role <> 'admin' then
    raise exception 'Oppsummeringen kommer når spillet er over' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'game_name', g.name,
    'status', g.status,
    'game_s', public.game_seconds(g),
    'grannies', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.total desc, coalesce(x.caught_at_s, 1000000) desc, x.name)
      from (
        select gr.id, gr.name, gr.catch_order, gr.caught_at_s, t.name as caught_by,
               public.placement_points(gr.catch_order) as placement,
               coalesce((select sum(delta) from public.points_ledger l where l.granny_id = gr.id), 0)::int as tasks,
               public.placement_points(gr.catch_order)
                 + coalesce((select sum(delta) from public.points_ledger l where l.granny_id = gr.id), 0)::int as total,
               (select count(*) from public.taxi_rides r where r.granny_id = gr.id)::int as taxi_rides
        from public.grannies gr left join public.teams t on t.id = gr.caught_by
        where gr.game_id = g.id and not gr.is_romling
      ) x), '[]'::jsonb),
    'romling', (select jsonb_build_object('name', gr.name, 'caught_at_s', gr.caught_at_s, 'caught_by', t.name,
                  'licensed', (select coalesce(jsonb_agg(jsonb_build_object('team', tt.name, 'at_s', tt.license_at_s) order by tt.license_at_s), '[]'::jsonb)
                               from public.teams tt where tt.game_id = g.id and tt.license_at_s is not null))
                from public.grannies gr left join public.teams t on t.id = gr.caught_by
                where gr.game_id = g.id and gr.is_romling),
    'teams', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.points desc, x.catches desc, x.name)
      from (
        select t.id, t.name, t.color,
               coalesce((select sum(delta) from public.points_ledger l where l.team_id = t.id), 0)::int as points,
               (select count(*) from public.grannies gg where gg.caught_by = t.id)::int as catches
        from public.teams t where t.game_id = g.id
      ) x), '[]'::jsonb),
    'catches', coalesce((
      select jsonb_agg(jsonb_build_object('order', gr.catch_order, 'granny', gr.name, 'is_romling', gr.is_romling,
               'team', t.name, 'at_s', gr.caught_at_s) order by gr.caught_at_s)
      from public.grannies gr join public.teams t on t.id = gr.caught_by
      where gr.game_id = g.id and gr.caught_at_s is not null), '[]'::jsonb),
    'snitches', coalesce((
      select jsonb_agg(jsonb_build_object('snitch', a.name, 'target', b.name, 'at_s', sn.at_s, 'bonus', sn.bonus_awarded) order by sn.at_s)
      from public.snitches sn join public.grannies a on a.id = sn.snitch_granny_id join public.grannies b on b.id = sn.target_granny_id
      where sn.game_id = g.id), '[]'::jsonb),
    'album', coalesce((
      select jsonb_agg(jsonb_build_object('photographer', gr.name, 'team', t.name, 'at_s', ph.submitted_s) order by ph.submitted_s)
      from public.photos ph join public.grannies gr on gr.id = ph.granny_id join public.teams t on t.id = ph.target_team_id
      where ph.game_id = g.id and ph.kind = 'fotoalbum' and ph.status = 'approved'), '[]'::jsonb)
  );
end
$$;

-- ---------------------------------------------------------------------------
-- game-worker (Edge Function, service_role): push og sletting
-- ---------------------------------------------------------------------------
create or replace function public.worker_claim_events()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  with claimed as (
    update public.events e set pushed_at = now()
    where e.id in (
      select id from public.events
      where pushed_at is null and created_at > now() - interval '5 minutes'
      order by id limit 200
      for update skip locked)
    returning e.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'kind', c.kind, 'title', c.title, 'body', c.body,
    'subs', coalesce((
      select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from public.events ee
      join public.players p on p.game_id = ee.game_id
      join public.push_subscriptions s on s.user_id = p.user_id
      where ee.id = c.id
        -- Spilleder får push bare for det som er ment for spilleder.
        and case when p.role = 'admin' then ee.audience = 'admin'
                 else public._event_for(ee, p) end
    ), '[]'::jsonb))), '[]'::jsonb)
  into result
  from claimed c;
  return result;
end
$$;

create or replace function public.worker_remove_subscription(p_endpoint text)
returns void
language sql security definer set search_path = ''
as $$ delete from public.push_subscriptions where endpoint = p_endpoint $$;

-- Sletter spill som ble avsluttet for mer enn retention_days siden (standard 30).
create or replace function public.purge_expired_games()
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games;
  n int := 0;
begin
  for g in select * from public.games
           where status = 'ended' and ended_at < now() - make_interval(days => coalesce((rules->>'retention_days')::int, 30)) loop
    insert into public.purged_games (game_id) values (g.id) on conflict do nothing;
    -- Anonyme brukere som bare var med i dette spillet.
    begin
      delete from auth.users u
       where u.id in (select user_id from public.players where game_id = g.id) and u.is_anonymous;
    exception when others then
      raise warning 'Kunne ikke slette brukere for spill %: %', g.id, sqlerrm;
    end;
    delete from public.games where id = g.id;
    n := n + 1;
  end loop;
  return n;
end
$$;

create or replace function public.worker_storage_to_clean()
returns jsonb
language sql security definer set search_path = ''
as $$ select coalesce(jsonb_agg(game_id), '[]'::jsonb) from public.purged_games where storage_cleaned_at is null $$;

create or replace function public.worker_mark_cleaned(p_game uuid)
returns void
language sql security definer set search_path = ''
as $$ update public.purged_games set storage_cleaned_at = now() where game_id = p_game $$;

-- ---------------------------------------------------------------------------
-- Tilganger
-- ---------------------------------------------------------------------------
revoke execute on function
  public._player(public.player_role), public._fmt(int), public._point(double precision, double precision),
  public._in_zone(public.zones, double precision, double precision, real),
  public._record_position(public.players, double precision, double precision, real),
  public._emit(uuid, int, text, text, text, text, uuid, uuid, jsonb, text),
  public._team_blind_at(uuid, int), public._event_for(public.events, public.players),
  public._normalize_name(text), public._random_code(text), public.placement_points(int),
  public._snitch_markers(uuid, int), public._granny_can_act(public.players, public.games, public.grannies),
  public._end_game(uuid), public.tick_games(), public._admin_game_for_setup(boolean),
  public.worker_claim_events(), public.worker_remove_subscription(text), public.purge_expired_games(),
  public.worker_storage_to_clean(), public.worker_mark_cleaned(uuid),
  public.my_events(bigint), public.save_push_subscription(text, text, text), public.granny_map(),
  public.granny_status(), public.granny_taxi(double precision, double precision, real),
  public.granny_snitch(uuid, double precision, double precision, real),
  public.submit_photo(public.photo_kind, text, double precision, double precision, real, uuid),
  public.can_view_photo(text), public.can_upload_photo(text),
  public.admin_photos(), public.admin_review_photo(uuid, boolean, uuid, text),
  public.team_status(), public.team_nabovakt(uuid, double precision, double precision, real),
  public.team_romling_guess(text, double precision, double precision, real),
  public.admin_broadcast(text, text, uuid, uuid), public.admin_adjust_points(int, text, uuid, uuid),
  public.admin_setup(), public.admin_update_game(jsonb), public.admin_save_granny(uuid, text, boolean),
  public.admin_save_team(uuid, text, public.team_color, uuid),
  public.admin_save_zone(uuid, public.zone_kind, text, jsonb, int, int, int, int, text),
  public.admin_delete(text, uuid), public.game_summary()
from public, anon, authenticated;

grant execute on function
  public.my_events(bigint), public.save_push_subscription(text, text, text), public.granny_map(),
  public.granny_status(), public.granny_taxi(double precision, double precision, real),
  public.granny_snitch(uuid, double precision, double precision, real),
  public.submit_photo(public.photo_kind, text, double precision, double precision, real, uuid),
  public.can_view_photo(text), public.can_upload_photo(text),
  public.admin_photos(), public.admin_review_photo(uuid, boolean, uuid, text),
  public.team_status(), public.team_nabovakt(uuid, double precision, double precision, real),
  public.team_romling_guess(text, double precision, double precision, real),
  public.admin_broadcast(text, text, uuid, uuid), public.admin_adjust_points(int, text, uuid, uuid),
  public.admin_setup(), public.admin_update_game(jsonb), public.admin_save_granny(uuid, text, boolean),
  public.admin_save_team(uuid, text, public.team_color, uuid),
  public.admin_save_zone(uuid, public.zone_kind, text, jsonb, int, int, int, int, text),
  public.admin_delete(text, uuid), public.game_summary()
to authenticated;

grant execute on function
  public.worker_claim_events(), public.worker_remove_subscription(text),
  public.worker_storage_to_clean(), public.worker_mark_cleaned(uuid)
to service_role;

-- Nye tabeller: klienter leser ikke direkte (alt går via RPC-ene over).
revoke all on public.events, public.push_subscriptions, public.app_settings, public.purged_games from anon, authenticated;
