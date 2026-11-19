-- Endringer etter planleggingsmøtet:
--   * Jakten varer 1:30. Ny standard tidsplan, og spill i oppsett får den.
--   * Honnørrabatten er fjernet. Hver granny har én taxitur (regel taxi_max_rides).
--   * Bonus-grannies (uten eget lag) gir 20p (regel catch_points_bonus).
--   * Taxisjåfører har egen rolle: grannyen bestiller, første sjåfør i køen tar turen,
--     lagene ser hentestedet en stund, og grannies ser taxiene på kartet.
--   * Side quests: spilleder lager oppdrag, laget sender bilde eller video, spilleder
--     godkjenner og gir poeng og/eller evnen «se granny live» (laget velger granny).
--   * Fangst registreres med selfie. Grannyen bekrefter fortsatt.
--   * Profilbilde av hver granny.

-- ---------------------------------------------------------------------------
-- Tider og regler
-- ---------------------------------------------------------------------------
alter table public.games
  alter column duration_s set default 5400,
  alter column head_start_s set default 900,
  alter column romling_reveal_s set default 2400,
  alter column ping_schedule_s set default '{900,1500,2100,2700,3300,3900,4200,4500,4800,5100,5400}',
  alter column rules set default '{
    "snitch_live_s": 60,
    "snitch_bonus_window_s": 600,
    "blind_s": 600,
    "reblind_cooldown_s": 900,
    "taxi_max_rides": 1,
    "taxi_pickup_show_s": 600,
    "ability_live_s": 60,
    "catch_points_bonus": 20,
    "romling_retry_s": 1200,
    "nabovakt_search_m": 300,
    "nabovakt_cooldown_s": 3600,
    "out_of_area_grace_s": 60,
    "catch_confirm_timeout_s": 120,
    "telegram_stale_reminder_s": 60,
    "telegram_stale_admin_s": 180,
    "retention_days": 30
  }'::jsonb;

update public.games
   set rules = (rules - 'taxi_cooldown_s' - 'honnor_min_free_s' - 'honnor_max_rides')
               || '{"taxi_max_rides": 1, "taxi_pickup_show_s": 600, "ability_live_s": 60, "catch_points_bonus": 20}'::jsonb;

update public.games
   set duration_s = 5400, head_start_s = 900, romling_reveal_s = 2400,
       ping_schedule_s = '{900,1500,2100,2700,3300,3900,4200,4500,4800,5100,5400}'
 where status = 'setup';

-- ---------------------------------------------------------------------------
-- Nye kolonner og tabeller
-- ---------------------------------------------------------------------------
alter table public.grannies add column avatar_path text;
alter table public.catches  add column selfie_path text;

create table public.taxis (
  id         uuid primary key default gen_random_uuid(),
  game_id    uuid not null references public.games on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);

alter table public.join_codes add column taxi_id uuid references public.taxis on delete cascade;
alter table public.join_codes drop constraint join_codes_check;
alter table public.join_codes add constraint join_codes_check check (
  (role = 'team'   and team_id is not null and granny_id is null and taxi_id is null) or
  (role = 'granny' and granny_id is not null and team_id is null and taxi_id is null) or
  (role = 'taxi'   and taxi_id is not null and team_id is null and granny_id is null) or
  (role = 'admin'  and team_id is null and granny_id is null and taxi_id is null));

alter table public.players add column taxi_id uuid references public.taxis on delete cascade;

alter table public.positions add column taxi_id uuid references public.taxis on delete cascade;
alter table public.positions drop constraint positions_check;
alter table public.positions add constraint positions_check check (num_nonnulls(granny_id, team_id, taxi_id) = 1);
create index positions_taxi_time on public.positions (taxi_id, recorded_at desc) where taxi_id is not null;

create table public.taxi_requests (
  id           uuid primary key default gen_random_uuid(),
  game_id      uuid not null references public.games on delete cascade,
  granny_id    uuid not null references public.grannies on delete cascade,
  taxi_id      uuid references public.taxis on delete set null,
  status       text not null default 'waiting' check (status in ('waiting', 'accepted', 'picked_up', 'done', 'cancelled')),
  requested_at timestamptz not null default now(),
  requested_s  int not null,
  accepted_s   int,
  picked_s     int,
  done_s       int,
  pickup       extensions.geography(Point, 4326)
);
create unique index taxi_requests_one_open on public.taxi_requests (granny_id) where status in ('waiting', 'accepted', 'picked_up');
create unique index taxi_requests_one_ride on public.taxi_requests (taxi_id) where status in ('accepted', 'picked_up');
create index taxi_requests_queue on public.taxi_requests (game_id, status, requested_at);

create table public.quests (
  id               uuid primary key default gen_random_uuid(),
  game_id          uuid not null references public.games on delete cascade,
  title            text not null,
  description      text,
  reward_points    int not null default 0 check (reward_points >= 0),
  reward_abilities int not null default 0 check (reward_abilities >= 0),
  team_id          uuid references public.teams on delete cascade,   -- null = alle lag
  closed           boolean not null default false,
  created_at       timestamptz not null default now()
);

create table public.quest_submissions (
  id           uuid primary key default gen_random_uuid(),
  game_id      uuid not null references public.games on delete cascade,
  quest_id     uuid not null references public.quests on delete cascade,
  team_id      uuid not null references public.teams on delete cascade,
  storage_path text not null,
  media        text not null check (media in ('image', 'video')),
  submitted_at timestamptz not null default now(),
  submitted_s  int not null,
  status       public.review_status not null default 'pending',
  note         text,
  reviewed_at  timestamptz
);
create unique index quest_submissions_one on public.quest_submissions (quest_id, team_id) where status in ('pending', 'approved');

create table public.team_abilities (
  id               uuid primary key default gen_random_uuid(),
  game_id          uuid not null references public.games on delete cascade,
  team_id          uuid not null references public.teams on delete cascade,
  submission_id    uuid references public.quest_submissions on delete set null,
  granted_s        int not null,
  used_s           int,
  target_granny_id uuid references public.grannies on delete set null
);
create index team_abilities_team on public.team_abilities (team_id, used_s);

alter table public.taxis             enable row level security;
alter table public.taxi_requests     enable row level security;
alter table public.quests            enable row level security;
alter table public.quest_submissions enable row level security;
alter table public.team_abilities    enable row level security;
revoke all on public.taxis, public.taxi_requests, public.quests, public.quest_submissions, public.team_abilities
  from anon, authenticated;

-- Varsler til alle taxisjåfører.
alter table public.events drop constraint events_audience_check;
alter table public.events add constraint events_audience_check
  check (audience in ('all', 'teams', 'grannies', 'team', 'granny', 'admin', 'taxis'));

-- Video til side quests, og større filer.
update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = '{image/jpeg,image/webp,video/mp4,video/quicktime,video/webm}'
 where id = 'photos';

-- ---------------------------------------------------------------------------
-- Innlogging, posisjon og varsler for den nye rollen
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

  insert into public.players (user_id, game_id, role, team_id, granny_id, taxi_id)
  values ((select auth.uid()), c.game_id, c.role, c.team_id, c.granny_id, c.taxi_id)
  on conflict (user_id) do update
    set game_id = excluded.game_id, role = excluded.role, team_id = excluded.team_id,
        granny_id = excluded.granny_id, taxi_id = excluded.taxi_id, joined_at = now()
  returning * into result;

  return result;
end
$$;

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

  insert into public.positions (game_id, granny_id, team_id, taxi_id, user_id, source, geom, accuracy_m)
  values (p.game_id, p.granny_id, p.team_id, p.taxi_id, p.user_id, 'app',
          extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
          p_accuracy);
end
$$;

create or replace function public._record_position(p public.players, p_lat double precision, p_lng double precision, p_accuracy real)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_lat is null or p_lng is null or p.role = 'admin' then return; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Ugyldig posisjon' using errcode = '22023';
  end if;
  insert into public.positions (game_id, granny_id, team_id, taxi_id, user_id, source, geom, accuracy_m)
  values (p.game_id, p.granny_id, p.team_id, p.taxi_id, p.user_id, 'app', public._point(p_lat, p_lng), p_accuracy);
end
$$;

create or replace function public._event_for(e public.events, p public.players)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select e.game_id = p.game_id and case
    when p.role = 'admin' then true
    when e.audience = 'all' then true
    when e.audience = 'teams' then p.role = 'team'
      and not (e.kind in ('ping', 'taxi', 'bingo', 'snitch', 'reveal') and public._team_blind_at(p.team_id, e.at_s))
    when e.audience = 'grannies' then p.role = 'granny'
    when e.audience = 'team' then p.team_id = e.team_id
    when e.audience = 'granny' then p.granny_id = e.granny_id
    when e.audience = 'taxis' then p.role = 'taxi'
    else false
  end
$$;

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
  tx public.taxis;
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
  if p.taxi_id is not null then
    select * into tx from public.taxis where id = p.taxi_id;
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
      'caught', gr.caught_at_s is not null, 'caught_at_s', gr.caught_at_s,
      'avatar_path', gr.avatar_path) end,
    'taxi', case when tx.id is null then null else jsonb_build_object('id', tx.id, 'name', tx.name) end
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Bilder: profilbilder, selfie ved fangst og video til side quests
-- ---------------------------------------------------------------------------
create or replace function public.can_upload_photo(p_name text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.players p join public.games g on g.id = p.game_id
    where p.user_id = (select auth.uid()) and p_name like p.game_id::text || '/%'
      and (
        -- Bilder i spillet (fotoalbum, bingo, postkort, selfie ved fangst)
        (p.role in ('granny', 'team') and g.status = 'running'
           and p_name ~ '^[0-9a-f-]+/[0-9a-zA-Z_-]+\.(jpg|webp)$')
        -- Side quest: bilde eller video fra laget
        or (p.role = 'team' and g.status = 'running'
           and p_name ~ '^[0-9a-f-]+/quest-[0-9a-zA-Z_-]+\.(jpg|webp|mp4|mov|webm)$')
        -- Profilbilde: grannyen selv eller spilleder, når som helst før spillet er over
        or (p.role in ('granny', 'admin') and g.status <> 'ended'
           and p_name ~ '^[0-9a-f-]+/avatar-[0-9a-zA-Z_-]+\.(jpg|webp)$')
      ))
$$;

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
  if p_name not like p.game_id::text || '/%' then return false; end if;

  -- Profilbilder ser alle i spillet. Rømlingens bilde ser bare spilleder og hun selv.
  if exists (select 1 from public.grannies gr
             where gr.avatar_path = p_name and gr.game_id = p.game_id
               and (not gr.is_romling or p.role = 'admin' or gr.id = p.granny_id)) then
    return true;
  end if;

  select * into ph from public.photos where storage_path = p_name;
  if ph is null then
    -- Selfie ved fangst, side quest-bevis, eller ikke sendt inn ennå: bare spilleder.
    return p.role = 'admin';
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

create or replace function public._check_path(p public.players, p_path text, p_prefix text)
returns void
language plpgsql immutable set search_path = ''
as $$
begin
  if p_path is null or p_path not like p.game_id::text || '/' || p_prefix || '%' then
    raise exception 'Ugyldig bilde' using errcode = '22023';
  end if;
end
$$;

create or replace function public.granny_set_avatar(p_path text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('granny');
begin
  perform public._check_path(p, p_path, 'avatar-');
  update public.grannies set avatar_path = p_path where id = p.granny_id;
end
$$;

create or replace function public.admin_set_avatar(p_granny uuid, p_path text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
begin
  if p_path is not null then perform public._check_path(p, p_path, 'avatar-'); end if;
  update public.grannies set avatar_path = p_path where id = p_granny and game_id = p.game_id;
  if not found then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Fangst: selfie, bonuspoeng, ingen honnørrabatt
-- ---------------------------------------------------------------------------
drop function public.register_catch(uuid);
create function public.register_catch(p_granny uuid, p_selfie text default null)
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
  if p_selfie is not null then perform public._check_path(p, p_selfie, ''); end if;

  select * into gr from public.grannies where id = p_granny and game_id = g.id;
  if gr is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  if gr.caught_at_s is not null then raise exception 'Hun er allerede fanget' using errcode = 'P0001'; end if;
  if gr.is_romling and (s < g.romling_reveal_s or t.license_at_s is null) then
    raise exception 'Krever lisens' using errcode = 'P0001';
  end if;

  select * into c from public.catches where granny_id = gr.id and team_id = t.id and status = 'pending';
  if c is null then
    insert into public.catches (game_id, granny_id, team_id, registered_by, registered_s, selfie_path)
    values (g.id, gr.id, t.id, p.user_id, s, p_selfie)
    returning * into c;
    perform public._emit(g.id, s, 'granny', 'catch_registered',
      format('%s sier de har fanget deg.', t.name), 'Bekreft i appen.', p_granny => gr.id,
      p_data => jsonb_build_object('catch_id', c.id));
  elsif p_selfie is not null then
    update public.catches set selfie_path = p_selfie where id = c.id returning * into c;
  end if;

  return jsonb_build_object('id', c.id, 'granny_name', gr.name, 'registered_s', c.registered_s);
end
$$;

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
  bonus boolean;
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

  -- Bonus-granny: ingen lag har henne som egen granny.
  bonus := not gr.is_romling and not exists (select 1 from public.teams tt where tt.assigned_granny_id = gr.id);
  pts := case
    when gr.is_romling then 20
    when t.assigned_granny_id = gr.id then 15
    when bonus then coalesce((g.rules->>'catch_points_bonus')::int, 20)
    else 10 end;
  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  values (g.id, t.id, pts, case when gr.is_romling then 'romling' when bonus then 'fangst_bonus' else 'fangst' end, c.id, c.registered_s);

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

  -- En granny som blir fanget, kan ikke lenger vente på taxi.
  update public.taxi_requests set status = 'cancelled'
   where granny_id = gr.id and status in ('waiting', 'accepted');

  perform public._emit(g.id, c.registered_s, 'all', 'catch_confirmed',
    format('%s er fanget av %s.', case when gr.is_romling then 'Rømlingen ' || gr.name else gr.name end, t.name),
    case when bonus then format('Bonus-granny: %sp til laget.', pts) end,
    p_data => jsonb_build_object('granny_id', gr.id, 'team_id', t.id),
    p_dedupe => 'catch_confirmed:' || gr.id);
end
$$;

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

  -- Krav som aldri ble avgjort, faller bort. Det samme gjør taxiturer som ikke er ferdige.
  update public.catches set status = 'void', resolved_at = now(), resolved_by = 'timeout'
   where game_id = g.id and status = 'pending';
  update public.taxi_requests set status = 'cancelled' where game_id = g.id and status in ('waiting', 'accepted');
  update public.taxi_requests set status = 'done', done_s = s where game_id = g.id and status = 'picked_up';

  perform public._emit(g.id, s, 'all', 'end', 'Spillet er over.', 'Se oppsummeringen i appen.', p_dedupe => 'end');
end
$$;

create or replace function public.admin_catch_queue()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
  g public.games;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'admin' then raise exception 'Bare for spilleder' using errcode = '42501'; end if;
  select * into g from public.games where id = p.game_id;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'status', c.status,
      'granny_id', gr.id, 'granny_name', gr.name, 'is_romling', gr.is_romling,
      'team_id', t.id, 'team_name', t.name, 'team_color', t.color,
      'registered_s', c.registered_s,
      'selfie_path', c.selfie_path,
      'age_s', extract(epoch from now() - c.registered_at)::int,
      'overdue', c.status = 'pending' and now() - c.registered_at > make_interval(secs => (g.rules->>'catch_confirm_timeout_s')::int),
      'competing', (select count(*) from public.catches x where x.granny_id = c.granny_id and x.status = 'pending')::int
    ) order by c.registered_at)
    from public.catches c
    join public.grannies gr on gr.id = c.granny_id
    join public.teams t on t.id = c.team_id
    where c.game_id = g.id
      and (c.status = 'pending' or (c.status = 'rejected' and c.admin_reviewed_at is null))
  ), '[]'::jsonb);
end
$$;

-- ---------------------------------------------------------------------------
-- Taxi
-- ---------------------------------------------------------------------------
drop function public.granny_taxi(double precision, double precision, real);

create or replace function public._taxi_rides_used(p_granny uuid)
returns int
language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.taxi_rides where granny_id = p_granny $$;

create or replace function public.granny_request_taxi(p_lat double precision default null, p_lng double precision default null, p_accuracy real default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('granny');
  g  public.games;
  gr public.grannies;
  s  int;
  r  public.taxi_requests;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id for update;
  s := public._granny_can_act(p, g, gr);
  perform public._record_position(p, p_lat, p_lng, p_accuracy);

  if public._taxi_rides_used(gr.id) >= coalesce((g.rules->>'taxi_max_rides')::int, 1) then
    raise exception 'Du har brukt opp taxiturene dine' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.taxi_requests where granny_id = gr.id and status in ('waiting', 'accepted', 'picked_up')) then
    raise exception 'Du har allerede bestilt taxi' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.taxis where game_id = g.id) then
    raise exception 'Det er ingen taxier i spillet' using errcode = 'P0001';
  end if;

  insert into public.taxi_requests (game_id, granny_id, requested_s) values (g.id, gr.id, s) returning * into r;
  perform public._emit(g.id, s, 'taxis', 'taxi_request', format('%s vil ha taxi.', gr.name), 'Ta turen i appen.');
  return jsonb_build_object('id', r.id, 'status', r.status);
end
$$;

create or replace function public.granny_cancel_taxi()
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('granny');
  r  public.taxi_requests;
  gr public.grannies;
  g  public.games;
begin
  select * into r from public.taxi_requests where granny_id = p.granny_id and status in ('waiting', 'accepted') for update;
  if r.id is null then raise exception 'Du har ingen taxi på vei' using errcode = 'P0001'; end if;
  update public.taxi_requests set status = 'cancelled' where id = r.id;
  if r.status = 'accepted' then
    select * into gr from public.grannies where id = r.granny_id;
    select * into g from public.games where id = r.game_id;
    perform public._emit(g.id, public.game_seconds(g), 'taxis', 'taxi_cancelled', format('%s avbestilte taxien.', gr.name));
  end if;
end
$$;

create or replace function public.taxi_queue()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('taxi');
  g  public.games;
  s  int;
  r  public.taxi_requests;
  gr public.grannies;
  pos public.positions;
begin
  select * into g from public.games where id = p.game_id;
  s := public.game_seconds(g);
  select * into r from public.taxi_requests where taxi_id = p.taxi_id and status in ('accepted', 'picked_up');
  if r.id is not null then
    select * into gr from public.grannies where id = r.granny_id;
    -- Posisjonen vises bare til grannyen er hentet.
    if r.status = 'accepted' then pos := public.granny_position_at(gr.id, s); end if;
  end if;

  return jsonb_build_object(
    'game_s', s,
    'taxi', (select jsonb_build_object('id', id, 'name', name) from public.taxis where id = p.taxi_id),
    'active', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'status', r.status, 'granny_name', gr.name, 'granny_avatar', gr.avatar_path,
      'requested_s', r.requested_s, 'accepted_s', r.accepted_s, 'picked_s', r.picked_s,
      'lat', extensions.st_y(pos.geom::extensions.geometry), 'lng', extensions.st_x(pos.geom::extensions.geometry),
      'position_s', pos.game_s) end,
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'granny_name', wg.name, 'requested_s', w.requested_s) order by w.requested_at)
      from public.taxi_requests w join public.grannies wg on wg.id = w.granny_id
      where w.game_id = g.id and w.status = 'waiting'), '[]'::jsonb),
    'busy', (select count(*) from public.taxi_requests b where b.game_id = g.id and b.status in ('accepted', 'picked_up'))::int
  );
end
$$;

-- Sjåføren tar alltid den som har ventet lengst.
create or replace function public.taxi_accept_next()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('taxi');
  g  public.games;
  s  int;
  r  public.taxi_requests;
  tx public.taxis;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  if exists (select 1 from public.taxi_requests where taxi_id = p.taxi_id and status in ('accepted', 'picked_up')) then
    raise exception 'Kjør ferdig turen du har først' using errcode = 'P0001';
  end if;
  select * into r from public.taxi_requests
   where game_id = g.id and status = 'waiting'
   order by requested_at limit 1 for update skip locked;
  if r.id is null then raise exception 'Ingen venter på taxi' using errcode = 'P0001'; end if;

  s := public.game_seconds(g);
  select * into tx from public.taxis where id = p.taxi_id;
  update public.taxi_requests set status = 'accepted', taxi_id = p.taxi_id, accepted_s = s where id = r.id;
  perform public._emit(g.id, s, 'granny', 'taxi_accepted', format('%s kommer og henter deg.', tx.name),
    'Bli der du er, eller ring sjåføren.', p_granny => r.granny_id);
  return jsonb_build_object('id', r.id);
end
$$;

-- Sjåføren gir fra seg turen. Grannyen havner først i køen igjen.
create or replace function public.taxi_release()
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('taxi');
  r public.taxi_requests;
  g public.games;
begin
  select * into r from public.taxi_requests where taxi_id = p.taxi_id and status = 'accepted' for update;
  if r.id is null then raise exception 'Du har ingen tur å gi fra deg' using errcode = 'P0001'; end if;
  select * into g from public.games where id = r.game_id;
  update public.taxi_requests set status = 'waiting', taxi_id = null, accepted_s = null where id = r.id;
  perform public._emit(g.id, public.game_seconds(g), 'granny', 'taxi_released', 'Taxien kom ikke.',
    'Du står fortsatt i køen.', p_granny => r.granny_id);
  perform public._emit(g.id, public.game_seconds(g), 'taxis', 'taxi_request', 'En granny venter på taxi.', 'Ta turen i appen.');
end
$$;

create or replace function public.taxi_pickup(p_lat double precision default null, p_lng double precision default null, p_accuracy real default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('taxi');
  g  public.games;
  s  int;
  r  public.taxi_requests;
  at extensions.geography;
  gpos public.positions;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  select * into r from public.taxi_requests where taxi_id = p.taxi_id and status = 'accepted' for update;
  if r.id is null then raise exception 'Du har ingen granny å hente' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  perform public._record_position(p, p_lat, p_lng, p_accuracy);

  -- Hentestedet: sjåførens posisjon, ellers grannyens siste.
  if p_lat is not null and p_lng is not null then
    at := public._point(p_lat, p_lng);
  else
    gpos := public.granny_position_at(r.granny_id, s);
    at := gpos.geom;
  end if;

  update public.taxi_requests set status = 'picked_up', picked_s = s, pickup = at where id = r.id;
  insert into public.taxi_rides (game_id, granny_id, at_s) values (g.id, r.granny_id, s);
  perform public._emit(g.id, s, 'teams', 'taxi', 'En granny har tatt taxi.',
    case when at is null then null else 'Hentestedet vises på kartet.' end,
    p_data => case when at is null then null else jsonb_build_object(
      'lat', extensions.st_y(at::extensions.geometry), 'lng', extensions.st_x(at::extensions.geometry)) end);
end
$$;

create or replace function public.taxi_dropoff()
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('taxi');
  g public.games;
  r public.taxi_requests;
begin
  select * into g from public.games where id = p.game_id;
  select * into r from public.taxi_requests where taxi_id = p.taxi_id and status = 'picked_up' for update;
  if r.id is null then raise exception 'Du har ingen granny i bilen' using errcode = 'P0001'; end if;
  update public.taxi_requests set status = 'done', done_s = public.game_seconds(g) where id = r.id;
end
$$;

-- Taxiene på kartet: grannies ser dem hele tiden (siste 5 min).
create or replace function public._taxi_markers(p_game uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind', 'taxi', 'id', tx.id, 'name', tx.name, 'live_reason', null,
    'lat', extensions.st_y(lp.geom::extensions.geometry), 'lng', extensions.st_x(lp.geom::extensions.geometry),
    'accuracy_m', lp.accuracy_m, 'at_s', lp.game_s, 'age_s', extract(epoch from now() - lp.recorded_at)::int,
    'busy', exists (select 1 from public.taxi_requests r where r.taxi_id = tx.id and r.status in ('accepted', 'picked_up'))
  ) order by tx.name), '[]'::jsonb)
  from public.taxis tx
  join lateral (
    select * from public.positions where taxi_id = tx.id order by recorded_at desc, id desc limit 1
  ) lp on true
  where tx.game_id = p_game and lp.recorded_at > now() - interval '5 minutes'
$$;

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
  return jsonb_build_object('game_s', s, 'markers', public._snitch_markers(g.id, s) || public._taxi_markers(g.id));
end
$$;

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
  last_album int;
  album_pending boolean;
  r  public.taxi_requests;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id;
  s := public.game_seconds(g);
  select max(submitted_s), bool_or(status = 'pending') into last_album, album_pending
    from public.photos where granny_id = gr.id and kind = 'fotoalbum' and status <> 'rejected';
  select * into r from public.taxi_requests where granny_id = gr.id and status in ('waiting', 'accepted', 'picked_up');

  return jsonb_build_object(
    'game_s', s,
    'points', coalesce((select sum(delta) from public.points_ledger where granny_id = gr.id), 0),
    'taxi_rides', public._taxi_rides_used(gr.id),
    'taxi_max_rides', coalesce((g.rules->>'taxi_max_rides')::int, 1),
    'taxi_request', case when r.id is null then null else jsonb_build_object(
      'status', r.status,
      'taxi_name', (select name from public.taxis where id = r.taxi_id),
      'queue_position', case when r.status = 'waiting' then (
        select count(*) from public.taxi_requests q
        where q.game_id = g.id and q.status = 'waiting' and q.requested_at <= r.requested_at)::int end) end,
    'taxis', (select count(*) from public.taxis where game_id = g.id)::int,
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

-- ---------------------------------------------------------------------------
-- Lagets kart: evnen «se granny live» og hentestedet for taxi
-- ---------------------------------------------------------------------------
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
  ability_s int;
  pickup_s int;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'team' then
    raise exception 'Bare for lag' using errcode = '42501';
  end if;
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id;
  s := public.game_seconds(g);
  ping := public.last_ping_s(g, s);
  ability_s := coalesce((g.rules->>'ability_live_s')::int, 60);
  pickup_s := coalesce((g.rules->>'taxi_pickup_show_s')::int, 600);

  select max(until_s) into blind_until from public.blinds where team_id = t.id and from_s <= s and until_s > s;
  if blind_until is not null then
    return jsonb_build_object('game_s', s, 'ping_s', ping, 'blind_until_s', blind_until, 'markers', '[]'::jsonb);
  end if;

  for gr in select * from public.grannies where game_id = g.id order by name loop
    continue when gr.caught_at_s is not null and gr.caught_at_s <= s;
    continue when gr.is_romling and s < g.romling_reveal_s;

    live := case when gr.is_romling then null else coalesce(
      public.granny_live_reason(gr.id, s),
      case when exists (select 1 from public.team_abilities a
                        where a.team_id = t.id and a.target_granny_id = gr.id
                          and a.used_s <= s and s < a.used_s + ability_s) then 'evne' end) end;
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

  -- Hentesteder for taxi, uten navn.
  markers := markers || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'taxi', 'id', null, 'name', null, 'live_reason', null,
      'lat', extensions.st_y(r.pickup::extensions.geometry), 'lng', extensions.st_x(r.pickup::extensions.geometry),
      'accuracy_m', null, 'at_s', r.picked_s, 'age_s', s - r.picked_s))
    from public.taxi_requests r
    where r.game_id = g.id and r.pickup is not null and r.picked_s <= s and s < r.picked_s + pickup_s
      and not public._team_blind_at(t.id, r.picked_s)), '[]'::jsonb);

  markers := markers || public._snitch_markers(g.id, s);
  return jsonb_build_object('game_s', s, 'ping_s', ping, 'blind_until_s', null, 'markers', markers);
end
$$;

-- ---------------------------------------------------------------------------
-- Side quests og evner
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_quest(
  p_id uuid, p_title text, p_description text, p_points int, p_abilities int, p_team uuid default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
  qid uuid;
  t public.teams;
begin
  select * into g from public.games where id = p.game_id;
  if length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Skriv en tittel' using errcode = 'P0001'; end if;
  if coalesce(p_points, 0) < 0 or coalesce(p_abilities, 0) < 0 then raise exception 'Belønningen kan ikke være negativ' using errcode = 'P0001'; end if;
  if coalesce(p_points, 0) = 0 and coalesce(p_abilities, 0) = 0 then raise exception 'Gi poeng, en evne eller begge' using errcode = 'P0001'; end if;
  if p_team is not null then
    select * into t from public.teams where id = p_team and game_id = g.id;
    if t.id is null then raise exception 'Ukjent lag' using errcode = 'P0002'; end if;
  end if;

  if p_id is null then
    insert into public.quests (game_id, title, description, reward_points, reward_abilities, team_id)
    values (g.id, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), coalesce(p_points, 0), coalesce(p_abilities, 0), p_team)
    returning id into qid;
    if g.status in ('running', 'paused') then
      perform public._emit(g.id, public.game_seconds(g), case when p_team is null then 'teams' else 'team' end,
        'quest_new', format('Ny side quest: %s', trim(p_title)), 'Se oppdraget under «Quests».', p_team => p_team);
    end if;
  else
    update public.quests set title = trim(p_title), description = nullif(trim(coalesce(p_description, '')), ''),
           reward_points = coalesce(p_points, 0), reward_abilities = coalesce(p_abilities, 0), team_id = p_team
     where id = p_id and game_id = g.id returning id into qid;
    if qid is null then raise exception 'Fant ikke oppdraget' using errcode = 'P0002'; end if;
  end if;
  return qid;
end
$$;

create or replace function public.admin_close_quest(p_id uuid, p_closed boolean)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
begin
  update public.quests set closed = p_closed where id = p_id and game_id = p.game_id;
  if not found then raise exception 'Fant ikke oppdraget' using errcode = 'P0002'; end if;
end
$$;

create or replace function public.admin_quests()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'title', q.title, 'description', q.description,
      'reward_points', q.reward_points, 'reward_abilities', q.reward_abilities,
      'team_id', q.team_id, 'team_name', t.name, 'closed', q.closed,
      'pending', (select count(*) from public.quest_submissions s where s.quest_id = q.id and s.status = 'pending')::int,
      'approved_teams', coalesce((select jsonb_agg(tt.name order by s.submitted_at) from public.quest_submissions s
                                  join public.teams tt on tt.id = s.team_id
                                  where s.quest_id = q.id and s.status = 'approved'), '[]'::jsonb)
    ) order by q.closed, q.created_at desc)
    from public.quests q left join public.teams t on t.id = q.team_id
    where q.game_id = p.game_id), '[]'::jsonb);
end
$$;

create or replace function public.admin_quest_queue()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'quest_id', q.id, 'quest_title', q.title, 'quest_description', q.description,
      'reward_points', q.reward_points, 'reward_abilities', q.reward_abilities,
      'team_id', t.id, 'team_name', t.name, 'team_color', t.color,
      'storage_path', s.storage_path, 'media', s.media,
      'submitted_s', s.submitted_s, 'submitted_at', s.submitted_at
    ) order by s.submitted_at)
    from public.quest_submissions s
    join public.quests q on q.id = s.quest_id
    join public.teams t on t.id = s.team_id
    where s.game_id = p.game_id and s.status = 'pending'), '[]'::jsonb);
end
$$;

create or replace function public.admin_review_quest(p_submission uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('admin');
  g  public.games;
  sb public.quest_submissions;
  q  public.quests;
  s  int;
  reward text;
begin
  select * into g from public.games where id = p.game_id;
  select * into sb from public.quest_submissions where id = p_submission and game_id = g.id for update;
  if sb.id is null then raise exception 'Fant ikke innsendingen' using errcode = 'P0002'; end if;
  if sb.status <> 'pending' then raise exception 'Innsendingen er allerede behandlet' using errcode = 'P0001'; end if;
  select * into q from public.quests where id = sb.quest_id;
  s := public.game_seconds(g);

  if not p_approve then
    update public.quest_submissions set status = 'rejected', note = nullif(trim(coalesce(p_note, '')), ''), reviewed_at = now()
     where id = sb.id;
    perform public._emit(g.id, s, 'team', 'quest_rejected', format('«%s» ble ikke godkjent.', q.title),
      coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Prøv igjen.'), p_team => sb.team_id);
    return;
  end if;

  update public.quest_submissions set status = 'approved', reviewed_at = now() where id = sb.id;
  if q.reward_points > 0 then
    insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s, created_by)
    values (g.id, sb.team_id, q.reward_points, 'side_quest', sb.id, s, 'admin');
  end if;
  insert into public.team_abilities (game_id, team_id, submission_id, granted_s)
  select g.id, sb.team_id, sb.id, s from generate_series(1, q.reward_abilities);

  reward := concat_ws(' og ',
    case when q.reward_points > 0 then format('%sp', q.reward_points) end,
    case when q.reward_abilities = 1 then '1 «se granny live»'
         when q.reward_abilities > 1 then format('%s «se granny live»', q.reward_abilities) end);
  perform public._emit(g.id, s, 'team', 'quest_approved', format('«%s» er godkjent!', q.title),
    format('Dere får %s.', reward), p_team => sb.team_id);
end
$$;

create or replace function public.team_quests()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('team');
  g public.games;
begin
  select * into g from public.games where id = p.game_id;
  return jsonb_build_object(
    'abilities_left', (select count(*) from public.team_abilities where team_id = p.team_id and used_s is null)::int,
    'ability_live_s', coalesce((g.rules->>'ability_live_s')::int, 60),
    'quests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id, 'title', q.title, 'description', q.description,
        'reward_points', q.reward_points, 'reward_abilities', q.reward_abilities,
        'closed', q.closed,
        'status', (select s.status from public.quest_submissions s where s.quest_id = q.id and s.team_id = p.team_id
                   order by s.submitted_at desc limit 1),
        'note', (select s.note from public.quest_submissions s where s.quest_id = q.id and s.team_id = p.team_id
                 order by s.submitted_at desc limit 1)
      ) order by q.closed, q.created_at desc)
      from public.quests q
      where q.game_id = g.id and (q.team_id is null or q.team_id = p.team_id)
        and (not q.closed or exists (select 1 from public.quest_submissions s where s.quest_id = q.id and s.team_id = p.team_id))
    ), '[]'::jsonb)
  );
end
$$;

create or replace function public.submit_quest(p_quest uuid, p_path text, p_media text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('team');
  g public.games;
  q public.quests;
  t public.teams;
  s int;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  if p_media not in ('image', 'video') then raise exception 'Ukjent filtype' using errcode = '22023'; end if;
  perform public._check_path(p, p_path, 'quest-');
  select * into q from public.quests where id = p_quest and game_id = g.id;
  if q.id is null or (q.team_id is not null and q.team_id <> p.team_id) then
    raise exception 'Fant ikke oppdraget' using errcode = 'P0002';
  end if;
  if q.closed then raise exception 'Oppdraget er stengt' using errcode = 'P0001'; end if;
  if exists (select 1 from public.quest_submissions where quest_id = q.id and team_id = p.team_id and status in ('pending', 'approved')) then
    raise exception 'Dere har allerede sendt inn dette oppdraget' using errcode = 'P0001';
  end if;

  s := public.game_seconds(g);
  select * into t from public.teams where id = p.team_id;
  insert into public.quest_submissions (game_id, quest_id, team_id, storage_path, media, submitted_s)
  values (g.id, q.id, p.team_id, p_path, p_media, s);
  perform public._emit(g.id, s, 'admin', 'quest_pending', format('%s har løst «%s».', t.name, q.title), 'Godkjenn i appen.');
end
$$;

create or replace function public.team_use_ability(p_granny uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('team');
  g  public.games;
  t  public.teams;
  gr public.grannies;
  a  public.team_abilities;
  s  int;
  secs int;
  dur text;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  if public._team_blind_at(p.team_id, s) then raise exception 'Dere er blinde' using errcode = 'P0001'; end if;
  select * into gr from public.grannies where id = p_granny and game_id = g.id;
  if gr.id is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  if gr.is_romling then raise exception 'Rømlingen kan ikke vises' using errcode = 'P0001'; end if;
  if gr.caught_at_s is not null then raise exception '% er allerede fanget', gr.name using errcode = 'P0001'; end if;

  select * into a from public.team_abilities
   where team_id = p.team_id and used_s is null order by granted_s limit 1 for update skip locked;
  if a.id is null then raise exception 'Dere har ingen evner igjen' using errcode = 'P0001'; end if;

  secs := coalesce((g.rules->>'ability_live_s')::int, 60);
  dur := case when secs % 60 = 0 then format('%s min', secs / 60) else format('%s sek', secs) end;
  select * into t from public.teams where id = p.team_id;
  update public.team_abilities set used_s = s, target_granny_id = gr.id where id = a.id;
  perform public._emit(g.id, s, 'team', 'ability_used', format('Dere ser %s live i %s.', gr.name, dur), null, p_team => t.id);
  perform public._emit(g.id, s, 'granny', 'ability_target', format('Et lag ser deg live i %s.', dur),
    'Kom deg videre!', p_granny => gr.id);
end
$$;

-- ---------------------------------------------------------------------------
-- Spilleder: taxier, oppsett, live og omstart
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_taxi(p_id uuid, p_name text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  tid uuid;
begin
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Skriv et navn'; end if;
  if p_id is null then
    insert into public.taxis (game_id, name) values (p.game_id, trim(p_name)) returning id into tid;
    insert into public.join_codes (code, game_id, role, taxi_id) values (public._random_code('T'), p.game_id, 'taxi', tid);
  else
    update public.taxis set name = trim(p_name) where id = p_id and game_id = p.game_id returning id into tid;
    if tid is null then raise exception 'Fant ikke taxien' using errcode = 'P0002'; end if;
  end if;
  return tid;
end
$$;

create or replace function public.admin_delete(p_kind text, p_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(p_kind not in ('zone', 'taxi', 'quest'));
begin
  case p_kind
    when 'granny' then delete from public.grannies where id = p_id and game_id = g.id;
    when 'team'   then delete from public.teams where id = p_id and game_id = g.id;
    when 'zone'   then delete from public.zones where id = p_id and game_id = g.id;
    when 'taxi'   then delete from public.taxis where id = p_id and game_id = g.id;
    when 'quest'  then delete from public.quests where id = p_id and game_id = g.id;
    else raise exception 'Ukjent type';
  end case;
end
$$;

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
        'avatar_path', gr.avatar_path,
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
    'taxis', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name,
        'code', (select code from public.join_codes jc where jc.taxi_id = x.id limit 1),
        'phones', (select count(*) from public.players pl where pl.taxi_id = x.id)) order by x.name)
      from public.taxis x where x.game_id = g.id), '[]'::jsonb),
    'admin_codes', coalesce((select jsonb_agg(code) from public.join_codes where game_id = g.id and role = 'admin'), '[]'::jsonb),
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'kind', z.kind, 'number', z.number, 'label', z.label,
        'radius_m', z.radius_m, 'opens_at_s', z.opens_at_s, 'closes_at_s', z.closes_at_s, 'mission', z.mission,
        'geojson', extensions.st_asgeojson(z.geom)::jsonb) order by z.kind, z.number)
      from public.zones z where z.game_id = g.id), '[]'::jsonb)
  );
end
$$;

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
    ), '[]'::jsonb),
    'taxis', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', x.id, 'name', x.name,
        'phones', (select count(*) from public.players pl where pl.taxi_id = x.id),
        'lat', extensions.st_y(lp.geom::extensions.geometry),
        'lng', extensions.st_x(lp.geom::extensions.geometry),
        'age_s', extract(epoch from now() - lp.recorded_at)::int,
        'ride', (select jsonb_build_object('status', r.status, 'granny_name', rg.name)
                 from public.taxi_requests r join public.grannies rg on rg.id = r.granny_id
                 where r.taxi_id = x.id and r.status in ('accepted', 'picked_up'))
      ) order by x.name)
      from public.taxis x
      left join lateral (
        select * from public.positions where taxi_id = x.id order by recorded_at desc, id desc limit 1
      ) lp on true
      where x.game_id = g.id
    ), '[]'::jsonb),
    'taxi_waiting', coalesce((
      select jsonb_agg(wg.name order by w.requested_at)
      from public.taxi_requests w join public.grannies wg on wg.id = w.granny_id
      where w.game_id = g.id and w.status = 'waiting'), '[]'::jsonb)
  );
end
$$;

create or replace function public.admin_reset_game()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
begin
  select * into g from public.games where id = p.game_id for update;
  if g.status <> 'ended' then
    raise exception 'Avslutt spillet før du starter det på nytt' using errcode = 'P0001';
  end if;

  delete from public.events            where game_id = g.id;
  delete from public.points_ledger     where game_id = g.id;
  delete from public.blinds            where game_id = g.id;
  delete from public.photos            where game_id = g.id;
  delete from public.catches           where game_id = g.id;
  delete from public.snitches          where game_id = g.id;
  delete from public.taxi_rides        where game_id = g.id;
  delete from public.taxi_requests     where game_id = g.id;
  delete from public.nabovakt_checkins where game_id = g.id;
  delete from public.romling_attempts  where game_id = g.id;
  delete from public.reveals           where game_id = g.id;
  delete from public.team_abilities    where game_id = g.id;
  delete from public.quest_submissions where game_id = g.id;
  delete from public.positions         where game_id = g.id;

  update public.grannies set caught_at_s = null, caught_by = null, catch_order = null where game_id = g.id;
  update public.teams set license_at_s = null where game_id = g.id;
  update public.games
     set status = 'setup', started_at = null, paused_at = null, ended_at = null, paused_total = interval '0'
   where id = g.id;

  return public.game_state();
end
$$;

-- ---------------------------------------------------------------------------
-- Tilganger
-- ---------------------------------------------------------------------------
revoke execute on function
  public._check_path(public.players, text, text), public._taxi_rides_used(uuid), public._taxi_markers(uuid),
  public.granny_set_avatar(text), public.admin_set_avatar(uuid, text),
  public.register_catch(uuid, text),
  public.granny_request_taxi(double precision, double precision, real), public.granny_cancel_taxi(),
  public.taxi_queue(), public.taxi_accept_next(), public.taxi_release(),
  public.taxi_pickup(double precision, double precision, real), public.taxi_dropoff(),
  public.admin_save_quest(uuid, text, text, int, int, uuid), public.admin_close_quest(uuid, boolean),
  public.admin_quests(), public.admin_quest_queue(), public.admin_review_quest(uuid, boolean, text),
  public.team_quests(), public.submit_quest(uuid, text, text), public.team_use_ability(uuid),
  public.admin_save_taxi(uuid, text)
from public, anon, authenticated;

grant execute on function
  public.granny_set_avatar(text), public.admin_set_avatar(uuid, text),
  public.register_catch(uuid, text),
  public.granny_request_taxi(double precision, double precision, real), public.granny_cancel_taxi(),
  public.taxi_queue(), public.taxi_accept_next(), public.taxi_release(),
  public.taxi_pickup(double precision, double precision, real), public.taxi_dropoff(),
  public.admin_save_quest(uuid, text, text, int, int, uuid), public.admin_close_quest(uuid, boolean),
  public.admin_quests(), public.admin_quest_queue(), public.admin_review_quest(uuid, boolean, text),
  public.team_quests(), public.submit_quest(uuid, text, text), public.team_use_ability(uuid),
  public.admin_save_taxi(uuid, text)
to authenticated;
