-- Analytics: first-party, cookieless event tracking + admin dashboard RPCs.
--
-- Apply via Supabase SQL editor or `supabase db push`.

-- Supabase keeps extensions in the `extensions` schema. pgcrypto is usually
-- already installed; the line below is idempotent either way.
create extension if not exists pgcrypto with schema extensions;

-- ─── Table ─────────────────────────────────────────────────────────────────
create table if not exists public.analytics_events (
  id           bigint generated always as identity primary key,
  event_name   text   not null,
  anon_id      text   not null,
  user_id      uuid   references auth.users(id) on delete set null,
  path         text,
  referrer     text,
  country      text,
  ua_hash      text,
  props        jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists analytics_events_created_at_idx on public.analytics_events (created_at desc);
create index if not exists analytics_events_event_name_idx on public.analytics_events (event_name);
create index if not exists analytics_events_anon_id_idx    on public.analytics_events (anon_id);
create index if not exists analytics_events_user_id_idx    on public.analytics_events (user_id) where user_id is not null;
create index if not exists analytics_events_path_idx       on public.analytics_events (path);

-- RLS: lock the table down. Writes go through track_event(); reads through admin RPCs.
alter table public.analytics_events enable row level security;
revoke all on public.analytics_events from anon, authenticated;

-- ─── Writer ────────────────────────────────────────────────────────────────
-- Public RPC. Derives anon_id from request headers (IP + UA + daily salt) so
-- the client cannot spoof identity. Captures user_id from the JWT when present.
create or replace function public.track_event(
  p_event_name text,
  p_path       text default null,
  p_referrer   text default null,
  p_props      jsonb default null
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_headers jsonb;
  v_ip       text;
  v_ua       text;
  v_country  text;
  v_anon_id  text;
  v_user_id  uuid;
  v_salt     text;
begin
  -- Whitelist of valid event names. Reject anything else so the table can't
  -- be polluted with arbitrary strings from a malicious caller.
  if p_event_name is null or p_event_name not in (
    'pageview',
    'cta_click',
    'demo_opened',
    'signin_started',
    'signin_completed',
    'license_activated',
    'download_clicked'
  ) then
    raise exception 'invalid event_name: %', p_event_name;
  end if;

  if p_path is not null and length(p_path) > 512 then
    p_path := left(p_path, 512);
  end if;
  if p_referrer is not null and length(p_referrer) > 512 then
    p_referrer := left(p_referrer, 512);
  end if;

  begin
    v_headers := current_setting('request.headers', true)::jsonb;
  exception when others then
    v_headers := '{}'::jsonb;
  end;

  v_ip := coalesce(
    split_part(v_headers->>'x-forwarded-for', ',', 1),
    v_headers->>'cf-connecting-ip',
    v_headers->>'x-real-ip',
    'unknown'
  );
  v_ua      := coalesce(v_headers->>'user-agent', '');
  v_country := nullif(v_headers->>'cf-ipcountry', '');

  -- Daily-rotating hash. Same visitor on same UTC day → same anon_id.
  v_salt    := to_char((now() at time zone 'utc')::date, 'YYYY-MM-DD') || '|mv-analytics';
  v_anon_id := encode(digest(trim(v_ip) || '|' || v_ua || '|' || v_salt, 'sha256'), 'hex');

  begin
    v_user_id := auth.uid();
  exception when others then
    v_user_id := null;
  end;

  insert into public.analytics_events (
    event_name, anon_id, user_id, path, referrer, country, ua_hash, props
  ) values (
    p_event_name,
    v_anon_id,
    v_user_id,
    nullif(p_path, ''),
    nullif(p_referrer, ''),
    v_country,
    encode(digest(v_ua, 'sha256'), 'hex'),
    p_props
  );
end;
$$;

revoke all on function public.track_event(text, text, text, jsonb) from public;
grant execute on function public.track_event(text, text, text, jsonb) to anon, authenticated;

-- ─── Admin reader RPCs ─────────────────────────────────────────────────────
-- All gated by public.is_admin() (already exists in this project).

create or replace function public.analytics_summary(
  p_start timestamptz,
  p_end   timestamptz
) returns table (
  total_pageviews    bigint,
  unique_visitors    bigint,
  signed_in_visitors bigint,
  cta_clicks         bigint,
  demo_opens         bigint,
  signin_started     bigint,
  signin_completed   bigint,
  download_clicks    bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  return query
  select
    count(*) filter (where event_name = 'pageview'),
    count(distinct anon_id) filter (where event_name = 'pageview'),
    count(distinct user_id) filter (where user_id is not null),
    count(*) filter (where event_name = 'cta_click'),
    count(*) filter (where event_name = 'pageview' and path like '/demo%'),
    count(*) filter (where event_name = 'signin_started'),
    count(*) filter (where event_name = 'signin_completed'),
    count(*) filter (where event_name = 'download_clicked')
  from public.analytics_events
  where created_at >= p_start and created_at < p_end;
end;
$$;

revoke all on function public.analytics_summary(timestamptz, timestamptz) from public;
grant execute on function public.analytics_summary(timestamptz, timestamptz) to authenticated;


create or replace function public.analytics_pageviews_by_day(
  p_start timestamptz,
  p_end   timestamptz
) returns table (
  day             date,
  pageviews       bigint,
  unique_visitors bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  return query
  with days as (
    select generate_series(
      date_trunc('day', p_start at time zone 'utc')::date,
      date_trunc('day', (p_end - interval '1 second') at time zone 'utc')::date,
      interval '1 day'
    )::date as day
  )
  select
    d.day,
    coalesce(count(e.id) filter (where e.event_name = 'pageview'), 0)::bigint,
    coalesce(count(distinct e.anon_id) filter (where e.event_name = 'pageview'), 0)::bigint
  from days d
  left join public.analytics_events e
    on (e.created_at at time zone 'utc')::date = d.day
   and e.created_at >= p_start
   and e.created_at <  p_end
  group by d.day
  order by d.day;
end;
$$;

revoke all on function public.analytics_pageviews_by_day(timestamptz, timestamptz) from public;
grant execute on function public.analytics_pageviews_by_day(timestamptz, timestamptz) to authenticated;


create or replace function public.analytics_top_pages(
  p_start timestamptz,
  p_end   timestamptz,
  p_limit int default 10
) returns table (
  path            text,
  pageviews       bigint,
  unique_visitors bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  return query
  select
    e.path,
    count(*)::bigint,
    count(distinct e.anon_id)::bigint
  from public.analytics_events e
  where e.event_name = 'pageview'
    and e.created_at >= p_start
    and e.created_at <  p_end
    and e.path is not null
  group by e.path
  order by count(*) desc
  limit greatest(1, least(coalesce(p_limit, 10), 100));
end;
$$;

revoke all on function public.analytics_top_pages(timestamptz, timestamptz, int) from public;
grant execute on function public.analytics_top_pages(timestamptz, timestamptz, int) to authenticated;


create or replace function public.analytics_top_referrers(
  p_start timestamptz,
  p_end   timestamptz,
  p_limit int default 10
) returns table (
  referrer    text,
  pageviews   bigint,
  visitors    bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  return query
  select
    -- Strip protocol/path; group by host so "google.com/?q=..." collapses.
    coalesce(
      regexp_replace(e.referrer, '^https?://([^/]+).*$', '\1'),
      '(direct)'
    ) as host,
    count(*)::bigint,
    count(distinct e.anon_id)::bigint
  from public.analytics_events e
  where e.event_name = 'pageview'
    and e.created_at >= p_start
    and e.created_at <  p_end
    and (e.referrer is null or e.referrer not ilike 'https://www.mockvaultps.com%' )
    and (e.referrer is null or e.referrer not ilike 'https://mockvaultps.com%')
  group by host
  order by count(*) desc
  limit greatest(1, least(coalesce(p_limit, 10), 100));
end;
$$;

revoke all on function public.analytics_top_referrers(timestamptz, timestamptz, int) from public;
grant execute on function public.analytics_top_referrers(timestamptz, timestamptz, int) to authenticated;


create or replace function public.analytics_top_countries(
  p_start timestamptz,
  p_end   timestamptz,
  p_limit int default 10
) returns table (
  country   text,
  visitors  bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  return query
  select
    coalesce(e.country, '??'),
    count(distinct e.anon_id)::bigint
  from public.analytics_events e
  where e.event_name = 'pageview'
    and e.created_at >= p_start
    and e.created_at <  p_end
  group by coalesce(e.country, '??')
  order by count(distinct e.anon_id) desc
  limit greatest(1, least(coalesce(p_limit, 10), 100));
end;
$$;

revoke all on function public.analytics_top_countries(timestamptz, timestamptz, int) from public;
grant execute on function public.analytics_top_countries(timestamptz, timestamptz, int) to authenticated;
