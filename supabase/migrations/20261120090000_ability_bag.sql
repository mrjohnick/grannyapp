-- Evnesekk for lagene (19.11). Side quests kan gi evner av fire typer, som
-- laget sparer og bruker når de vil (hver evne én gang):
--   ping_one   – se én valgfri granny der hun er nå (øyeblikksbilde)
--   ping_all   – se alle grannyer der de er nå
--   ping_bonus – se alle bonus-grannyer der de er nå
--   live       – se én valgfri granny live i ability_live_s (standard 30 sek)
-- Pingene vises bare for laget som brukte evnen. Grannyene varsles hver gang
-- de blir pinget: av evner, av sladring og ved vanlige ping og bonus-ping.

alter table public.team_abilities
  add column kind text not null default 'live' check (kind in ('ping_one', 'ping_all', 'ping_bonus', 'live'));
alter table public.quests
  add column reward_ability_kind text not null default 'live' check (reward_ability_kind in ('ping_one', 'ping_all', 'ping_bonus', 'live'));

update public.games set rules = rules || '{"ability_live_s": 30}'::jsonb;
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
    "ability_live_s": 30,
    "catch_points_bonus": 20,
    "romling_retry_s": 1200,
    "nabovakt_search_m": 300,
    "nabovakt_cooldown_s": 3600,
    "out_of_area_grace_s": 60,
    "catch_confirm_timeout_s": 86400,
    "telegram_stale_reminder_s": 60,
    "telegram_stale_admin_s": 180,
    "retention_days": 30
  }'::jsonb;

create or replace function public._ability_name(p_kind text)
returns text language sql immutable set search_path = ''
as $$
  select case p_kind
    when 'ping_one' then 'ping på én granny'
    when 'ping_all' then 'ping på alle grannyer'
    when 'ping_bonus' then 'ping på bonus-grannyer'
    when 'live' then 'live på én granny'
    else p_kind end
$$;

-- Laget bruker en evne fra sekken. p_granny trengs for ping_one og live.
create or replace function public.use_team_ability(p_kind text, p_granny uuid default null)
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
  x  public.grannies;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  if p_kind not in ('ping_one', 'ping_all', 'ping_bonus', 'live') then raise exception 'Ukjent evne' using errcode = '22023'; end if;
  s := public.game_seconds(g);
  select * into t from public.teams where id = p.team_id;

  if p_kind in ('ping_one', 'live') then
    select * into gr from public.grannies where id = p_granny and game_id = g.id;
    if gr.id is null then raise exception 'Velg en granny' using errcode = 'P0002'; end if;
    if gr.is_romling then raise exception 'Rømlingen kan ikke vises' using errcode = 'P0001'; end if;
    if gr.caught_at_s is not null then raise exception '% er allerede fanget', gr.name using errcode = 'P0001'; end if;
    if p_kind = 'ping_one' and public.granny_position_at(gr.id, s) is null then
      raise exception 'Vi vet ikke hvor hun er ennå' using errcode = 'P0001';
    end if;
  end if;

  select * into a from public.team_abilities
   where team_id = t.id and kind = p_kind and used_s is null order by granted_s limit 1 for update skip locked;
  if a.id is null then raise exception 'Dere har ingen slike evner igjen' using errcode = 'P0001'; end if;
  update public.team_abilities set used_s = s, target_granny_id = gr.id where id = a.id;

  if p_kind = 'ping_one' then
    perform public._emit(g.id, s, 'team', 'ability_used', format('Dere pinget %s.', gr.name), 'Se kartet.', p_team => t.id);
    perform public._emit(g.id, s, 'granny', 'pinged', 'Et lag har pinget deg.', 'De ser hvor du er akkurat nå.', p_granny => gr.id);
  elsif p_kind = 'live' then
    secs := coalesce((g.rules->>'ability_live_s')::int, 30);
    perform public._emit(g.id, s, 'team', 'ability_used', format('Dere ser %s live i %s sek.', gr.name, secs), null, p_team => t.id);
    perform public._emit(g.id, s, 'granny', 'ability_target', format('Et lag ser deg live i %s sek.', secs), 'Kom deg videre!', p_granny => gr.id);
  elsif p_kind = 'ping_all' then
    perform public._emit(g.id, s, 'team', 'ability_used', 'Dere pinget alle grannyer.', 'Se kartet.', p_team => t.id);
    for x in select * from public.grannies where game_id = g.id and caught_at_s is null and not is_romling loop
      perform public._emit(g.id, s, 'granny', 'pinged', 'Et lag har pinget alle grannyer.', 'De ser hvor du er akkurat nå.', p_granny => x.id);
    end loop;
  else
    perform public._emit(g.id, s, 'team', 'ability_used', 'Dere pinget bonus-grannyene.', 'Se kartet.', p_team => t.id);
    for x in select * from public.grannies where game_id = g.id and caught_at_s is null and public._is_bonus_granny(id) loop
      perform public._emit(g.id, s, 'granny', 'pinged', 'Et lag har pinget alle bonus-grannyer.', 'De ser hvor du er akkurat nå.', p_granny => x.id);
    end loop;
  end if;
end
$$;

-- Den gamle «se granny live» (bare live) går nå via use_team_ability.
create or replace function public.team_use_ability(p_granny uuid)
returns void
language sql security definer set search_path = ''
as $$ select public.use_team_ability('live', p_granny) $$;

-- Varsel til hver granny når hun blir pinget ved vanlig ping eller bonus-ping
-- (kjøres av pg_cron hvert 15. sekund).
create or replace function public.tick_granny_ping_alerts()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  g  public.games;
  gr public.grannies;
  s  int;
  ping int;
  bonus boolean;
begin
  for g in select * from public.games where status = 'running' loop
    s := public.game_seconds(g);
    for gr in select * from public.grannies where game_id = g.id and caught_at_s is null and not is_romling loop
      bonus := public._is_bonus_granny(gr.id);
      for ping in select x from unnest(public._ping_schedule(g, bonus)) x where x <= s and x > s - 120 loop
        perform public._emit(g.id, ping, 'granny', 'pinged',
          case when bonus and cardinality(g.bonus_ping_schedule_s) > 0 then 'Bonus-ping!' else 'Ping!' end,
          'Lagene ser hvor du er nå.', p_granny => gr.id, p_dedupe => 'granny_ping:' || ping || ':' || gr.id);
      end loop;
    end loop;
  end loop;
end
$$;

select cron.schedule('granny-ping-alerts', '15 seconds', 'select public.tick_granny_ping_alerts()');

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
  snitch_s int;
  team_ping int;
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
  ability_s := coalesce((g.rules->>'ability_live_s')::int, 30);
  pickup_s := coalesce((g.rules->>'taxi_pickup_show_s')::int, 600);

  select max(until_s) into blind_until from public.blinds where team_id = t.id and from_s <= s and until_s > s;
  if blind_until is not null then
    return jsonb_build_object('game_s', s, 'ping_s', ping, 'bonus_ping_s', bonus_ping, 'blind_until_s', blind_until, 'markers', '[]'::jsonb);
  end if;

  for gr in select * from public.grannies where game_id = g.id order by name loop
    continue when gr.caught_at_s is not null and gr.caught_at_s <= s;
    continue when gr.is_romling and s < g.romling_reveal_s;
    gping := case when public._is_bonus_granny(gr.id) then bonus_ping else ping end;
    -- En sladring er en ekstra ping for henne: siste posisjon i det øyeblikket.
    select max(at_s) into snitch_s from public.snitches where target_granny_id = gr.id and at_s <= s;
    -- Lagets egne ping-evner: øyeblikksbilde for dette laget.
    select max(a.used_s) into team_ping from public.team_abilities a
     where a.team_id = t.id and a.used_s is not null and a.used_s <= s
       and (a.kind = 'ping_all'
            or (a.kind = 'ping_one' and a.target_granny_id = gr.id)
            or (a.kind = 'ping_bonus' and public._is_bonus_granny(gr.id)));
    gping := greatest(gping, snitch_s, team_ping);

    live := case when gr.is_romling then null else coalesce(
      public.granny_live_reason(gr.id, s),
      case when exists (select 1 from public.team_abilities a
                        where a.team_id = t.id and a.kind = 'live' and a.target_granny_id = gr.id
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
      'age_s', show_s - pos.game_s,
      'snitched', live is null and snitch_s is not null and show_s = snitch_s,
      'team_pinged', live is null and team_ping is not null and show_s = team_ping
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

  return jsonb_build_object('game_s', s, 'ping_s', ping, 'bonus_ping_s', bonus_ping, 'blind_until_s', null, 'markers', markers);
end
$$;

drop function public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid);
create function public.admin_save_quest(
  p_id uuid, p_title text, p_description text, p_points int, p_abilities int default 0,
  p_team uuid default null, p_audience text default 'teams', p_granny uuid default null,
  p_ability_kind text default 'live')
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
  qid uuid;
  aud text := coalesce(p_audience, 'teams');
begin
  select * into g from public.games where id = p.game_id;
  if length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Skriv en tittel' using errcode = 'P0001'; end if;
  if coalesce(p_points, 0) < 0 or coalesce(p_abilities, 0) < 0 then raise exception 'Belønningen kan ikke være negativ' using errcode = 'P0001'; end if;
  if coalesce(p_points, 0) = 0 and coalesce(p_abilities, 0) = 0 then raise exception 'Gi poeng, en evne eller begge' using errcode = 'P0001'; end if;
  if aud not in ('teams', 'grannies') then raise exception 'Ukjent mottaker' using errcode = '22023'; end if;
  if coalesce(p_ability_kind, 'live') not in ('ping_one', 'ping_all', 'ping_bonus', 'live') then
    raise exception 'Ukjent evne' using errcode = '22023';
  end if;
  if aud = 'teams' and p_granny is not null or aud = 'grannies' and p_team is not null then
    raise exception 'Ukjent mottaker' using errcode = '22023';
  end if;
  if p_team is not null and not exists (select 1 from public.teams where id = p_team and game_id = g.id) then
    raise exception 'Ukjent lag' using errcode = 'P0002';
  end if;
  if p_granny is not null and not exists (select 1 from public.grannies where id = p_granny and game_id = g.id) then
    raise exception 'Ukjent granny' using errcode = 'P0002';
  end if;

  if p_id is null then
    insert into public.quests (game_id, title, description, reward_points, reward_abilities, team_id, audience, granny_id, reward_ability_kind)
    values (g.id, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), coalesce(p_points, 0),
            case when aud = 'teams' then coalesce(p_abilities, 0) else 0 end, p_team, aud, p_granny, coalesce(p_ability_kind, 'live'))
    returning id into qid;
    if g.status in ('running', 'paused') then
      perform public._emit(g.id, public.game_seconds(g),
        case when p_team is not null then 'team' when p_granny is not null then 'granny' else aud end,
        'quest_new', format('Ny side quest: %s', trim(p_title)), 'Se oppdraget under «Oppdrag».',
        p_team => p_team, p_granny => p_granny);
    end if;
  else
    update public.quests set title = trim(p_title), description = nullif(trim(coalesce(p_description, '')), ''),
           reward_points = coalesce(p_points, 0),
           reward_abilities = case when aud = 'teams' then coalesce(p_abilities, 0) else 0 end,
           team_id = p_team, audience = aud, granny_id = p_granny, reward_ability_kind = coalesce(p_ability_kind, 'live')
     where id = p_id and game_id = g.id returning id into qid;
    if qid is null then raise exception 'Fant ikke oppdraget' using errcode = 'P0002'; end if;
  end if;
  return qid;
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
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  aud text;
begin
  select * into g from public.games where id = p.game_id;
  select * into sb from public.quest_submissions where id = p_submission and game_id = g.id for update;
  if sb.id is null then raise exception 'Fant ikke innsendingen' using errcode = 'P0002'; end if;
  if sb.status <> 'pending' then raise exception 'Innsendingen er allerede behandlet' using errcode = 'P0001'; end if;
  select * into q from public.quests where id = sb.quest_id;
  s := public.game_seconds(g);
  aud := case when sb.team_id is not null then 'team' else 'granny' end;

  if not p_approve then
    update public.quest_submissions set status = 'rejected', note = v_note, reviewed_at = now() where id = sb.id;
    perform public._emit(g.id, s, aud, 'quest_rejected', format('«%s» ble ikke godkjent.', q.title),
      coalesce(v_note, 'Prøv igjen.'), p_team => sb.team_id, p_granny => sb.granny_id);
    return;
  end if;

  update public.quest_submissions set status = 'approved', reviewed_at = now() where id = sb.id;
  if q.reward_points > 0 then
    insert into public.points_ledger (game_id, team_id, granny_id, delta, reason, ref_id, at_s, created_by)
    values (g.id, sb.team_id, sb.granny_id, q.reward_points, 'side_quest', sb.id, s, 'admin');
  end if;
  if sb.team_id is not null then
    insert into public.team_abilities (game_id, team_id, submission_id, granted_s, kind)
    select g.id, sb.team_id, sb.id, s, q.reward_ability_kind from generate_series(1, q.reward_abilities);
  end if;
  perform public._emit(g.id, s, aud, 'quest_approved', format('«%s» er godkjent!', q.title),
    concat_ws(' og ',
      case when q.reward_points > 0 then format('Dere får %sp', q.reward_points) end,
      case when sb.team_id is not null and q.reward_abilities > 0 then
        format('%s × %s i evnesekken', q.reward_abilities, public._ability_name(q.reward_ability_kind)) end) || '.',
    p_team => sb.team_id, p_granny => sb.granny_id);
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
    'ability_live_s', coalesce((g.rules->>'ability_live_s')::int, 30),
    'abilities', jsonb_build_object(
      'ping_one',   (select count(*) from public.team_abilities where team_id = p.team_id and used_s is null and kind = 'ping_one')::int,
      'ping_all',   (select count(*) from public.team_abilities where team_id = p.team_id and used_s is null and kind = 'ping_all')::int,
      'ping_bonus', (select count(*) from public.team_abilities where team_id = p.team_id and used_s is null and kind = 'ping_bonus')::int,
      'live',       (select count(*) from public.team_abilities where team_id = p.team_id and used_s is null and kind = 'live')::int),
    'quests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id, 'title', q.title, 'description', q.description,
        'reward_points', q.reward_points, 'reward_abilities', q.reward_abilities, 'reward_ability_kind', q.reward_ability_kind,
        'closed', q.closed,
        'status', (select s.status from public.quest_submissions s where s.quest_id = q.id and s.team_id = p.team_id
                   order by s.submitted_at desc limit 1),
        'note', (select s.note from public.quest_submissions s where s.quest_id = q.id and s.team_id = p.team_id
                 order by s.submitted_at desc limit 1)
      ) order by q.closed, q.created_at desc)
      from public.quests q
      where q.game_id = g.id and q.audience = 'teams' and (q.team_id is null or q.team_id = p.team_id)
        and (not q.closed or exists (select 1 from public.quest_submissions s where s.quest_id = q.id and s.team_id = p.team_id))
    ), '[]'::jsonb)
  );
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
      'reward_points', q.reward_points, 'reward_abilities', q.reward_abilities, 'reward_ability_kind', q.reward_ability_kind,
      'audience', q.audience,
      'team_id', q.team_id, 'team_name', t.name,
      'granny_id', q.granny_id, 'granny_name', gq.name,
      'closed', q.closed,
      'pending', (select count(*) from public.quest_submissions s where s.quest_id = q.id and s.status = 'pending')::int,
      'approved_teams', coalesce((select jsonb_agg(coalesce(tt.name, gg.name) order by s.submitted_at) from public.quest_submissions s
                                  left join public.teams tt on tt.id = s.team_id
                                  left join public.grannies gg on gg.id = s.granny_id
                                  where s.quest_id = q.id and s.status = 'approved'), '[]'::jsonb)
    ) order by q.closed, q.created_at desc)
    from public.quests q
    left join public.teams t on t.id = q.team_id
    left join public.grannies gq on gq.id = q.granny_id
    where q.game_id = p.game_id), '[]'::jsonb);
end
$$;

-- ---------------------------------------------------------------------------
-- Tilgang
-- ---------------------------------------------------------------------------
revoke execute on function
  public._ability_name(text), public.tick_granny_ping_alerts(),
  public.use_team_ability(text, uuid),
  public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid, text)
from public, anon, authenticated;
grant execute on function
  public.use_team_ability(text, uuid),
  public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid, text)
to authenticated;
