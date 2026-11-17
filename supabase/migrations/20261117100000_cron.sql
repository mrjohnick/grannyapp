-- Klokke og bakgrunnsjobber.
--
-- * tick_games() hvert 15. sekund: ping, postkort, 0:45, blindhet over, slutt.
-- * Hvert nytt varsel vekker game-worker, som sender Web Push.
-- * Hver natt: slett spill eldre enn 30 dager, og la game-worker rydde bildene.
--
-- game-worker sin adresse ligger i public.app_settings (nøkkel «worker_url»).
-- Uten den sendes ingen push, men alt annet virker. Se docs/DEPLOY.md.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create or replace function public.kick_worker(p_task text default 'push')
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  url text;
begin
  select value into url from public.app_settings where key = 'worker_url';
  if url is null then return; end if;
  perform net.http_post(
    url := url,
    body := jsonb_build_object('task', p_task),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 10000);
exception when others then
  -- Push er ikke kritisk. Et varsel skal aldri stoppe en handling i spillet.
  raise warning 'kick_worker: %', sqlerrm;
end
$$;

create or replace function public.tg_events_kick()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.kick_worker('push');
  return null;
end
$$;

create trigger events_kick after insert on public.events
  for each statement execute function public.tg_events_kick();

revoke execute on function public.kick_worker(text), public.tg_events_kick() from public, anon, authenticated;

select cron.schedule('granny-tick', '15 seconds', 'select public.tick_games()');
-- Reserve: plukker opp push som ikke ble sendt (f.eks. hvis workeren sov).
select cron.schedule('granny-push', '* * * * *', 'select public.kick_worker(''push'')');
select cron.schedule('granny-purge', '17 3 * * *', 'select public.purge_expired_games(); select public.kick_worker(''purge'')');
