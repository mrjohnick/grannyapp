-- Spillerens egen innloggingskode, så appen kan holde den i adressen
-- (?kode=…) og vise «Kopier lenke». Da virker «Åpne i nettleser» fra
-- Telegram, og det er lett å flytte innloggingen til en annen nettleser.
create or replace function public.my_join_code()
returns text
language sql stable security definer
set search_path = ''
as $$
  select c.code
    from public.players p
    join public.join_codes c on c.game_id = p.game_id and c.role = p.role
     and c.team_id is not distinct from p.team_id
     and c.granny_id is not distinct from p.granny_id
     and c.taxi_id is not distinct from p.taxi_id
   where p.user_id = (select auth.uid())
   order by c.code
   limit 1
$$;

revoke execute on function public.my_join_code() from public, anon, authenticated;
grant execute on function public.my_join_code() to authenticated;
