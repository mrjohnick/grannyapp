-- Utenfor spillområdet (20.11): grannyen får varsel med en gang, en nedtelling
-- i appen til hun blir live for alle lag, og beskjed når hun er inne igjen.
-- Spilleder får varsel når hun blir live. Selve regelen er uendret: live etter
-- out_of_area_grace_s utenfor (granny_live_reason = 'utenfor').

-- Spillsekundet hun blir live fordi hun er utenfor. Null: hun er inne, har
-- ingen posisjon, er fanget, eller spillet har ikke noe spillområde.
create or replace function public._out_live_at(p_granny uuid, p_s int)
returns int
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
  if gr.caught_at_s is not null then return null; end if;
  select * into g from public.games where id = gr.game_id;
  select geom into area from public.zones where game_id = g.id and kind = 'area';
  if area is null then return null; end if;
  latest := public.granny_position_at(p_granny, p_s);
  if latest is null or extensions.st_covers(area, latest.geom) then return null; end if;
  select max(game_s) into last_inside from public.positions
   where granny_id = p_granny and game_s <= p_s and extensions.st_covers(area, geom);
  return coalesce(last_inside, 0) + coalesce((g.rules->>'out_of_area_grace_s')::int, 60);
end
$$;

-- Kjøres av pg_cron hvert 10. sekund.
create or replace function public.tick_out_of_area()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  g  public.games;
  gr public.grannies;
  s  int;
  live_at int;
  open_id bigint;
begin
  for g in select * from public.games where status = 'running'
           and exists (select 1 from public.zones z where z.game_id = games.id and z.kind = 'area') loop
    s := public.game_seconds(g);
    for gr in select * from public.grannies where game_id = g.id and caught_at_s is null and not is_romling loop
      live_at := public._out_live_at(gr.id, s);

      if live_at is null then
        -- Inne igjen: si fra én gang for den siste advarselen som står åpen.
        select max(e.id) into open_id from public.events e
         where e.game_id = g.id and e.granny_id = gr.id and e.kind = 'out_of_area';
        if open_id is not null then
          perform public._emit(g.id, s, 'granny', 'out_back', 'Du er inne i spillområdet igjen.',
            'Du er ikke lenger live.', p_granny => gr.id, p_dedupe => 'out_back:' || open_id);
        end if;
        continue;
      end if;

      perform public._emit(g.id, s, 'granny', 'out_of_area', 'Du er utenfor spillområdet!',
        case when s < live_at then format('Gå inn igjen. Om %s sek blir du live for alle lag.', live_at - s)
             else 'Du er live for alle lag til du er inne igjen.' end,
        p_granny => gr.id, p_data => jsonb_build_object('live_at_s', live_at),
        p_dedupe => 'out:' || gr.id || ':' || live_at);

      if s >= live_at then
        perform public._emit(g.id, s, 'granny', 'out_live', 'Du er live for alle lag.',
          'Gå inn i spillområdet igjen, så er du skjult.', p_granny => gr.id,
          p_dedupe => 'out_live:' || gr.id || ':' || live_at);
        perform public._emit(g.id, s, 'admin', 'out_live', format('%s er utenfor området og er live.', gr.name), null,
          p_dedupe => 'out_live_admin:' || gr.id || ':' || live_at);
      end if;
    end loop;
  end loop;
end
$$;

select cron.schedule('granny-area', '10 seconds', 'select public.tick_out_of_area()');

-- Appen: nedtelling hos grannyen.
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
    -- Utenfor spillområdet: når hun blir (eller ble) live for alle lag.
    'out_of_area', (select case when x is null then null else jsonb_build_object('live_at_s', x) end
                    from (select public._out_live_at(gr.id, s) as x) o),
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

revoke execute on function public._out_live_at(uuid, int), public.tick_out_of_area() from public, anon, authenticated;
