-- Hva en Telegram-konto er koblet til, så boten kan svare «Du er koblet til
-- som …» i stedet for hjelpeteksten når noen skriver i chatten.
create or replace function public.telegram_status(p_user_id bigint)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with links as (
    select case p.role
             when 'team'  then (select name from public.teams where id = p.team_id)
             when 'taxi'  then (select name from public.taxis where id = p.taxi_id)
             when 'admin' then 'spilleder'
             else null end as name,
           pt.muted
      from public.player_telegram pt
      join public.players p on p.user_id = pt.user_id
     where pt.telegram_user_id = p_user_id and pt.chat_id is not null
    union all
    select gr.name, gt.alerts_muted
      from public.granny_telegram gt
      join public.grannies gr on gr.id = gt.granny_id
     where gt.telegram_user_id = p_user_id and gt.chat_id is not null
  )
  select jsonb_build_object(
    'linked', exists (select 1 from links),
    'muted', coalesce(bool_and(muted), false),
    'names', coalesce(jsonb_agg(distinct name) filter (where name is not null), '[]'::jsonb))
  from links
$$;

revoke execute on function public.telegram_status(bigint) from public, anon, authenticated;
grant execute on function public.telegram_status(bigint) to service_role;
