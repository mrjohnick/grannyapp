-- Endringer 19.11:
--  * Rømlingen og forspranget er tatt ut av spillet. Logikken for Rømlingen
--    ligger igjen i databasen, men appen lar deg ikke lage en, og forspranget
--    er 0. Det gjør at lagene kan jakte fra første sekund.
--  * Bonus-grannyer (uten eget lag) har egne ping-tider (bonus_ping_schedule_s).
--    Tom liste betyr samme tider som de andre.
--  * En fanget granny kan bestille taxi, men står alltid sist i køen. Turen
--    teller ikke, lagene får ikke varsel og det er ingen tidsgrense.
--  * Etter «Hentet» har grannyen taxi_ride_max_s (standard 10 min). Da avsluttes
--    turen av seg selv, og sjåføren må slippe henne av.

-- ---------------------------------------------------------------------------
-- Rømling og forsprang ut
-- ---------------------------------------------------------------------------
update public.grannies set is_romling = false where is_romling;
alter table public.games alter column head_start_s set default 0;
update public.games set head_start_s = 0 where status = 'setup';

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
        case when g.head_start_s > 0 then format('Grannyene har %s minutter forsprang.', g.head_start_s / 60)
             else 'Jakten er i gang. Lykke til!' end,
        p_dedupe => 'start');
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

-- ---------------------------------------------------------------------------
-- Ping-tider for bonus-grannyer
-- ---------------------------------------------------------------------------
alter table public.games add column bonus_ping_schedule_s int[] not null default '{}'
  constraint bonus_ping_schedule_sorted check (public.int_array_is_sorted(bonus_ping_schedule_s));

-- En bonus-granny er ikke «egen granny» for noe lag (og er ikke Rømlingen).
create or replace function public._is_bonus_granny(p_granny uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select not exists (select 1 from public.teams where assigned_granny_id = p_granny)
     and not coalesce((select is_romling from public.grannies where id = p_granny), false)
$$;

-- Ping-tidene som gjelder for en granny. Tom bonus-liste: samme som de andre.
create or replace function public._ping_schedule(g public.games, p_bonus boolean)
returns int[]
language sql immutable set search_path = ''
as $$
  select case when p_bonus and cardinality(g.bonus_ping_schedule_s) > 0 then g.bonus_ping_schedule_s else g.ping_schedule_s end
$$;

create or replace function public._last_of(p_sched int[], p_s int)
returns int language sql immutable set search_path = ''
as $$ select max(x) from unnest(p_sched) x where x <= p_s $$;

create or replace function public._next_of(p_sched int[], p_s int)
returns int language sql immutable set search_path = ''
as $$ select min(x) from unnest(p_sched) x where x > p_s $$;

-- Bonus-ping som egne varsler til lagene (vanlige ping lages av tick_games).
create or replace function public.tick_bonus_pings()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  g public.games;
  s int;
  ping int;
begin
  for g in select * from public.games where status = 'running' and cardinality(bonus_ping_schedule_s) > 0 loop
    s := public.game_seconds(g);
    for ping in select x from unnest(g.bonus_ping_schedule_s) x
                where x <= s and x > s - 120 and not (x = any (g.ping_schedule_s)) loop
      perform public._emit(g.id, ping, 'teams', 'ping', 'Bonus-ping!', 'Bonus-grannyene er oppdatert på kartet.',
        p_dedupe => 'bonus_ping:' || ping);
    end loop;
  end loop;
end
$$;

select cron.schedule('granny-bonus-ping', '15 seconds', 'select public.tick_bonus_pings()');

create or replace function public.admin_update_game(p_settings jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(false);
  timing boolean := p_settings ?| array['duration_s', 'head_start_s', 'romling_reveal_s', 'ping_schedule_s', 'bonus_ping_schedule_s'];
  sched int[];
  bonus int[];
begin
  if timing and g.status <> 'setup' then
    raise exception 'Tidene kan bare endres før spillet starter' using errcode = 'P0001';
  end if;
  if p_settings ? 'rules' and (
       jsonb_typeof(p_settings->'rules') <> 'object'
       or exists (select 1 from jsonb_each(p_settings->'rules') r
                  where jsonb_typeof(r.value) <> 'number' or (r.value #>> '{}')::numeric < 0)) then
    raise exception 'Reglene må være tall som er 0 eller mer' using errcode = 'P0001';
  end if;
  if p_settings ? 'ping_schedule_s' then
    select array_agg(x::int order by x::int) into sched from jsonb_array_elements_text(p_settings->'ping_schedule_s') x;
  end if;
  if p_settings ? 'bonus_ping_schedule_s' then
    select coalesce(array_agg(x::int order by x::int), '{}') into bonus
      from jsonb_array_elements_text(p_settings->'bonus_ping_schedule_s') x;
  end if;
  update public.games set
    name                  = coalesce(nullif(trim(p_settings->>'name'), ''), name),
    duration_s            = coalesce((p_settings->>'duration_s')::int, duration_s),
    head_start_s          = coalesce((p_settings->>'head_start_s')::int, head_start_s),
    romling_reveal_s      = coalesce((p_settings->>'romling_reveal_s')::int, romling_reveal_s),
    ping_schedule_s       = coalesce(sched, ping_schedule_s),
    bonus_ping_schedule_s = coalesce(bonus, bonus_ping_schedule_s),
    rules                 = rules || coalesce(p_settings->'rules', '{}'::jsonb)
  where id = g.id;
end
$$;

-- Lagene ser hver granny ved hennes siste ping (bonus-tider for bonus-grannyer).
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
  bonus_ping int;
  gping int;
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
  ping := public._last_of(g.ping_schedule_s, s);
  bonus_ping := public._last_of(public._ping_schedule(g, true), s);
  ability_s := coalesce((g.rules->>'ability_live_s')::int, 60);
  pickup_s := coalesce((g.rules->>'taxi_pickup_show_s')::int, 600);

  select max(until_s) into blind_until from public.blinds where team_id = t.id and from_s <= s and until_s > s;
  if blind_until is not null then
    return jsonb_build_object('game_s', s, 'ping_s', ping, 'bonus_ping_s', bonus_ping, 'blind_until_s', blind_until, 'markers', '[]'::jsonb);
  end if;

  for gr in select * from public.grannies where game_id = g.id order by name loop
    continue when gr.caught_at_s is not null and gr.caught_at_s <= s;
    continue when gr.is_romling and s < g.romling_reveal_s;
    gping := case when public._is_bonus_granny(gr.id) then bonus_ping else ping end;

    live := case when gr.is_romling then null else coalesce(
      public.granny_live_reason(gr.id, s),
      case when exists (select 1 from public.team_abilities a
                        where a.team_id = t.id and a.target_granny_id = gr.id
                          and a.used_s <= s and s < a.used_s + ability_s) then 'evne' end) end;
    if live is not null then
      show_s := s;
    elsif gping is not null and (not gr.is_romling or gping >= g.romling_reveal_s) then
      show_s := gping;
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
  return jsonb_build_object('game_s', s, 'ping_s', ping, 'bonus_ping_s', bonus_ping, 'blind_until_s', null, 'markers', markers);
end
$$;

-- Grannyen ser sin egen neste ping. Alle andre ser den neste av begge listene.
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
  sched int[];
  bonus int[];
  next_regular int;
  next_bonus int;
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

  bonus := public._ping_schedule(g, true);
  next_regular := public._next_of(g.ping_schedule_s, s);
  next_bonus := public._next_of(bonus, s);
  if gr.id is not null then
    sched := public._ping_schedule(g, public._is_bonus_granny(gr.id));
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
    'bonus_ping_schedule_s', to_jsonb(g.bonus_ping_schedule_s),
    'last_ping_s', case when sched is not null then public._last_of(sched, s)
                        else greatest(public._last_of(g.ping_schedule_s, s), public._last_of(bonus, s)) end,
    'next_ping_s', case when sched is not null then public._next_of(sched, s)
                        else least(next_regular, next_bonus) end,
    -- Lagene: neste ping gjelder bare bonus-grannyene.
    'next_ping_bonus', sched is null and next_bonus is not null and (next_regular is null or next_bonus < next_regular),
    'role', p.role,
    'team', case when t.id is null then null else jsonb_build_object(
      'id', t.id, 'name', t.name, 'color', t.color,
      'assigned_granny_id', t.assigned_granny_id,
      'assigned_granny_name', (select name from public.grannies where id = t.assigned_granny_id),
      'has_license', t.license_at_s is not null,
      'blind_until_s', blind_until) end,
    'granny', case when gr.id is null then null else jsonb_build_object(
      'id', gr.id, 'name', gr.name, 'is_romling', gr.is_romling,
      'is_bonus', public._is_bonus_granny(gr.id),
      'caught', gr.caught_at_s is not null, 'caught_at_s', gr.caught_at_s,
      'avatar_path', gr.avatar_path) end,
    'taxi', case when tx.id is null then null else jsonb_build_object('id', tx.id, 'name', tx.name) end
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Taxi: fangede sist i køen, og tidsgrense i bilen
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
    "taxi_ride_max_s": 600,
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
update public.games set rules = '{"taxi_ride_max_s": 600}'::jsonb || rules;

-- Varsel om at tiden i bilen snart er ute, er sendt.
alter table public.taxi_requests add column end_warned boolean not null default false;

-- Køen: frie grannyer først, så fangede. Innenfor hver gruppe: lengst ventetid først.
create or replace function public._taxi_queue_rank(r public.taxi_requests)
returns int
language sql stable security definer set search_path = ''
as $$
  select case when (select caught_at_s from public.grannies where id = r.granny_id) is null then 0 else 1 end
$$;

-- Tiden i bilen er ute ved dette spillsekundet (null: ingen grense).
create or replace function public._taxi_ride_ends_s(g public.games, r public.taxi_requests)
returns int
language sql stable security definer set search_path = ''
as $$
  select case
    when r.status <> 'picked_up' or r.picked_s is null then null
    when coalesce((g.rules->>'taxi_ride_max_s')::int, 600) <= 0 then null
    when (select caught_at_s from public.grannies where id = r.granny_id) is not null then null
    else r.picked_s + (g.rules->>'taxi_ride_max_s')::int end
$$;

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
  caught boolean;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id for update;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  caught := gr.caught_at_s is not null;
  perform public._record_position(p, p_lat, p_lng, p_accuracy);

  -- En fanget granny er ute av spillet. Turene hennes teller ikke.
  if not caught and public._taxi_rides_used(gr.id) >= coalesce((g.rules->>'taxi_max_rides')::int, 1) then
    raise exception 'Du har brukt opp taxiturene dine' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.taxi_requests where granny_id = gr.id and status in ('waiting', 'accepted', 'picked_up')) then
    raise exception 'Du har allerede bestilt taxi' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.taxis where game_id = g.id) then
    raise exception 'Det er ingen taxier i spillet' using errcode = 'P0001';
  end if;

  insert into public.taxi_requests (game_id, granny_id, requested_s) values (g.id, gr.id, s) returning * into r;
  perform public._emit(g.id, s, 'taxis', 'taxi_request', format('%s vil ha taxi.', gr.name),
    case when caught then 'Hun er fanget og står sist i køen.' else 'Ta turen i appen.' end);
  return jsonb_build_object('id', r.id, 'status', r.status);
end
$$;

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
  select * into r from public.taxi_requests w
   where w.game_id = g.id and w.status = 'waiting'
   order by public._taxi_queue_rank(w), w.requested_at limit 1 for update skip locked;
  if r.id is null then raise exception 'Ingen venter på taxi' using errcode = 'P0001'; end if;

  s := public.game_seconds(g);
  select * into tx from public.taxis where id = p.taxi_id;
  update public.taxi_requests set status = 'accepted', taxi_id = p.taxi_id, accepted_s = s where id = r.id;
  perform public._emit(g.id, s, 'granny', 'taxi_accepted', format('%s kommer og henter deg.', tx.name),
    'Bli der du er, eller ring sjåføren.', p_granny => r.granny_id);
  return jsonb_build_object('id', r.id);
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
  gr public.grannies;
  at extensions.geography;
  gpos public.positions;
  limit_s int;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  select * into r from public.taxi_requests where taxi_id = p.taxi_id and status = 'accepted' for update;
  if r.id is null then raise exception 'Du har ingen granny å hente' using errcode = 'P0001'; end if;
  s := public.game_seconds(g);
  perform public._record_position(p, p_lat, p_lng, p_accuracy);
  select * into gr from public.grannies where id = r.granny_id;

  -- En fanget granny er ute av spillet: ingen tur telles, og lagene får ikke vite noe.
  if gr.caught_at_s is not null then
    update public.taxi_requests set status = 'picked_up', picked_s = s, pickup = null, end_warned = false where id = r.id;
    return;
  end if;

  -- Hentestedet: sjåførens posisjon, ellers grannyens siste.
  if p_lat is not null and p_lng is not null then
    at := public._point(p_lat, p_lng);
  else
    gpos := public.granny_position_at(r.granny_id, s);
    at := gpos.geom;
  end if;

  update public.taxi_requests set status = 'picked_up', picked_s = s, pickup = at, end_warned = false where id = r.id;
  insert into public.taxi_rides (game_id, granny_id, at_s) values (g.id, r.granny_id, s);
  perform public._emit(g.id, s, 'teams', 'taxi', 'En granny har tatt taxi.',
    case when at is null then null else 'Hentestedet vises på kartet.' end,
    p_data => case when at is null then null else jsonb_build_object(
      'lat', extensions.st_y(at::extensions.geometry), 'lng', extensions.st_x(at::extensions.geometry)) end);

  limit_s := coalesce((g.rules->>'taxi_ride_max_s')::int, 600);
  if limit_s > 0 then
    perform public._emit(g.id, s, 'granny', 'taxi_ride_started', format('Du har %s min i taxien.', ceil(limit_s / 60.0)::int),
      'Etter det må du gå ut av bilen.', p_granny => gr.id);
  end if;
end
$$;

-- Sjåfør uten svar (som før), og tidsgrensen i bilen.
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
  ends int;
  n  int := 0;
begin
  for g in select * from public.games where status = 'running' loop
    s := public.game_seconds(g);
    timeout := coalesce((g.rules->>'taxi_driver_timeout_s')::int, 300);

    if timeout > 0 then
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
    end if;

    for r in select * from public.taxi_requests where game_id = g.id and status = 'picked_up' for update skip locked loop
      ends := public._taxi_ride_ends_s(g, r);
      continue when ends is null;
      select * into gr from public.grannies where id = r.granny_id;

      if s >= ends then
        update public.taxi_requests set status = 'done', done_s = s where id = r.id;
        perform public._emit(g.id, s, 'granny', 'taxi_ride_over', 'Tiden i taxien er ute.', 'Gå ut av bilen nå.', p_granny => gr.id);
        if r.taxi_id is not null then
          perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_ride_over', format('Tiden er ute. Slipp av %s nå.', gr.name),
            'Turen er avsluttet.');
        end if;
        n := n + 1;
      elsif ends - s <= 60 and not r.end_warned then
        update public.taxi_requests set end_warned = true where id = r.id;
        perform public._emit(g.id, s, 'granny', 'taxi_ride_warning', 'Ett minutt igjen i taxien.', 'Gjør deg klar til å gå ut.', p_granny => gr.id);
        if r.taxi_id is not null then
          perform public._emit_taxi(g.id, s, r.taxi_id, 'taxi_ride_warning', format('Ett minutt igjen med %s.', gr.name),
            'Finn et sted å slippe henne av.');
        end if;
      end if;
    end loop;
  end loop;
  return n;
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
    'timeout_s', coalesce((g.rules->>'taxi_driver_timeout_s')::int, 300),
    'taxi', (select jsonb_build_object('id', id, 'name', name) from public.taxis where id = p.taxi_id),
    'active', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'status', r.status, 'granny_name', gr.name, 'granny_avatar', gr.avatar_path,
      'caught', gr.caught_at_s is not null,
      'requested_s', r.requested_s, 'accepted_s', r.accepted_s, 'picked_s', r.picked_s,
      'ride_ends_s', public._taxi_ride_ends_s(g, r),
      'lat', extensions.st_y(pos.geom::extensions.geometry), 'lng', extensions.st_x(pos.geom::extensions.geometry),
      'position_s', pos.game_s,
      'position_age_s', case when pos.game_s is null then null else greatest(0, s - pos.game_s) end) end,
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'granny_name', wg.name, 'requested_s', w.requested_s,
               'caught', wg.caught_at_s is not null)
             order by public._taxi_queue_rank(w), w.requested_at)
      from public.taxi_requests w join public.grannies wg on wg.id = w.granny_id
      where w.game_id = g.id and w.status = 'waiting'), '[]'::jsonb),
    'busy', (select count(*) from public.taxi_requests b where b.game_id = g.id and b.status in ('accepted', 'picked_up'))::int
  );
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
  my_rank int;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id;
  s := public.game_seconds(g);
  select max(submitted_s), bool_or(status = 'pending') into last_album, album_pending
    from public.photos where granny_id = gr.id and kind = 'fotoalbum' and status <> 'rejected';
  select * into r from public.taxi_requests where granny_id = gr.id and status in ('waiting', 'accepted', 'picked_up');
  if r.id is not null then my_rank := public._taxi_queue_rank(r); end if;

  return jsonb_build_object(
    'game_s', s,
    'points', coalesce((select sum(delta) from public.points_ledger where granny_id = gr.id), 0),
    'taxi_rides', public._taxi_rides_used(gr.id),
    'taxi_max_rides', coalesce((g.rules->>'taxi_max_rides')::int, 1),
    'taxi_request', case when r.id is null then null else jsonb_build_object(
      'status', r.status,
      'taxi_name', (select name from public.taxis where id = r.taxi_id),
      'ride_ends_s', public._taxi_ride_ends_s(g, r),
      'last_in_queue', my_rank = 1,
      'queue_position', case when r.status = 'waiting' then (
        select count(*) from public.taxi_requests q
        where q.game_id = g.id and q.status = 'waiting'
          and (public._taxi_queue_rank(q) < my_rank
               or (public._taxi_queue_rank(q) = my_rank and q.requested_at <= r.requested_at)))::int end) end,
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
        'caught', gr.caught_at_s is not null,
        'taxi_id', r.taxi_id, 'taxi_name', tx.name,
        'requested_s', r.requested_s, 'accepted_s', r.accepted_s, 'picked_s', r.picked_s,
        'ride_ends_s', public._taxi_ride_ends_s(g, r),
        'driver_quiet_s', case when r.status = 'accepted' then s - greatest(r.accepted_s,
          coalesce((select max(game_s) from public.positions where taxi_id = r.taxi_id), r.accepted_s)) end
      ) order by r.status <> 'waiting', public._taxi_queue_rank(r), r.requested_at)
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

-- ---------------------------------------------------------------------------
-- Tilgang (nye hjelpefunksjoner er bare for serveren)
-- ---------------------------------------------------------------------------
revoke execute on function
  public._is_bonus_granny(uuid), public._ping_schedule(public.games, boolean),
  public._last_of(int[], int), public._next_of(int[], int), public.tick_bonus_pings(),
  public._taxi_queue_rank(public.taxi_requests), public._taxi_ride_ends_s(public.games, public.taxi_requests)
from public, anon, authenticated;
