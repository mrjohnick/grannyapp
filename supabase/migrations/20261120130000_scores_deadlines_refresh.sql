-- Endringer 20.11:
--  * Poengtavlen er hemmelig: lag ser bare egne poeng, og bare spilleder ser
--    oppsummeringen (også etter spillet).
--  * Grannyenes plasseringspoeng velges i oppsettet (granny_place_points,
--    1. plass først). Plass = hvor lenge hun holdt seg fri. Alle som er fri når
--    spillet slutter, deler 1. plass. Poengene regnes ut i oppsummeringen.
--  * Side quests kan ha tidsfrist (deadline_s).
--  * data_version på spillet øker når navn, bilder, lag, soner eller taxier
--    endres, så appen henter dem på nytt uten at noen laster siden.

alter table public.games
  add column granny_place_points int[] not null default '{20,15,12,9,7,5,4,3,2,1}',
  add column data_version bigint not null default 0;
alter table public.quests add column deadline_s int;

-- ---------------------------------------------------------------------------
-- Plassering: den som fanges først, får siste plass
-- ---------------------------------------------------------------------------
create or replace function public._granny_place(gr public.grannies)
returns int
language sql stable security definer set search_path = ''
as $$
  select case
    when gr.caught_at_s is null or gr.catch_order is null then 1
    else (select count(*)::int from public.grannies x where x.game_id = gr.game_id and not x.is_romling) - gr.catch_order + 1
  end
$$;

create or replace function public._granny_place_points(g public.games, gr public.grannies)
returns int
language sql stable security definer set search_path = ''
as $$ select coalesce(g.granny_place_points[greatest(public._granny_place(gr), 1)], 0) $$;

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
  -- Poengtavlen er hemmelig for lag og grannyer, også etter spillet.
  if p.role <> 'admin' then
    raise exception 'Bare spilleder ser resultatet' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'game_name', g.name,
    'status', g.status,
    'granny_place_points', to_jsonb(g.granny_place_points),
    'game_s', public.game_seconds(g),
    'grannies', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.total desc, coalesce(x.caught_at_s, 1000000) desc, x.name)
      from (
        select gr.id, gr.name, gr.catch_order, gr.caught_at_s, t.name as caught_by,
               public._granny_place(gr) as place,
               public._granny_place_points(g, gr) as placement,
               coalesce((select sum(delta) from public.points_ledger l where l.granny_id = gr.id), 0)::int as tasks,
               public._granny_place_points(g, gr)
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
        -- Bare eget lag: poengtavlen er hemmelig under spillet.
        from public.teams tt where tt.id = t.id
      ) x), '[]'::jsonb)
  );
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
    -- Øker når navn, bilder, lag, soner eller taxier endres. Appen henter da disse på nytt.
    'data_version', g.data_version,
    'granny_place_points', case when p.role = 'admin' then to_jsonb(g.granny_place_points) end,
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
  place int[];
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
  -- Poeng per plassering for grannyene (1. plass først). Kan endres underveis.
  if p_settings ? 'granny_place_points' then
    if jsonb_typeof(p_settings->'granny_place_points') <> 'array'
       or exists (select 1 from jsonb_array_elements(p_settings->'granny_place_points') x
                  where jsonb_typeof(x) <> 'number' or (x #>> '{}')::numeric < 0) then
      raise exception 'Poeng per plassering må være tall som er 0 eller mer' using errcode = 'P0001';
    end if;
    select coalesce(array_agg((x #>> '{}')::int order by ord), '{}') into place
      from jsonb_array_elements(p_settings->'granny_place_points') with ordinality as e(x, ord);
  end if;
  update public.games set
    granny_place_points   = coalesce(place, granny_place_points),
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

-- ---------------------------------------------------------------------------
-- Side quests med tidsfrist
-- ---------------------------------------------------------------------------
drop function public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid, text);
create function public.admin_save_quest(
  p_id uuid, p_title text, p_description text, p_points int, p_abilities int default 0,
  p_team uuid default null, p_audience text default 'teams', p_granny uuid default null,
  p_ability_kind text default 'live', p_time_limit_min int default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
  g public.games;
  qid uuid;
  aud text := coalesce(p_audience, 'teams');
  s int;
  deadline int;
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

  -- Tidsfrist i minutter fra nå (spilltid). Før start regnes den fra spillstart.
  s := public.game_seconds(g);
  if coalesce(p_time_limit_min, 0) < 0 then raise exception 'Fristen kan ikke være negativ' using errcode = 'P0001'; end if;
  deadline := case when coalesce(p_time_limit_min, 0) > 0 then s + p_time_limit_min * 60 end;

  if p_id is null then
    insert into public.quests (game_id, title, description, reward_points, reward_abilities, team_id, audience, granny_id, reward_ability_kind, deadline_s)
    values (g.id, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), coalesce(p_points, 0),
            case when aud = 'teams' then coalesce(p_abilities, 0) else 0 end, p_team, aud, p_granny, coalesce(p_ability_kind, 'live'), deadline)
    returning id into qid;
    if g.status in ('running', 'paused') then
      perform public._emit(g.id, public.game_seconds(g),
        case when p_team is not null then 'team' when p_granny is not null then 'granny' else aud end,
        'quest_new', format('Ny side quest: %s', trim(p_title)),
        case when deadline is null then 'Se oppdraget under «Oppdrag».'
             else format('Frist: %s min. Se oppdraget under «Oppdrag».', p_time_limit_min) end,
        p_team => p_team, p_granny => p_granny);
    end if;
  else
    update public.quests set title = trim(p_title), description = nullif(trim(coalesce(p_description, '')), ''),
           reward_points = coalesce(p_points, 0),
           reward_abilities = case when aud = 'teams' then coalesce(p_abilities, 0) else 0 end,
           team_id = p_team, audience = aud, granny_id = p_granny, reward_ability_kind = coalesce(p_ability_kind, 'live'),
           deadline_s = deadline
     where id = p_id and game_id = g.id returning id into qid;
    if qid is null then raise exception 'Fant ikke oppdraget' using errcode = 'P0002'; end if;
  end if;
  return qid;
end
$$;

create or replace function public.deliver_quest(p_quest uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player();
  g  public.games;
  q  public.quests;
  gr public.grannies;
  who text;
  s  int;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  select * into q from public.quests where id = p_quest and game_id = g.id;
  if p.role = 'team' then
    if q.id is null or q.audience <> 'teams' or (q.team_id is not null and q.team_id <> p.team_id) then
      raise exception 'Fant ikke oppdraget' using errcode = 'P0002';
    end if;
    who := (select name from public.teams where id = p.team_id);
  elsif p.role = 'granny' then
    select * into gr from public.grannies where id = p.granny_id;
    if gr.caught_at_s is not null then raise exception 'Du er fanget' using errcode = 'P0001'; end if;
    if q.id is null or q.audience <> 'grannies' or (q.granny_id is not null and q.granny_id <> p.granny_id) then
      raise exception 'Fant ikke oppdraget' using errcode = 'P0002';
    end if;
    who := gr.name;
  else
    raise exception 'Bare lag og grannyer leverer oppdrag' using errcode = '42501';
  end if;
  if q.closed then raise exception 'Oppdraget er stengt' using errcode = 'P0001'; end if;
  if q.deadline_s is not null and public.game_seconds(g) >= q.deadline_s then
    raise exception 'Fristen er ute' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.quest_submissions x where x.quest_id = q.id and x.status in ('pending', 'approved')
             and (x.team_id = p.team_id or x.granny_id = p.granny_id)) then
    raise exception 'Dere har allerede levert dette oppdraget' using errcode = 'P0001';
  end if;

  s := public.game_seconds(g);
  insert into public.quest_submissions (game_id, quest_id, team_id, granny_id, submitted_s)
  values (g.id, q.id, case when p.role = 'team' then p.team_id end, case when p.role = 'granny' then p.granny_id end, s);
  perform public._emit(g.id, s, 'admin', 'quest_pending', format('%s har levert «%s».', who, q.title),
    'Sjekk Telegram og godkjenn i appen.');
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
        'closed', q.closed, 'deadline_s', q.deadline_s,
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

create or replace function public.granny_quests()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('granny');
  g public.games;
begin
  select * into g from public.games where id = p.game_id;
  return jsonb_build_object(
    'quests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id, 'title', q.title, 'description', q.description,
        'reward_points', q.reward_points, 'reward_abilities', 0,
        'closed', q.closed, 'deadline_s', q.deadline_s,
        'status', (select s.status from public.quest_submissions s where s.quest_id = q.id and s.granny_id = p.granny_id
                   order by s.submitted_at desc limit 1),
        'note', (select s.note from public.quest_submissions s where s.quest_id = q.id and s.granny_id = p.granny_id
                 order by s.submitted_at desc limit 1)
      ) order by q.closed, q.created_at desc)
      from public.quests q
      where q.game_id = g.id and q.audience = 'grannies' and (q.granny_id is null or q.granny_id = p.granny_id)
        and (not q.closed or exists (select 1 from public.quest_submissions s where s.quest_id = q.id and s.granny_id = p.granny_id))
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
      'closed', q.closed, 'deadline_s', q.deadline_s,
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
-- data_version: si fra til appene når faste data endres
-- ---------------------------------------------------------------------------
create or replace function public.tg_bump_data_version()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.games set data_version = data_version + 1
   where id = coalesce(new.game_id, old.game_id);
  return null;
end
$$;

create trigger grannies_data_version
  after insert or delete or update of name, avatar_path, is_romling on public.grannies
  for each row execute function public.tg_bump_data_version();
create trigger teams_data_version
  after insert or delete or update of name, color, assigned_granny_id on public.teams
  for each row execute function public.tg_bump_data_version();
create trigger taxis_data_version
  after insert or delete or update of name on public.taxis
  for each row execute function public.tg_bump_data_version();
create trigger zones_data_version
  after insert or delete or update on public.zones
  for each row execute function public.tg_bump_data_version();

-- ---------------------------------------------------------------------------
-- Tilgang
-- ---------------------------------------------------------------------------
revoke execute on function
  public._granny_place(public.grannies), public._granny_place_points(public.games, public.grannies),
  public.tg_bump_data_version(),
  public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid, text, int)
from public, anon, authenticated;
grant execute on function public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid, text, int) to authenticated;
