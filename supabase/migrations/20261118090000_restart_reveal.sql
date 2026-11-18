-- Spilleder: start spillet på nytt, vis en granny live, og endre regler underveis.

-- ---------------------------------------------------------------------------
-- Vis granny live (spilleder bestemmer hvor lenge)
-- ---------------------------------------------------------------------------
create table public.reveals (
  id         uuid primary key default gen_random_uuid(),
  game_id    uuid not null references public.games on delete cascade,
  granny_id  uuid not null references public.grannies on delete cascade,
  at_s       int not null,
  until_s    int not null,
  created_at timestamptz not null default now()
);
create index reveals_granny on public.reveals (granny_id, until_s);
alter table public.reveals enable row level security;
revoke all on public.reveals from anon, authenticated;

-- Samme som før, men med «spilleder» som ny grunn til å være live.
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
  if exists (select 1 from public.reveals where granny_id = p_granny and at_s <= p_s and until_s > p_s) then
    return 'spilleder';
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

-- Blinde lag får heller ikke varsel når spilleder viser en granny.
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
    else false
  end
$$;

create or replace function public.admin_reveal_granny(p_granny uuid, p_minutes int)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('admin');
  g  public.games;
  gr public.grannies;
  s  int;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 30 then
    raise exception 'Velg mellom 1 og 30 minutter' using errcode = 'P0001';
  end if;
  select * into gr from public.grannies where id = p_granny and game_id = g.id;
  if gr.id is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  if gr.is_romling then raise exception 'Rømlingen kan ikke vises live' using errcode = 'P0001'; end if;
  if gr.caught_at_s is not null then raise exception '% er allerede fanget', gr.name using errcode = 'P0001'; end if;

  s := public.game_seconds(g);
  insert into public.reveals (game_id, granny_id, at_s, until_s) values (g.id, gr.id, s, s + p_minutes * 60);
  perform public._emit(g.id, s, 'teams', 'reveal', format('%s er live i %s min.', gr.name, p_minutes),
    'Spilleder viser posisjonen på kartet.', p_granny => gr.id);
  perform public._emit(g.id, s, 'granny', 'reveal_target', format('Du er synlig for alle lag i %s min.', p_minutes),
    'Spilleder viser posisjonen din på kartet.', p_granny => gr.id);
end
$$;

-- ---------------------------------------------------------------------------
-- Regler kan endres mens spillet går. Tidene låses fortsatt ved start.
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_game(p_settings jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.games := public._admin_game_for_setup(false);
  timing boolean := p_settings ?| array['duration_s', 'head_start_s', 'romling_reveal_s', 'ping_schedule_s'];
  sched int[];
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

-- ---------------------------------------------------------------------------
-- Start på nytt: sletter alt som skjedde i spillet, men beholder grannies,
-- lag, innloggingskoder, innloggede telefoner, soner, tider og regler.
-- ---------------------------------------------------------------------------
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
  delete from public.nabovakt_checkins where game_id = g.id;
  delete from public.romling_attempts  where game_id = g.id;
  delete from public.reveals           where game_id = g.id;
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
revoke execute on function public.admin_reveal_granny(uuid, int), public.admin_reset_game()
from public, anon, authenticated;
grant execute on function public.admin_reveal_granny(uuid, int), public.admin_reset_game()
to authenticated;
