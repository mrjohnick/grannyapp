-- Taxier kan dele live-posisjon med boten i Telegram, som grannyene (20.11).
-- Posisjonen kommer da fram også når taxi-appen er lukket eller sjåføren
-- bruker et navigasjonsprogram. Taxien bruker samme kobling som for varsler.

create or replace function public.telegram_ingest_location(
  p_user_id bigint, p_lat double precision, p_lng double precision,
  p_accuracy real default null, p_live_period int default null, p_at timestamptz default now())
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  gt public.granny_telegram;
  gr public.grannies;
  geo extensions.geography := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
  n int;
begin
  select * into gt from public.granny_telegram where telegram_user_id = p_user_id;
  if gt.granny_id is not null then
    select * into gr from public.grannies where id = gt.granny_id;
    -- Telegram kan levere forsinket (f.eks. etter et webhook-avbrudd). Bruk
    -- tidspunktet fra meldingen, men aldri et tidspunkt i fremtiden.
    insert into public.positions (game_id, granny_id, source, geom, accuracy_m, live_period, recorded_at)
    values (gr.game_id, gr.id, 'telegram', geo, p_accuracy, p_live_period, least(p_at, now()));
    if p_live_period is not null then
      update public.granny_telegram set last_live_period = p_live_period where granny_id = gr.id;
    end if;
    return jsonb_build_object('ok', true, 'is_live', p_live_period is not null, 'kind', 'granny');
  end if;

  -- Taxi: kontoen er koblet til en taxi-telefon via player_telegram.
  insert into public.positions (game_id, taxi_id, user_id, source, geom, accuracy_m, live_period, recorded_at)
  select distinct on (p.taxi_id) p.game_id, p.taxi_id, p.user_id, 'telegram', geo, p_accuracy, p_live_period, least(p_at, now())
    from public.player_telegram pt
    join public.players p on p.user_id = pt.user_id
   where pt.telegram_user_id = p_user_id and pt.chat_id is not null and p.role = 'taxi' and p.taxi_id is not null;
  get diagnostics n = row_count;
  if n > 0 then
    return jsonb_build_object('ok', true, 'is_live', p_live_period is not null, 'kind', 'taxi');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'not_linked');
end
$$;

create or replace function public.telegram_start(p_token text, p_user_id bigint, p_chat_id bigint)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  pt public.player_telegram;
  p  public.players;
  res jsonb;
  who text;
begin
  if p_token like 'v%' then
    update public.player_telegram
       set telegram_user_id = p_user_id, chat_id = p_chat_id, linked_at = now(), muted = false
     where link_token = p_token
    returning * into pt;
    if pt.user_id is null then return jsonb_build_object('ok', false); end if;
    select * into p from public.players where user_id = pt.user_id;
    who := case p.role
      when 'team'  then (select name from public.teams where id = p.team_id)
      when 'taxi'  then (select name from public.taxis where id = p.taxi_id)
      when 'admin' then 'Spilleder'
      else null end;
    return jsonb_build_object('ok', true, 'kind', 'player', 'role', p.role, 'name', who);
  end if;

  res := public.telegram_link(p_token, p_user_id, p_chat_id);
  if not coalesce((res->>'ok')::boolean, false) then return jsonb_build_object('ok', false); end if;
  update public.granny_telegram set alerts_muted = false where link_token = p_token;
  return jsonb_build_object('ok', true, 'kind', 'granny', 'name', res->>'granny_name');
end
$$;

-- Appen: taxien ser også når Telegram sist sendte posisjonen.
create or replace function public.my_telegram_alerts()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player();
  pt public.player_telegram;
  gt public.granny_telegram;
  last_at timestamptz;
begin
  -- Grannyen kobler seg til via posisjonsdelingen. Samme lenke gir varsler.
  if p.role = 'granny' then
    insert into public.granny_telegram (granny_id) values (p.granny_id) on conflict do nothing;
    select * into gt from public.granny_telegram where granny_id = p.granny_id;
    return jsonb_build_object('link_token', gt.link_token, 'linked', gt.chat_id is not null and not gt.alerts_muted);
  end if;
  insert into public.player_telegram (user_id) values (p.user_id) on conflict do nothing;
  select * into pt from public.player_telegram where user_id = p.user_id;
  if p.role = 'taxi' then
    select max(recorded_at) into last_at from public.positions where taxi_id = p.taxi_id and source = 'telegram';
  end if;
  return jsonb_build_object(
    'link_token', pt.link_token,
    'linked', pt.chat_id is not null and not pt.muted,
    'last_position_age_s', case when last_at is null then null else extract(epoch from now() - last_at)::int end);
end
$$;
