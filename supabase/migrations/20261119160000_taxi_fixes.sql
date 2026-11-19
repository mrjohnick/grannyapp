-- Taxi: kanttilfeller funnet i gjennomgangen 19.11.
--  1. En taxi som slettes midt i en tur, låser ikke lenger grannyen.
--  2. Sjåfør som ikke sender posisjon: varsel, så gis turen videre (tick_taxis).
--  3. Spilleder kan avbryte, gi videre, angre henting og gi ekstra tur.
--  4. (appen) Grannyen ser om noen taxi er på nett før hun bestiller.
--  5. Sjåføren ser hvor gammel grannyens posisjon er, og får beskjed når
--     turen forsvinner fordi hun ble fanget.

-- ---------------------------------------------------------------------------
-- Varsler til én bestemt taxi
-- ---------------------------------------------------------------------------
alter table public.events add column taxi_id uuid references public.taxis on delete cascade;
alter table public.events drop constraint events_audience_check;
alter table public.events add constraint events_audience_check
  check (audience in ('all', 'teams', 'grannies', 'team', 'granny', 'admin', 'taxis', 'taxi'));
alter table public.events add constraint events_taxi_check check (audience <> 'taxi' or taxi_id is not null);

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
    when e.audience = 'taxi' then p.taxi_id = e.taxi_id
    else false
  end
$$;

create or replace function public._emit_taxi(p_game uuid, p_s int, p_taxi uuid, p_kind text, p_title text, p_body text default null)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.events (game_id, at_s, audience, taxi_id, kind, title, body)
  values (p_game, p_s, 'taxi', p_taxi, p_kind, p_title, p_body)
$$;

-- ---------------------------------------------------------------------------
-- Regler og nye kolonner
-- ---------------------------------------------------------------------------
alter table public.games
  alter column rules set default '{
    "snitch_live_s": 60,
    "snitch_bonus_window_s": 600,
    "blind_s": 600,
    "reblind_cooldown_s": 900,
    "taxi_max_rides": 1,
    "taxi_pickup_show_s": 600,
    "taxi_driver_timeout_s": 300,
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
update public.games set rules = '{"taxi_driver_timeout_s": 300}'::jsonb || rules;

-- Ekstra turer fra spilleder, i tillegg til taxi_max_rides.
alter table public.grannies add column taxi_extra_rides int not null default 0 check (taxi_extra_rides >= 0);
-- Sjåføren er varslet om at turen snart gis videre.
alter table public.taxi_requests add column warned boolean not null default false;

-- Brukte turer minus ekstra turer. Resten av koden sammenligner med
-- taxi_max_rides, så ekstra turer virker overalt uten flere endringer.
create or replace function public._taxi_rides_used(p_granny uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select (select count(*)::int from public.taxi_rides where granny_id = p_granny)
       - coalesce((select taxi_extra_rides from public.grannies where id = p_granny), 0)
$$;

-- ---------------------------------------------------------------------------
-- Felles: gi en tur tilbake til køen, og frigjør en taxi
-- ---------------------------------------------------------------------------

-- Grannyen beholder plassen sin i køen (requested_at endres ikke).
create or replace function public._taxi_requeue(r public.taxi_requests, p_granny_title text, p_granny_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  g  public.games;
  gr public.grannies;
  s  int;
begin
  select * into g from public.games where id = r.game_id;
  select * into gr from public.grannies where id = r.granny_id;
  s := public.game_seconds(g);
  update public.taxi_requests set status = 'waiting', taxi_id = null, accepted_s = null, warned = false where id = r.id;
  perform public._emit(g.id, s, 'granny', 'taxi_released', p_granny_title, p_granny_body, p_granny => gr.id);
  perform public._emit(g.id, s, 'taxis', 'taxi_request', format('%s venter på taxi.', gr.name), 'Ta turen i appen.');
end
$$;

-- Før en taxi slettes: turen den er på vei til går tilbake i køen, og en
-- granny som sitter i bilen regnes som levert.
create or replace function public._taxi_free(p_taxi uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.taxi_requests;
  g public.games;
begin
  for r in select * from public.taxi_requests where taxi_id = p_taxi and status in ('accepted', 'picked_up') for update loop
    if r.status = 'accepted' then
      perform public._taxi_requeue(r, 'Taxien din er tatt ut av spillet.', 'Du står først i køen igjen.');
    else
      select * into g from public.games where id = r.game_id;
      update public.taxi_requests set status = 'done', done_s = public.game_seconds(g) where id = r.id;
    end if;
  end loop;
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
    when 'taxi'   then
      if exists (select 1 from public.taxis where id = p_id and game_id = g.id) then
        perform public._taxi_free(p_id);
      end if;
      delete from public.taxis where id = p_id and game_id = g.id;
    when 'quest'  then delete from public.quests where id = p_id and game_id = g.id;
    else raise exception 'Ukjent type';
  end case;
end
$$;

-- ---------------------------------------------------------------------------
-- Sjåfør som ikke svarer (kjøres av pg_cron hvert 20. sekund)
-- ---------------------------------------------------------------------------
-- «Stille» = spilltid siden siste posisjon fra taxien, men tidligst fra da
-- turen ble tatt. Halvveis: varsel til sjåføren. Ved grensen: turen gis videre.
create or replace function public.tick_taxis()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  g  public.games;
  r  public.taxi_requests;
  gr public.grannies;
  s  int;
  timeout int;
  quiet int;
  n  int := 0;
begin
  for g in select * from public.games where status = 'running' loop
    s := public.game_seconds(g);
    timeout := coalesce((g.rules->>'taxi_driver_timeout_s')::int, 300);
    if timeout <= 0 then continue; end if;

    for r in select * from public.taxi_requests where game_id = g.id and status = 'accepted' and taxi_id is not null for update skip locked loop
      quiet := s - greatest(r.accepted_s,
        coalesce((select max(game_s) from public.positions where taxi_id = r.taxi_id), r.accepted_s));
      select * into gr from public.grannies where id = r.granny_id;

      if quiet >= timeout then
        perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_timeout', format('Turen til %s er gitt videre.', gr.name),
          format('Appen sendte ikke posisjonen din på %s min.', timeout / 60));
        perform public._taxi_requeue(r, 'Taxien svarer ikke.', 'Du står først i køen igjen.');
        n := n + 1;
      elsif quiet >= timeout / 2 and not r.warned then
        update public.taxi_requests set warned = true where id = r.id;
        perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_warning', 'Åpne taxi-appen!',
          format('Ellers går turen til %s videre til en annen taxi om %s min.', gr.name, greatest(1, (timeout - quiet) / 60)));
      elsif quiet < timeout / 2 and r.warned then
        update public.taxi_requests set warned = false where id = r.id;
      end if;
    end loop;
  end loop;
  return n;
end
$$;

select cron.schedule('granny-taxi', '20 seconds', 'select public.tick_taxis()');

-- ---------------------------------------------------------------------------
-- Beskjed til riktig sjåfør
-- ---------------------------------------------------------------------------
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
    perform public._emit_taxi(g.id, public.game_seconds(g), r.taxi_id, 'taxi_cancelled', format('%s avbestilte taxien.', gr.name));
  end if;
end
$$;

-- Fangst avbryter en tur som er på vei (finalize_catch). Si fra til sjåføren.
create or replace function public.tg_taxi_request_caught()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  gr public.grannies;
  g  public.games;
begin
  select * into gr from public.grannies where id = new.granny_id;
  if gr.caught_at_s is null then return new; end if;
  select * into g from public.games where id = new.game_id;
  perform public._emit_taxi(g.id, public.game_seconds(g), old.taxi_id, 'taxi_cancelled',
    format('%s er fanget.', gr.name), 'Turen er avbrutt.');
  return new;
end
$$;

create trigger taxi_request_caught
  after update of status on public.taxi_requests
  for each row
  when (old.status = 'accepted' and new.status = 'cancelled' and old.taxi_id is not null)
  execute function public.tg_taxi_request_caught();

-- Sjåføren ser hvor gammel grannyens posisjon er (position_age_s).
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
    'timeout_s', coalesce((g.rules->>'taxi_driver_timeout_s')::int, 300),
    'taxi', (select jsonb_build_object('id', id, 'name', name) from public.taxis where id = p.taxi_id),
    'active', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'status', r.status, 'granny_name', gr.name, 'granny_avatar', gr.avatar_path,
      'requested_s', r.requested_s, 'accepted_s', r.accepted_s, 'picked_s', r.picked_s,
      'lat', extensions.st_y(pos.geom::extensions.geometry), 'lng', extensions.st_x(pos.geom::extensions.geometry),
      'position_s', pos.game_s,
      'position_age_s', case when pos.game_s is null then null else greatest(0, s - pos.game_s) end) end,
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'granny_name', wg.name, 'requested_s', w.requested_s) order by w.requested_at)
      from public.taxi_requests w join public.grannies wg on wg.id = w.granny_id
      where w.game_id = g.id and w.status = 'waiting'), '[]'::jsonb),
    'busy', (select count(*) from public.taxi_requests b where b.game_id = g.id and b.status in ('accepted', 'picked_up'))::int
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Spilleder
-- ---------------------------------------------------------------------------
create or replace function public.admin_taxi_overview()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
  s int;
begin
  select * into g from public.games where id = p.game_id;
  s := public.game_seconds(g);
  return jsonb_build_object(
    'max_rides', coalesce((g.rules->>'taxi_max_rides')::int, 1),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'granny_id', r.granny_id, 'granny_name', gr.name,
        'taxi_id', r.taxi_id, 'taxi_name', tx.name,
        'requested_s', r.requested_s, 'accepted_s', r.accepted_s, 'picked_s', r.picked_s,
        'driver_quiet_s', case when r.status = 'accepted' then s - greatest(r.accepted_s,
          coalesce((select max(game_s) from public.positions where taxi_id = r.taxi_id), r.accepted_s)) end
      ) order by r.requested_at)
      from public.taxi_requests r
      join public.grannies gr on gr.id = r.granny_id
      left join public.taxis tx on tx.id = r.taxi_id
      where r.game_id = g.id and r.status in ('waiting', 'accepted', 'picked_up')), '[]'::jsonb),
    'grannies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', gr.id, 'name', gr.name, 'is_romling', gr.is_romling, 'caught', gr.caught_at_s is not null,
        'rides', (select count(*) from public.taxi_rides x where x.granny_id = gr.id),
        'extra', gr.taxi_extra_rides) order by gr.name)
      from public.grannies gr where gr.game_id = g.id), '[]'::jsonb),
    'online', coalesce((select jsonb_agg(m->>'id') from jsonb_array_elements(public._taxi_markers(g.id)) m), '[]'::jsonb)
  );
end
$$;

-- p_action: 'cancel' (avbryt), 'requeue' (gi videre til en annen taxi) eller 'undo_pickup' (angre henting).
create or replace function public.admin_taxi_action(p_request uuid, p_action text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('admin');
  g  public.games;
  r  public.taxi_requests;
  gr public.grannies;
  s  int;
  ride uuid;
begin
  select * into g from public.games where id = p.game_id;
  select * into r from public.taxi_requests where id = p_request and game_id = g.id for update;
  if r.id is null then raise exception 'Fant ikke turen' using errcode = 'P0002'; end if;
  select * into gr from public.grannies where id = r.granny_id;
  s := public.game_seconds(g);

  if p_action = 'cancel' then
    if r.status not in ('waiting', 'accepted', 'picked_up') then raise exception 'Turen er allerede avsluttet' using errcode = 'P0001'; end if;
    if r.status = 'picked_up' then
      update public.taxi_requests set status = 'done', done_s = s where id = r.id;
    else
      update public.taxi_requests set status = 'cancelled' where id = r.id;
    end if;
    perform public._emit(g.id, s, 'granny', 'taxi_cancelled', 'Spilleder avsluttet taxituren.', null, p_granny => gr.id);
    if r.taxi_id is not null then
      perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_cancelled', format('Spilleder avsluttet turen til %s.', gr.name));
    end if;

  elsif p_action = 'requeue' then
    if r.status <> 'accepted' then raise exception 'Bare en tur som er på vei, kan gis videre' using errcode = 'P0001'; end if;
    perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_cancelled', format('Spilleder ga turen til %s videre.', gr.name));
    perform public._taxi_requeue(r, 'Spilleder sender en annen taxi.', 'Du står først i køen igjen.');

  elsif p_action = 'undo_pickup' then
    if r.status <> 'picked_up' then raise exception 'Hun er ikke hentet' using errcode = 'P0001'; end if;
    select id into ride from public.taxi_rides where granny_id = r.granny_id and at_s = r.picked_s limit 1;
    delete from public.taxi_rides where id = ride;
    update public.taxi_requests set status = 'accepted', picked_s = null, pickup = null, warned = false where id = r.id;
    perform public._emit(g.id, s, 'granny', 'taxi_accepted', 'Hentingen er angret.', 'Taxituren din er ikke brukt opp. Taxien kommer fortsatt.', p_granny => gr.id);
    perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_cancelled', format('Spilleder angret hentingen av %s.', gr.name),
      'Trykk «Hentet» når hun faktisk sitter i bilen.');
    perform public._emit(g.id, s, 'teams', 'message', 'Se bort fra forrige taxivarsel.', 'Hentestedet er fjernet fra kartet.');

  else
    raise exception 'Ukjent handling' using errcode = '22023';
  end if;
end
$$;

-- Gi (eller ta tilbake) ekstra taxiturer for én granny.
create or replace function public.admin_taxi_extra_ride(p_granny uuid, p_delta int)
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('admin');
  g  public.games;
  gr public.grannies;
begin
  select * into g from public.games where id = p.game_id;
  update public.grannies set taxi_extra_rides = greatest(0, taxi_extra_rides + p_delta)
   where id = p_granny and game_id = g.id
  returning * into gr;
  if gr.id is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  if p_delta > 0 and g.status in ('running', 'paused') then
    perform public._emit(g.id, public.game_seconds(g), 'granny', 'message', 'Du har fått en ekstra taxitur.', null, p_granny => gr.id);
  end if;
  return gr.taxi_extra_rides;
end
$$;

-- Ny runde: ekstra turer nullstilles også (admin_reset_game rydder resten).
create or replace function public.tg_reset_taxi_extra()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.status = 'ended' and new.status = 'setup' then
    update public.grannies set taxi_extra_rides = 0 where game_id = new.id;
  end if;
  return new;
end
$$;

create trigger games_reset_taxi_extra
  after update of status on public.games
  for each row execute function public.tg_reset_taxi_extra();

-- ---------------------------------------------------------------------------
-- Tilgang
-- ---------------------------------------------------------------------------
revoke execute on function
  public._emit_taxi(uuid, int, uuid, text, text, text), public._taxi_requeue(public.taxi_requests, text, text),
  public._taxi_free(uuid), public.tick_taxis(), public.tg_taxi_request_caught(), public.tg_reset_taxi_extra(),
  public.admin_taxi_overview(), public.admin_taxi_action(uuid, text), public.admin_taxi_extra_ride(uuid, int)
from public, anon, authenticated;

grant execute on function
  public.admin_taxi_overview(), public.admin_taxi_action(uuid, text), public.admin_taxi_extra_ride(uuid, int)
to authenticated;
