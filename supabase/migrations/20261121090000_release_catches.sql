-- Fangst av en granny som ikke er lagets egen: laget får poeng, men hun går fri igjen
-- og er fredet en stund. Bare laget som har henne som egen granny (og Rømlingen) tar
-- henne ut av jakten. Hvert lag kan ta hver «fremmede» granny én gang.

alter table public.grannies add column protected_until_s int;
alter table public.catches  add column released boolean not null default false;

-- Fredningstid etter at hun er sluppet fri (sekunder). Settes i Oppsett.
update public.games set rules = rules || '{"catch_immunity_s": 300}'::jsonb where not rules ? 'catch_immunity_s';
alter table public.games
  alter column rules set default '{"blind_s": 600, "snitch_live_s": 60, "ability_live_s": 30, "retention_days": 30,
    "taxi_max_rides": 1, "romling_retry_s": 1200, "taxi_ride_max_s": 600, "nabovakt_search_m": 300,
    "catch_points_bonus": 20, "catch_immunity_s": 300, "reblind_cooldown_s": 900, "taxi_pickup_show_s": 600,
    "nabovakt_cooldown_s": 3600, "out_of_area_grace_s": 60, "snitch_bonus_window_s": 600,
    "taxi_driver_timeout_s": 300, "telegram_stale_admin_s": 180, "catch_confirm_timeout_s": 86400,
    "telegram_stale_reminder_s": 60}'::jsonb;

-- Tar fangsten henne ut av jakten? Bare egen granny og Rømlingen.
create or replace function public._catch_takes_out(p_granny uuid, p_team uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select gr.is_romling or exists (select 1 from public.teams t where t.id = p_team and t.assigned_granny_id = gr.id)
  from public.grannies gr where gr.id = p_granny
$$;
revoke all on function public._catch_takes_out(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Registrer: avvis fredet granny og en fremmed granny laget allerede har tatt.
-- ---------------------------------------------------------------------------
create or replace function public.register_catch(p_granny uuid, p_selfie text default null)
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
  if gr.protected_until_s is not null and s < gr.protected_until_s then
    raise exception 'Hun er fredet' using errcode = 'P0001';
  end if;
  if not public._catch_takes_out(gr.id, t.id) and exists (
       select 1 from public.catches x where x.granny_id = gr.id and x.team_id = t.id and x.status = 'confirmed') then
    raise exception 'Dere har allerede tatt henne' using errcode = 'P0001';
  end if;

  select * into c from public.catches where granny_id = gr.id and team_id = t.id and status = 'pending';
  if c is null then
    insert into public.catches (game_id, granny_id, team_id, registered_by, registered_s, selfie_path)
    values (g.id, gr.id, t.id, p.user_id, s, p_selfie)
    returning * into c;
    perform public._emit(g.id, s, 'granny', 'catch_registered',
      format('%s sier de har fanget deg.', t.name), 'Spilleder avgjør.', p_granny => gr.id,
      p_data => jsonb_build_object('catch_id', c.id));
    perform public._emit(g.id, s, 'admin', 'catch_pending', format('%s sier de har fanget %s.', t.name, gr.name),
      case when public._catch_takes_out(gr.id, t.id) then 'Sjekk bildet i Telegram og godkjenn i appen.'
           else 'Ikke deres granny: godkjent gir poeng, og hun går fri igjen.' end,
      p_data => jsonb_build_object('catch_id', c.id));
  elsif p_selfie is not null then
    update public.catches set selfie_path = p_selfie where id = c.id returning * into c;
  end if;

  return jsonb_build_object('id', c.id, 'granny_name', gr.name, 'registered_s', c.registered_s,
                            'takes_out', public._catch_takes_out(gr.id, t.id));
end
$$;

-- ---------------------------------------------------------------------------
-- Godkjenn: egen granny / Rømlingen er ute. Ellers poeng, fri igjen og fredet.
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
  pts int;
  bonus boolean;
  out_ boolean;
  now_s int;
  free_s int;
begin
  select * into c from public.catches where id = p_catch for update;
  if c is null then raise exception 'Fant ikke fangsten' using errcode = 'P0002'; end if;
  select * into gr from public.grannies where id = c.granny_id for update;
  if gr.caught_at_s is not null then raise exception 'Hun er allerede fanget' using errcode = 'P0001'; end if;
  select * into t from public.teams where id = c.team_id;
  select * into g from public.games where id = c.game_id;

  -- Bonus-granny: ingen lag har henne som egen granny.
  bonus := not gr.is_romling and not exists (select 1 from public.teams tt where tt.assigned_granny_id = gr.id);
  out_ := public._catch_takes_out(gr.id, t.id);
  pts := case
    when gr.is_romling then 20
    when t.assigned_granny_id = gr.id then 15
    when bonus then coalesce((g.rules->>'catch_points_bonus')::int, 20)
    else 10 end;

  update public.catches set status = 'confirmed', released = not out_, resolved_at = now(), resolved_by = p_by,
         admin_reviewed_at = case when p_by = 'admin' then now() else admin_reviewed_at end
   where id = c.id;
  -- Andre krav på samme fangst faller bort.
  update public.catches set status = 'void', resolved_at = now(), resolved_by = p_by
   where granny_id = gr.id and status = 'pending' and id <> c.id;

  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  values (g.id, t.id, pts, case when gr.is_romling then 'romling' when bonus then 'fangst_bonus' else 'fangst' end, c.id, c.registered_s);

  if not out_ then
    -- Tatt, men fri igjen: fredet fra nå (godkjenningen), ikke fra registreringen.
    now_s := public.game_seconds(g);
    free_s := now_s + coalesce((g.rules->>'catch_immunity_s')::int, 300);
    update public.grannies set protected_until_s = free_s where id = gr.id;
    perform public._emit(g.id, now_s, 'teams', 'catch_released',
      format('%s ble tatt av %s.', gr.name, t.name),
      format('%sp til laget. Hun går fri igjen og er fredet i %s min.', pts, round((free_s - now_s) / 60.0)),
      p_data => jsonb_build_object('granny_id', gr.id, 'team_id', t.id),
      p_dedupe => 'catch_released:' || c.id);
    perform public._emit(g.id, now_s, 'granny', 'catch_released_me',
      format('Du er fri igjen! %s fikk poeng for deg.', t.name),
      format('Ingen lag kan ta deg de neste %s minuttene. Kom deg unna.', round((free_s - now_s) / 60.0)),
      p_granny => gr.id, p_dedupe => 'catch_released_me:' || c.id);
    return;
  end if;

  update public.grannies set caught_at_s = c.registered_s, caught_by = c.team_id where id = gr.id;

  with o as (
    select x.id, row_number() over (order by x.caught_at_s) as rn
    from public.grannies x
    where x.game_id = g.id and x.caught_at_s is not null and not x.is_romling
  )
  update public.grannies x set catch_order = o.rn from o where x.id = o.id;

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


-- ---------------------------------------------------------------------------
-- Lister: lagets fangster og spilleders kø sier om fangsten tar henne ut.
-- ---------------------------------------------------------------------------
create or replace function public.team_catches()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'granny_id', c.granny_id, 'granny_name', gr.name,
    'status', c.status, 'registered_s', c.registered_s,
    'age_s', extract(epoch from now() - coalesce(c.resolved_at, c.registered_at))::int,
    'admin_deciding', c.status = 'rejected' and c.admin_reviewed_at is null,
    'released', c.released,
    'takes_out', public._catch_takes_out(c.granny_id, c.team_id),
    'protected_until_s', gr.protected_until_s
  ) order by c.registered_at desc), '[]'::jsonb)
  from public.catches c
  join public.grannies gr on gr.id = c.granny_id
  where c.team_id = public.my_team_id()
    and c.registered_at > now() - interval '30 minutes'
$$;

-- Hvilke grannyer laget kan fange nå, og hva de gir.
create or replace function public.team_catch_targets()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('team');
  g public.games;
  t public.teams;
  s int;
begin
  select * into g from public.games where id = p.game_id;
  select * into t from public.teams where id = p.team_id;
  s := public.game_seconds(g);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', gr.id, 'name', gr.name, 'is_romling', gr.is_romling,
      'takes_out', public._catch_takes_out(gr.id, t.id),
      'points', case
        when gr.is_romling then 20
        when t.assigned_granny_id = gr.id then 15
        when not exists (select 1 from public.teams tt where tt.assigned_granny_id = gr.id)
          then coalesce((g.rules->>'catch_points_bonus')::int, 20)
        else 10 end,
      'protected_until_s', case when gr.protected_until_s > s then gr.protected_until_s end,
      'taken_by_us', not public._catch_takes_out(gr.id, t.id) and exists (
        select 1 from public.catches x where x.granny_id = gr.id and x.team_id = t.id and x.status = 'confirmed')
    ) order by (t.assigned_granny_id = gr.id) desc, gr.is_romling, gr.name)
    from public.grannies gr
    where gr.game_id = g.id and gr.caught_at_s is null
  ), '[]'::jsonb);
end
$$;
revoke all on function public.team_catch_targets() from public, anon, authenticated;
grant execute on function public.team_catch_targets() to authenticated;

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
      'competing', (select count(*) from public.catches x where x.granny_id = c.granny_id and x.status = 'pending')::int,
      'takes_out', public._catch_takes_out(gr.id, t.id)
    ) order by c.registered_at)
    from public.catches c
    join public.grannies gr on gr.id = c.granny_id
    join public.teams t on t.id = c.team_id
    where c.game_id = g.id
      and (c.status = 'pending' or (c.status = 'rejected' and c.admin_reviewed_at is null))
  ), '[]'::jsonb);
end
$$;

-- Granny ser selv hvor lenge hun er fredet.
do $x$
declare src text;
begin
  select pg_get_functiondef('public.granny_status()'::regprocedure) into src;
  src := replace(src, $q$'snitch_used', exists$q$,
    $q$'protected_until_s', case when gr.protected_until_s > s then gr.protected_until_s end,
    'snitch_used', exists$q$);
  execute src;
end
$x$;

-- Ny runde: fredningen nullstilles sammen med fangstene.
do $x$
declare src text;
begin
  select pg_get_functiondef('public.admin_reset_game()'::regprocedure) into src;
  if position('catch_order = null where' in src) = 0 then raise exception 'admin_reset_game har endret seg'; end if;
  src := replace(src, 'catch_order = null where', 'catch_order = null, protected_until_s = null where');
  execute src;
end
$x$;
