-- Fangst: laget registrerer, grannyen bekrefter (eller velger lag), og
-- spilleder avgjør hvis hun ikke svarer innen 2 min eller sier nei.
--
-- Regler fra specen og beslutningene 10. nov:
-- * Registreringstidspunktet avgjør rekkefølgen, ikke når hun bekrefter.
-- * Flere lag kan registrere samme granny. Hun velger hvilket lag som tok henne.
-- * Egen granny 15p, andre 10p, Rømlingen 20p (krever lisens).
-- * Fanger laget fotografen sin, får det 2p tilbake per bilde.
-- * Sladrehanken får 3p hvis den hun sladret på fanges innen 10 min.
-- * Honnørrabatt: 3p ved fangst hvis hun har vært fri i minst 75 min og tatt
--   2 taxiturer eller færre. (Grannies som aldri fanges, får det ved slutt.)
-- * Plasseringspoeng (0–20) regnes ut fra catch_order i oppsummeringen,
--   så de blir riktige selv om bekreftelser kommer i feil rekkefølge.

alter table public.catches add column admin_reviewed_at timestamptz;
create unique index one_open_claim_per_team on public.catches (granny_id, team_id) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Felles: gjør en fangst endelig
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
  s  record;
  pts int;
begin
  select * into c from public.catches where id = p_catch for update;
  if c is null then raise exception 'Fant ikke fangsten' using errcode = 'P0002'; end if;
  select * into gr from public.grannies where id = c.granny_id for update;
  if gr.caught_at_s is not null then raise exception 'Hun er allerede fanget' using errcode = 'P0001'; end if;
  select * into t from public.teams where id = c.team_id;
  select * into g from public.games where id = c.game_id;

  update public.catches set status = 'confirmed', resolved_at = now(), resolved_by = p_by,
         admin_reviewed_at = case when p_by = 'admin' then now() else admin_reviewed_at end
   where id = c.id;
  -- Andre åpne krav på samme granny faller bort.
  update public.catches set status = 'void', resolved_at = now(), resolved_by = p_by
   where granny_id = gr.id and status = 'pending' and id <> c.id;

  update public.grannies set caught_at_s = c.registered_s, caught_by = c.team_id where id = gr.id;

  -- Rekkefølge etter registreringstid (Rømlingen telles ikke).
  with o as (
    select x.id, row_number() over (order by x.caught_at_s, cc.registered_at) as rn
    from public.grannies x
    join public.catches cc on cc.granny_id = x.id and cc.status = 'confirmed'
    where x.game_id = g.id and x.caught_at_s is not null and not x.is_romling
  )
  update public.grannies x set catch_order = o.rn from o where x.id = o.id;

  -- Lagets poeng
  pts := case when gr.is_romling then 20 when t.assigned_granny_id = gr.id then 15 else 10 end;
  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  values (g.id, t.id, pts, case when gr.is_romling then 'romling' else 'fangst' end, c.id, c.registered_s);

  -- Fotoalbumet: laget får tilbake 2p per bilde fotografen tok av dem.
  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  select g.id, t.id, 2, 'fotoalbum_tilbake', ph.id, c.registered_s
  from public.photos ph
  where ph.kind = 'fotoalbum' and ph.status = 'approved'
    and ph.granny_id = gr.id and ph.target_team_id = t.id
    and not exists (select 1 from public.points_ledger l where l.reason = 'fotoalbum_tilbake' and l.ref_id = ph.id);

  -- Sladrehanken
  for s in
    select * from public.snitches
    where target_granny_id = gr.id and not bonus_awarded
      and c.registered_s - at_s between 0 and (g.rules->>'snitch_bonus_window_s')::int
  loop
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s)
    values (g.id, s.snitch_granny_id, 3, 'sladrehank', s.id, c.registered_s);
    update public.snitches set bonus_awarded = true where id = s.id;
  end loop;

  -- Honnørrabatt
  if not gr.is_romling
     and c.registered_s >= (g.rules->>'honnor_min_free_s')::int
     and (select count(*) from public.taxi_rides where granny_id = gr.id) <= (g.rules->>'honnor_max_rides')::int
  then
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s)
    values (g.id, gr.id, 3, 'honnorrabatt', c.id, c.registered_s);
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Lag: registrer fangst (L2)
-- ---------------------------------------------------------------------------
create or replace function public.register_catch(p_granny uuid)
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

  select * into gr from public.grannies where id = p_granny and game_id = g.id;
  if gr is null then raise exception 'Fant ikke grannyen' using errcode = 'P0002'; end if;
  if gr.caught_at_s is not null then raise exception 'Hun er allerede fanget' using errcode = 'P0001'; end if;
  if gr.is_romling and (s < g.romling_reveal_s or t.license_at_s is null) then
    raise exception 'Krever lisens' using errcode = 'P0001';
  end if;

  -- Samme lag to ganger: bruk det åpne kravet.
  select * into c from public.catches where granny_id = gr.id and team_id = t.id and status = 'pending';
  if c is null then
    insert into public.catches (game_id, granny_id, team_id, registered_by, registered_s)
    values (g.id, gr.id, t.id, p.user_id, s)
    returning * into c;
  end if;

  return jsonb_build_object('id', c.id, 'granny_name', gr.name, 'registered_s', c.registered_s);
end
$$;

-- Lagets fangster (for ventevisningen etter registrering).
create or replace function public.team_catches()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'granny_id', c.granny_id, 'granny_name', gr.name,
    'status', c.status, 'registered_s', c.registered_s,
    'age_s', extract(epoch from now() - c.registered_at)::int,
    'admin_deciding', c.status = 'rejected' and c.admin_reviewed_at is null
  ) order by c.registered_at desc), '[]'::jsonb)
  from public.catches c
  join public.grannies gr on gr.id = c.granny_id
  where c.team_id = public.my_team_id()
    and c.registered_at > now() - interval '30 minutes'
$$;

-- ---------------------------------------------------------------------------
-- Granny: se og svare på krav (G5)
-- ---------------------------------------------------------------------------
create or replace function public.granny_pending_catches()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'team_id', t.id, 'team_name', t.name, 'team_color', t.color,
    'registered_s', c.registered_s,
    'age_s', extract(epoch from now() - c.registered_at)::int
  ) order by c.registered_at), '[]'::jsonb)
  from public.catches c
  join public.teams t on t.id = c.team_id
  where c.granny_id = public.my_granny_id() and c.status = 'pending'
$$;

-- p_catch = kravet hun bekrefter. p_accept = false: ingen tok henne,
-- alle åpne krav går til spilleder.
create or replace function public.granny_respond_catch(p_catch uuid, p_accept boolean)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  me uuid := public.my_granny_id();
  c public.catches;
begin
  if me is null then raise exception 'Bare for grannies' using errcode = '42501'; end if;

  if p_accept then
    select * into c from public.catches where id = p_catch and granny_id = me and status = 'pending';
    if c is null then raise exception 'Kravet er ikke åpent lenger' using errcode = 'P0001'; end if;
    perform public.finalize_catch(c.id, 'granny');
  else
    update public.catches set status = 'rejected', resolved_at = now(), resolved_by = 'granny'
     where granny_id = me and status = 'pending';
  end if;
  return public.game_state();
end
$$;

-- ---------------------------------------------------------------------------
-- Spilleder: kø og avgjørelse (S1)
-- ---------------------------------------------------------------------------
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
      'age_s', extract(epoch from now() - c.registered_at)::int,
      'overdue', c.status = 'pending' and now() - c.registered_at > make_interval(secs => (g.rules->>'catch_confirm_timeout_s')::int),
      'competing', (select count(*) from public.catches x where x.granny_id = c.granny_id and x.status = 'pending')::int
    ) order by c.registered_at)
    from public.catches c
    join public.grannies gr on gr.id = c.granny_id
    join public.teams t on t.id = c.team_id
    where c.game_id = g.id
      and (c.status = 'pending' or (c.status = 'rejected' and c.admin_reviewed_at is null))
  ), '[]'::jsonb);
end
$$;

create or replace function public.admin_resolve_catch(p_catch uuid, p_accept boolean)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  c public.catches;
begin
  select * into c from public.catches where id = p_catch;
  if c is null or not public.is_admin_of(c.game_id) then
    raise exception 'Bare for spilleder' using errcode = '42501';
  end if;
  if p_accept then
    perform public.finalize_catch(c.id, 'admin');
  else
    update public.catches set status = 'rejected', resolved_at = coalesce(resolved_at, now()),
           resolved_by = coalesce(resolved_by, 'admin'), admin_reviewed_at = now()
     where id = c.id;
  end if;
end
$$;

grant execute on function
  public.register_catch(uuid),
  public.team_catches(),
  public.granny_pending_catches(),
  public.granny_respond_catch(uuid, boolean),
  public.admin_catch_queue(),
  public.admin_resolve_catch(uuid, boolean)
to authenticated;

-- Postgres gir PUBLIC kjøretilgang til alle nye funksjoner, og
-- «alter default privileges in schema» kan ikke ta det bort. Derfor
-- eksplisitt: interne hjelpere skal ikke kunne kalles av klienter.
revoke execute on function public.finalize_catch(uuid, text) from public, anon, authenticated;
