-- Eksplisitte tilganger, uavhengig av «Automatically expose new tables» i
-- Supabase. Klienter (authenticated) kan bare lese, og RLS bestemmer hvilke
-- rader. Alle skrivinger går via security definer-funksjonene.
-- Nye tabeller får ingen tilgang før en migrasjon gir den.

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on all tables in schema public to authenticated;

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
