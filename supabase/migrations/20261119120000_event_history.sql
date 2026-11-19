-- Varslingssiden: alle varsler spilleren har fått i dette spillet, ikke bare de
-- siste 15 minuttene som my_events() gir. De nyeste 300, eldst først.
create or replace function public.my_event_history()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players := public._player();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id, 'at_s', e.at_s, 'kind', e.kind, 'title', e.title, 'body', e.body,
      'audience', e.audience, 'data', e.data, 'created_at', e.created_at
    ) order by e.id)
    from (
      select * from public.events e
      where e.game_id = p.game_id and public._event_for(e, p)
      order by e.id desc
      limit 300
    ) e
  ), '[]'::jsonb);
end
$$;

revoke execute on function public.my_event_history() from public, anon, authenticated;
grant execute on function public.my_event_history() to authenticated;
