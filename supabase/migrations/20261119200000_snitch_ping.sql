-- Endringer 19.11 (2):
--  * Sladring: hver granny kan sladre én gang på en valgfri granny, uten å stå
--    i Kaffekroken. Lagene ser da hvor hun var akkurat da (siste posisjon),
--    som en ekstra ping. Hun blir ikke live, og det er ingen anonym markør.
--  * Nabovakten er tatt ut av appen (ingen databaseendring trengs).

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
  s  int;
begin
  select * into g from public.games where id = p.game_id;
  select * into gr from public.grannies where id = p.granny_id for update;
  s := public._granny_can_act(p, g, gr);
  if gr.is_romling then raise exception 'Rømlingen kan ikke sladre' using errcode = 'P0001'; end if;
  if exists (select 1 from public.snitches where snitch_granny_id = gr.id) then
    raise exception 'Du har allerede sladret' using errcode = 'P0001';
  end if;
  if p_lat is not null and p_lng is not null then
    perform public._record_position(p, p_lat, p_lng, p_accuracy);
  end if;

  select * into target from public.grannies where id = p_target and game_id = g.id;
  if target is null or target.is_romling or target.caught_at_s is not null or target.id = gr.id then
    raise exception 'Du kan ikke sladre på henne' using errcode = 'P0001';
  end if;
  -- Uten posisjon har lagene ingenting å se. Ikke bruk opp sladringen da.
  if public.granny_position_at(target.id, s) is null then
    raise exception 'Vi vet ikke hvor hun er ennå' using errcode = 'P0001';
  end if;

  -- live_until_s = at_s: bare et øyeblikksbilde, aldri live.
  insert into public.snitches (game_id, snitch_granny_id, target_granny_id, at_s, live_until_s)
  values (g.id, gr.id, target.id, s, s);

  perform public._emit(g.id, s, 'teams', 'snitch', 'Noen har sladret.',
    format('%s er pinget på kartet.', target.name), p_data => jsonb_build_object('granny_id', target.id));
  perform public._emit(g.id, s, 'granny', 'snitch_target', 'Noen har sladret på deg.',
    'Lagene ser hvor du var akkurat nå.', p_granny => target.id);
  return public.granny_status();
end
$$;

-- Lagenes kart: sladring er en ekstra ping (felt «snitched» på markøren).
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
    -- En sladring er en ekstra ping for henne: siste posisjon i det øyeblikket.
    select max(at_s) into snitch_s from public.snitches where target_granny_id = gr.id and at_s <= s;
    gping := greatest(gping, snitch_s);

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
      'age_s', show_s - pos.game_s,
      'snitched', live is null and snitch_s is not null and show_s = snitch_s
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
