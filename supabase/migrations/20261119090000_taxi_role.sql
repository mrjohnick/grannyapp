-- Ny rolle: taxisjåfør. Ligger i egen fil, fordi en ny enum-verdi ikke kan
-- brukes i samme transaksjon som den lages.
alter type public.player_role add value if not exists 'taxi';
