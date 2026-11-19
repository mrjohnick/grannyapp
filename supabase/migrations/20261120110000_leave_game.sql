-- «Logg ut» i appen: fjern telefonen fra spillet, så den ikke telles som en
-- telefon på laget og ikke får varsler lenger. Telegram-koblingen for
-- telefonen forsvinner med (player_telegram følger players).
create or replace function public.leave_game()
returns void
language sql security definer
set search_path = ''
as $$
  delete from public.players where user_id = (select auth.uid())
$$;

revoke execute on function public.leave_game() from public, anon, authenticated;
grant execute on function public.leave_game() to authenticated;
