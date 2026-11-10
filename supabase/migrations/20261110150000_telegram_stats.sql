-- Måling av Telegram live-posisjon, for felttesten.
-- Svarer på: hvor ofte kommer posisjonene, hvor store er hullene, hvor
-- nøyaktige er de. Tidspunktene er fra Telegram (date/edit_date), ikke
-- når webhooken ble kalt.

create or replace function public.admin_telegram_stats(p_window_min int default 30)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  p public.players;
begin
  select * into p from public.players where user_id = (select auth.uid());
  if p is null or p.role <> 'admin' then
    raise exception 'Bare for spilleder' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'window_min', p_window_min,
    'grannies', coalesce((
      select jsonb_agg(row_to_json(s)::jsonb order by s.name)
      from (
        select
          gr.id,
          gr.name,
          gt.telegram_user_id is not null as linked,
          count(d.recorded_at)::int as updates,
          percentile_cont(0.5) within group (order by d.gap_s)  as median_gap_s,
          percentile_cont(0.9) within group (order by d.gap_s)  as p90_gap_s,
          max(d.gap_s)                                          as max_gap_s,
          percentile_cont(0.5) within group (order by d.accuracy_m) as median_accuracy_m,
          extract(epoch from now() - max(d.recorded_at))::int   as last_age_s,
          bool_or(d.live_period is not null)                     as live
        from public.grannies gr
        left join public.granny_telegram gt on gt.granny_id = gr.id
        left join lateral (
          select pos.recorded_at, pos.accuracy_m, pos.live_period,
                 extract(epoch from pos.recorded_at - lag(pos.recorded_at) over (order by pos.recorded_at, pos.id)) as gap_s
          from public.positions pos
          where pos.granny_id = gr.id
            and pos.source = 'telegram'
            and pos.recorded_at > now() - make_interval(mins => p_window_min)
        ) d on true
        where gr.game_id = p.game_id
        group by gr.id, gr.name, gt.telegram_user_id
      ) s
    ), '[]'::jsonb)
  );
end
$$;

revoke execute on function public.admin_telegram_stats(int) from public, anon;
grant execute on function public.admin_telegram_stats(int) to authenticated;
