-- Blindhet er tatt ut av spillet (19.11). Fotoalbumet gir fortsatt 2p til
-- grannyen og -2p til laget, men laget blir ikke blindt, og samme lag kan tas
-- med igjen uten sperretid.

create or replace function public.admin_review_photo(p_photo uuid, p_approve boolean, p_target_team uuid default null, p_note text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  p  public.players := public._player('admin');
  ph public.photos;
  g  public.games;
  t  public.teams;
  gr public.grannies;
  z  public.zones;
  s  int;
  tid uuid;
begin
  select * into ph from public.photos where id = p_photo and game_id = p.game_id for update;
  if ph is null then raise exception 'Fant ikke bildet' using errcode = 'P0002'; end if;
  if ph.status <> 'pending' then raise exception 'Bildet er allerede behandlet' using errcode = 'P0001'; end if;
  select * into g from public.games where id = ph.game_id;
  s := public.game_seconds(g);

  if not p_approve then
    update public.photos set status = 'rejected', reviewed_at = now(), note = p_note where id = ph.id;
    if ph.granny_id is not null then
      perform public._emit(g.id, s, 'granny', 'photo_rejected', 'Bildet ble ikke godkjent', p_note, p_granny => ph.granny_id);
    else
      perform public._emit(g.id, s, 'team', 'photo_rejected', 'Postkortet ble ikke godkjent', p_note, p_team => ph.team_id);
    end if;
    return;
  end if;

  if ph.kind = 'fotoalbum' then
    tid := coalesce(p_target_team, ph.target_team_id);
    select * into t from public.teams where id = tid and game_id = g.id;
    if t is null then raise exception 'Velg laget på bildet' using errcode = 'P0001'; end if;
    select * into gr from public.grannies where id = ph.granny_id;

    update public.photos set status = 'approved', reviewed_at = now(), target_team_id = t.id where id = ph.id;
    insert into public.points_ledger (game_id, granny_id, delta, reason, ref_id, at_s) values (g.id, gr.id, 2, 'fotoalbum', ph.id, s);
    insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, -2, 'fotoalbum', ph.id, s);
    -- Har laget allerede fanget fotografen, får det poengene tilbake med en gang.
    if gr.caught_by = t.id then
      insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, 2, 'fotoalbum_tilbake', ph.id, s);
    end if;
    -- Ingen blindhet lenger. Raden (from_s = until_s) er bare for at laget skal
    -- se bildet i «Dere i Fotoalbumet» (team_status) med en gang.
    insert into public.blinds (game_id, team_id, photo_id, from_s, until_s)
    values (g.id, t.id, ph.id, s, s);

    perform public._emit(g.id, s, 'team', 'album_photo', 'Dere er tatt med i Fotoalbumet.',
      'Dere mister 2p. Se bildet under Poeng.', p_team => t.id);
    perform public._emit(g.id, s, 'granny', 'photo_approved', 'Fotoalbumet: godkjent!',
      format('Du får 2p, og %s mister 2p.', t.name), p_granny => gr.id);

  elsif ph.kind = 'postkort' then
    select * into z from public.zones where id = ph.zone_id;
    if exists (select 1 from public.photos where zone_id = ph.zone_id and status = 'approved') then
      raise exception 'Postkortet er allerede tatt' using errcode = 'P0001';
    end if;
    select * into t from public.teams where id = ph.team_id;
    update public.photos set status = 'approved', reviewed_at = now() where id = ph.id;
    insert into public.points_ledger (game_id, team_id, delta, reason, ref_id, at_s) values (g.id, t.id, 2, 'postkort', ph.id, s);
    perform public._emit(g.id, s, 'teams', 'postkort_won', format('Postkort %s er tatt av %s.', z.number, t.name),
      p_dedupe => 'postkort_won:' || z.id);

  else
    update public.photos set status = 'approved', reviewed_at = now() where id = ph.id;
  end if;
end
$$;
