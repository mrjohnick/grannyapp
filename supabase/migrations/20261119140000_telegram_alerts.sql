-- Varsler i Telegram. Alle telefoner (lag, taxi, spilleder) kan koble seg til
-- boten og få de samme varslene som push. Grannyer som har koblet seg til for
-- live-posisjon får varslene i samme chat. Telegram viser varselet på låst
-- skjerm selv om nettleseren ikke gjør det.

-- Kobling per telefon (spiller). Bare serveren leser denne.
-- Tokenet starter med «v», så webhooken skiller det fra grannyenes hex-token.
create table public.player_telegram (
  user_id          uuid primary key references public.players on delete cascade,
  link_token       text not null unique default 'v' || encode(extensions.gen_random_bytes(12), 'hex'),
  telegram_user_id bigint,
  chat_id          bigint,
  linked_at        timestamptz,
  muted            boolean not null default false
);
alter table public.player_telegram enable row level security;

-- Grannyer kan skru av varslene med /stopp og fortsatt dele posisjon.
alter table public.granny_telegram add column alerts_muted boolean not null default false;

-- ---------------------------------------------------------------------------
-- Appen: status og lenke til boten for denne telefonen
-- ---------------------------------------------------------------------------
create or replace function public.my_telegram_alerts()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player();
  pt public.player_telegram;
  gt public.granny_telegram;
begin
  -- Grannyen kobler seg til via posisjonsdelingen. Samme lenke gir varsler.
  if p.role = 'granny' then
    insert into public.granny_telegram (granny_id) values (p.granny_id) on conflict do nothing;
    select * into gt from public.granny_telegram where granny_id = p.granny_id;
    return jsonb_build_object('link_token', gt.link_token, 'linked', gt.chat_id is not null and not gt.alerts_muted);
  end if;
  insert into public.player_telegram (user_id) values (p.user_id) on conflict do nothing;
  select * into pt from public.player_telegram where user_id = p.user_id;
  return jsonb_build_object('link_token', pt.link_token, 'linked', pt.chat_id is not null and not pt.muted);
end
$$;

-- ---------------------------------------------------------------------------
-- Webhooken (service_role)
-- ---------------------------------------------------------------------------

-- /start <token>. Kobler en granny (posisjon og varsler) eller en telefon (varsler).
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
    return jsonb_build_object('ok', true, 'kind', 'player', 'name', who);
  end if;

  res := public.telegram_link(p_token, p_user_id, p_chat_id);
  if not coalesce((res->>'ok')::boolean, false) then return jsonb_build_object('ok', false); end if;
  update public.granny_telegram set alerts_muted = false where link_token = p_token;
  return jsonb_build_object('ok', true, 'kind', 'granny', 'name', res->>'granny_name');
end
$$;

-- /stopp og /start uten token: skru varslene av eller på for denne Telegram-kontoen.
create or replace function public.telegram_set_muted(p_user_id bigint, p_muted boolean)
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  n int;
  m int;
begin
  update public.player_telegram set muted = p_muted where telegram_user_id = p_user_id and chat_id is not null;
  get diagnostics n = row_count;
  update public.granny_telegram set alerts_muted = p_muted where telegram_user_id = p_user_id and chat_id is not null;
  get diagnostics m = row_count;
  return n + m;
end
$$;

-- ---------------------------------------------------------------------------
-- game-worker: varsler som skal sendes, med push-abonnementer og Telegram-chatter
-- ---------------------------------------------------------------------------
create or replace function public.worker_claim_events()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  with claimed as (
    update public.events e set pushed_at = now()
    where e.id in (
      select id from public.events
      where pushed_at is null and created_at > now() - interval '5 minutes'
      order by id limit 200
      for update skip locked)
    returning e.*
  ),
  -- Hvem som skal ha hvert varsel. Spilleder får bare det som er ment for spilleder.
  recipients as (
    select c.id as event_id, p.*
    from claimed c
    join public.events ee on ee.id = c.id
    join public.players p on p.game_id = ee.game_id
    where case when p.role = 'admin' then ee.audience = 'admin' else public._event_for(ee, p) end
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'kind', c.kind, 'title', c.title, 'body', c.body,
    'subs', coalesce((
      select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from recipients r
      join public.push_subscriptions s on s.user_id = r.user_id
      where r.event_id = c.id
    ), '[]'::jsonb),
    'chats', coalesce((
      select jsonb_agg(distinct x.chat_id)
      from (
        select pt.chat_id from recipients r
        join public.player_telegram pt on pt.user_id = r.user_id
        where r.event_id = c.id and pt.chat_id is not null and not pt.muted
        union
        select gt.chat_id from recipients r
        join public.granny_telegram gt on gt.granny_id = r.granny_id
        where r.event_id = c.id and r.role = 'granny' and gt.chat_id is not null and not gt.alerts_muted
      ) x
    ), '[]'::jsonb)
  ) order by c.id), '[]'::jsonb)
  into result
  from claimed c;
  return result;
end
$$;

-- Brukeren har blokkert boten. Slutt å sende dit.
create or replace function public.worker_telegram_blocked(p_chat_id bigint)
returns void
language sql security definer set search_path = ''
as $$
  update public.player_telegram set chat_id = null where chat_id = p_chat_id;
  update public.granny_telegram set alerts_muted = true where chat_id = p_chat_id;
$$;

-- ---------------------------------------------------------------------------
-- Spilleder: hvem har Telegram-varsler
-- ---------------------------------------------------------------------------
create or replace function public.admin_telegram_alerts()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player('admin');
begin
  return jsonb_build_object(
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color,
        'phones', (select count(*) from public.players pl where pl.team_id = t.id),
        'telegram', (select count(*) from public.players pl join public.player_telegram pt on pt.user_id = pl.user_id
                      where pl.team_id = t.id and pt.chat_id is not null and not pt.muted)
      ) order by t.name)
      from public.teams t where t.game_id = p.game_id), '[]'::jsonb),
    'taxis', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name,
        'phones', (select count(*) from public.players pl where pl.taxi_id = x.id),
        'telegram', (select count(*) from public.players pl join public.player_telegram pt on pt.user_id = pl.user_id
                      where pl.taxi_id = x.id and pt.chat_id is not null and not pt.muted)
      ) order by x.name)
      from public.taxis x where x.game_id = p.game_id), '[]'::jsonb),
    'grannies', jsonb_build_object(
      'total', (select count(*) from public.grannies g where g.game_id = p.game_id),
      'telegram', (select count(*) from public.grannies g join public.granny_telegram gt on gt.granny_id = g.id
                    where g.game_id = p.game_id and gt.chat_id is not null and not gt.alerts_muted)),
    'admins', jsonb_build_object(
      'phones', (select count(*) from public.players pl where pl.game_id = p.game_id and pl.role = 'admin'),
      'telegram', (select count(*) from public.players pl join public.player_telegram pt on pt.user_id = pl.user_id
                    where pl.game_id = p.game_id and pl.role = 'admin' and pt.chat_id is not null and not pt.muted))
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Tilgang
-- ---------------------------------------------------------------------------
revoke execute on function
  public.my_telegram_alerts(), public.admin_telegram_alerts(),
  public.telegram_start(text, bigint, bigint), public.telegram_set_muted(bigint, boolean),
  public.worker_telegram_blocked(bigint)
from public, anon, authenticated;

grant execute on function public.my_telegram_alerts(), public.admin_telegram_alerts() to authenticated;
grant execute on function
  public.telegram_start(text, bigint, bigint), public.telegram_set_muted(bigint, boolean),
  public.worker_telegram_blocked(bigint)
to service_role;
