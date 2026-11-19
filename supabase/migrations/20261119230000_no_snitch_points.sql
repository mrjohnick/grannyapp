-- Sladring gir ikke lenger poeng (19.11). Sladringen er bare en ekstra ping
-- for lagene. finalize_catch er lik forrige versjon, uten 3p-bonusen.

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
  bonus boolean;
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
  update public.catches set status = 'void', resolved_at = now(), resolved_by = p_by
   where granny_id = gr.id and status = 'pending' and id <> c.id;

  update public.grannies set caught_at_s = c.registered_s, caught_by = c.team_id where id = gr.id;

  with o as (
    select x.id, row_number() over (order by x.caught_at_s, cc.registered_at) as rn
    from public.grannies x
    join public.catches cc on cc.granny_id = x.id and cc.status = 'confirmed'
    where x.game_id = g.id and x.caught_at_s is not null and not x.is_romling
  )
  update public.grannies x set catch_order = o.rn from o where x.id = o.id;

  -- Bonus-granny: ingen lag har henne som egen granny.
  bonus := not gr.is_romling and not exists (select 1 from public.teams tt where tt.assigned_granny_id = gr.id);
  pts := case
    when gr.is_romling then 20
    when t.assigned_granny_id = gr.id then 15
    when bonus then coalesce((g.rules->>'catch_points_bonus')::int, 20)
    else 10 end;
  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  values (g.id, t.id, pts, case when gr.is_romling then 'romling' when bonus then 'fangst_bonus' else 'fangst' end, c.id, c.registered_s);

  insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s)
  select g.id, t.id, 2, 'fotoalbum_tilbake', ph.id, c.registered_s
  from public.photos ph
  where ph.kind = 'fotoalbum' and ph.status = 'approved'
    and ph.granny_id = gr.id and ph.target_team_id = t.id
    and not exists (select 1 from public.points_ledger l where l.reason = 'fotoalbum_tilbake' and l.ref_id = ph.id);


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
