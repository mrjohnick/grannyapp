-- Endringer 19.11 (3): bilder og videoer går i lagenes Telegram-grupper.
--  * Appen laster ikke lenger opp bevis. Lag og grannyer trykker «Marker som
--    levert», og spilleder godkjenner før poengene kommer.
--  * Side quests kan sendes til lag eller til grannyer.
--  * Postkort leveres uten bilde (posisjonen lagres for spilleder).
--  * Fangst teller bare når spilleder godkjenner. Grannyen bekrefter ikke lenger.
--  * Fotoalbumet og Bingo er tatt ut av appen (logikken ligger igjen, ubrukt).
--  * Taxi: lagene får vite navnet på den som tok taxi, men ikke hentestedet.

-- ---------------------------------------------------------------------------
-- Taxi uten hentested
-- ---------------------------------------------------------------------------
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

  -- Lagene får bare vite hvem som tok taxi, ikke hvor (ingen hentested på kartet).
  update public.taxi_requests set status = 'picked_up', picked_s = s, pickup = null, end_warned = false where id = r.id;
  insert into public.taxi_rides (game_id, granny_id, at_s) values (g.id, r.granny_id, s);
  perform public._emit(g.id, s, 'teams', 'taxi', format('%s har tatt taxi.', gr.name), null);

  limit_s := coalesce((g.rules->>'taxi_ride_max_s')::int, 600);
  if limit_s > 0 then
    perform public._emit(g.id, s, 'granny', 'taxi_ride_started', format('Du har %s min i taxien.', ceil(limit_s / 60.0)::int),
      'Etter det må du gå ut av bilen.', p_granny => gr.id);
  end if;
end
$$;

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
    perform public._emit(g.id, s, 'teams', 'message', 'Se bort fra forrige taxivarsel.', format('%s sitter likevel ikke i taxi.', gr.name));

  else
    raise exception 'Ukjent handling' using errcode = '22023';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Fangst: bare spilleder godkjenner
-- ---------------------------------------------------------------------------
create or replace function public.granny_respond_catch(p_catch uuid, p_accept boolean)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
begin
  raise exception 'Spilleder godkjenner fangster' using errcode = 'P0001';
end
$$;

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

  select * into c from public.catches where granny_id = gr.id and team_id = t.id and status = 'pending';
  if c is null then
    insert into public.catches (game_id, granny_id, team_id, registered_by, registered_s, selfie_path)
    values (g.id, gr.id, t.id, p.user_id, s, p_selfie)
    returning * into c;
    perform public._emit(g.id, s, 'granny', 'catch_registered',
      format('%s sier de har fanget deg.', t.name), 'Spilleder avgjør.', p_granny => gr.id,
      p_data => jsonb_build_object('catch_id', c.id));
    perform public._emit(g.id, s, 'admin', 'catch_pending', format('%s sier de har fanget %s.', t.name, gr.name),
      'Sjekk bildet i Telegram og godkjenn i appen.', p_data => jsonb_build_object('catch_id', c.id));
  elsif p_selfie is not null then
    update public.catches set selfie_path = p_selfie where id = c.id returning * into c;
  end if;

  return jsonb_build_object('id', c.id, 'granny_name', gr.name, 'registered_s', c.registered_s);
end
$$;

-- Grannyen svarer ikke lenger, så varselet «ikke bekreftet» (tick_games) skal
-- ikke komme. Fristen settes til et døgn.
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
    "catch_confirm_timeout_s": 86400,
    "telegram_stale_reminder_s": 60,
    "telegram_stale_admin_s": 180,
    "retention_days": 30
  }'::jsonb;
update public.games set rules = rules || '{"catch_confirm_timeout_s": 86400}'::jsonb;

-- ---------------------------------------------------------------------------
-- Side quests for lag og grannyer, levert uten bilde
-- ---------------------------------------------------------------------------
alter table public.quests
  add column audience text not null default 'teams' check (audience in ('teams', 'grannies')),
  add column granny_id uuid references public.grannies on delete cascade,
  add constraint quests_target check ((audience = 'teams' and granny_id is null) or (audience = 'grannies' and team_id is null));

alter table public.quest_submissions
  alter column team_id drop not null,
  alter column storage_path drop not null,
  alter column media drop not null,
  add column granny_id uuid references public.grannies on delete cascade,
  add constraint quest_submissions_who check (num_nonnulls(team_id, granny_id) = 1);
create unique index quest_submissions_one_granny on public.quest_submissions (quest_id, granny_id) where status in ('pending', 'approved');

drop function public.admin_save_quest(uuid, text, text, int, int, uuid);
create function public.admin_save_quest(
  p_id uuid, p_title text, p_description text, p_points int, p_abilities int default 0,
  p_team uuid default null, p_audience text default 'teams', p_granny uuid default null)
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
    insert into public.quests (game_id, title, description, reward_points, reward_abilities, team_id, audience, granny_id)
    values (g.id, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), coalesce(p_points, 0),
            case when aud = 'teams' then coalesce(p_abilities, 0) else 0 end, p_team, aud, p_granny)
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
           team_id = p_team, audience = aud, granny_id = p_granny
     where id = p_id and game_id = g.id returning id into qid;
    if qid is null then raise exception 'Fant ikke oppdraget' using errcode = 'P0002'; end if;
  end if;
  return qid;
end
$$;

-- Lag eller granny markerer et oppdrag som levert. Beviset ligger i Telegram.
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
    insert into public.team_abilities (game_id, team_id, submission_id, granted_s)
    select g.id, sb.team_id, sb.id, s from generate_series(1, q.reward_abilities);
  end if;
  perform public._emit(g.id, s, aud, 'quest_approved', format('«%s» er godkjent!', q.title),
    format('Dere får %sp.', q.reward_points), p_team => sb.team_id, p_granny => sb.granny_id);
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
      'granny_id', gr.id, 'granny_name', gr.name,
      'storage_path', s.storage_path, 'media', s.media,
      'submitted_s', s.submitted_s, 'submitted_at', s.submitted_at
    ) order by s.submitted_at)
    from public.quest_submissions s
    join public.quests q on q.id = s.quest_id
    left join public.teams t on t.id = s.team_id
    left join public.grannies gr on gr.id = s.granny_id
    where s.game_id = p.game_id and s.status = 'pending'), '[]'::jsonb);
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
        'closed', q.closed,
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

-- ---------------------------------------------------------------------------
-- Postkort uten bilde
-- ---------------------------------------------------------------------------
alter table public.photos alter column storage_path drop not null;

create or replace function public.deliver_postkort(p_lat double precision default null, p_lng double precision default null, p_accuracy real default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('team');
  g  public.games;
  t  public.teams;
  z  public.zones;
  s  int;
  ph public.photos;
  dist real;
begin
  select * into g from public.games where id = p.game_id;
  if g.status <> 'running' then raise exception 'Spillet er ikke i gang' using errcode = 'P0001'; end if;
  select * into t from public.teams where id = p.team_id;
  s := public.game_seconds(g);
  select * into z from public.zones
   where game_id = g.id and kind = 'postkort' and opens_at_s <= s and s < closes_at_s
   order by opens_at_s desc limit 1;
  if z is null then raise exception 'Ingen postkort er åpne' using errcode = 'P0001'; end if;
  if exists (select 1 from public.photos where zone_id = z.id and status = 'approved') then
    raise exception 'Postkortet er allerede tatt' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.photos where zone_id = z.id and team_id = t.id and status = 'pending') then
    raise exception 'Dere har allerede levert dette postkortet' using errcode = 'P0001';
  end if;
  if p_lat is not null and p_lng is not null then
    perform public._record_position(p, p_lat, p_lng, p_accuracy);
    dist := extensions.st_distance(z.geom, public._point(p_lat, p_lng));
  end if;
  insert into public.photos (game_id, kind, team_id, zone_id, storage_path, geom, submitted_s, distance_m)
  values (g.id, 'postkort', t.id, z.id, null,
          case when p_lat is null then null else public._point(p_lat, p_lng) end, s, dist)
  returning * into ph;
  perform public._emit(g.id, s, 'admin', 'photo_pending', format('Postkort %s levert av %s', z.number, t.name),
    'Sjekk bildet i Telegram og godkjenn i appen.' || case when dist is null then '' else format(' %s m fra stedet.', round(dist)) end,
    p_data => jsonb_build_object('photo_id', ph.id));
  return jsonb_build_object('id', ph.id, 'status', ph.status);
end
$$;

-- ---------------------------------------------------------------------------
-- Tilgang
-- ---------------------------------------------------------------------------
revoke execute on function
  public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid),
  public.deliver_quest(uuid), public.granny_quests(), public.deliver_postkort(double precision, double precision, real)
from public, anon, authenticated;
grant execute on function
  public.admin_save_quest(uuid, text, text, int, int, uuid, text, uuid),
  public.deliver_quest(uuid), public.granny_quests(), public.deliver_postkort(double precision, double precision, real)
to authenticated;
