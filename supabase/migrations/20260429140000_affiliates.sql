-- Affiliate program: free-copy holders generate a referral link, sales tracked
-- via Stripe `client_reference_id`, payouts handled manually outside Stripe.
--
-- Apply via Supabase SQL editor or `supabase db push`.

-- ─── app_settings (single-row key/value, RPC-managed) ──────────────────────
create table if not exists public.app_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

insert into public.app_settings (key, value)
values ('default_commission_pct', '20')
on conflict (key) do nothing;


-- ─── affiliates ────────────────────────────────────────────────────────────
create table if not exists public.affiliates (
  id              bigint generated always as identity primary key,
  user_id         uuid not null unique references auth.users(id) on delete cascade,
  code            text not null unique,
  -- null = use the global default in app_settings
  commission_pct  numeric(5,2),
  status          text not null default 'active' check (status in ('active','paused')),
  created_at      timestamptz not null default now()
);

create index if not exists affiliates_code_idx on public.affiliates (code);

alter table public.affiliates enable row level security;
revoke all on public.affiliates from anon, authenticated;

-- Affiliates see their own row.
drop policy if exists "affiliates can read own row" on public.affiliates;
create policy "affiliates can read own row"
  on public.affiliates
  for select
  to authenticated
  using (user_id = auth.uid());

-- Admins can read all rows (for the admin dashboard).
drop policy if exists "admins can read all affiliates" on public.affiliates;
create policy "admins can read all affiliates"
  on public.affiliates
  for select
  to authenticated
  using (public.is_admin(auth.uid()));


-- ─── affiliate_referrals ───────────────────────────────────────────────────
create table if not exists public.affiliate_referrals (
  id               bigint generated always as identity primary key,
  affiliate_id     bigint not null references public.affiliates(id) on delete cascade,
  license_id       bigint not null unique references public.licenses(id) on delete cascade,
  amount_cents     bigint not null default 0,
  currency         text   not null default 'usd',
  commission_pct   numeric(5,2) not null,
  commission_cents bigint not null default 0,
  status           text   not null default 'pending'
                     check (status in ('pending','paid','reversed')),
  payout_note      text,
  paid_at          timestamptz,
  created_at       timestamptz not null default now()
);

create index if not exists affiliate_referrals_affiliate_idx on public.affiliate_referrals (affiliate_id, created_at desc);
create index if not exists affiliate_referrals_status_idx    on public.affiliate_referrals (status);

alter table public.affiliate_referrals enable row level security;
revoke all on public.affiliate_referrals from anon, authenticated;

-- Affiliates see their own referrals.
drop policy if exists "affiliates can read own referrals" on public.affiliate_referrals;
create policy "affiliates can read own referrals"
  on public.affiliate_referrals
  for select
  to authenticated
  using (
    affiliate_id in (select id from public.affiliates where user_id = auth.uid())
  );

drop policy if exists "admins can read all referrals" on public.affiliate_referrals;
create policy "admins can read all referrals"
  on public.affiliate_referrals
  for select
  to authenticated
  using (public.is_admin(auth.uid()));


-- ─── affiliate_clicks (deduped per ua_hash per UTC day) ────────────────────
create table if not exists public.affiliate_clicks (
  id            bigint generated always as identity primary key,
  affiliate_id  bigint not null references public.affiliates(id) on delete cascade,
  ua_hash       text   not null,
  country       text,
  path          text,
  day           date   not null default (now() at time zone 'utc')::date,
  created_at    timestamptz not null default now()
);

create unique index if not exists affiliate_clicks_dedupe_idx
  on public.affiliate_clicks (affiliate_id, ua_hash, day);
create index if not exists affiliate_clicks_affiliate_day_idx
  on public.affiliate_clicks (affiliate_id, day desc);

alter table public.affiliate_clicks enable row level security;
revoke all on public.affiliate_clicks from anon, authenticated;


-- ─── Helpers ───────────────────────────────────────────────────────────────
-- Random 8-char code from a Crockford-ish alphabet (no I/L/O/0/1/U) so codes
-- are easy to read back over voice/DM.
create or replace function public._gen_affiliate_code()
returns text
language plpgsql
as $$
declare
  v_alphabet text := 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
  v_code     text;
  v_attempt  int := 0;
begin
  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    if not exists (select 1 from public.affiliates where code = v_code) then
      return v_code;
    end if;
    v_attempt := v_attempt + 1;
    if v_attempt > 12 then
      raise exception 'could not allocate unique affiliate code';
    end if;
  end loop;
end;
$$;

create or replace function public._default_commission_pct()
returns numeric
language sql
stable
as $$
  select coalesce(
    (select value::numeric from public.app_settings where key = 'default_commission_pct'),
    20
  );
$$;


-- ─── User RPC: opt in (idempotent) ─────────────────────────────────────────
-- Eligibility: caller has at least one active license whose source = 'admin'
-- (i.e. a free copy issued by us). Returns the row whether new or existing.
create or replace function public.affiliate_create_for_self()
returns table (
  id              bigint,
  code            text,
  status          text,
  commission_pct  numeric,
  created_at      timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_aff  public.affiliates%rowtype;
  v_pct  numeric;
begin
  if v_user is null then
    raise exception 'not signed in';
  end if;

  -- Eligibility: any active license that wasn't a Stripe purchase
  -- (i.e. admin-issued or gifted = a free copy from us).
  if not exists (
    select 1 from public.licenses
     where user_id = v_user and status = 'active' and source <> 'stripe'
  ) then
    raise exception 'not eligible';
  end if;

  select * into v_aff from public.affiliates where user_id = v_user;
  if not found then
    insert into public.affiliates (user_id, code)
    values (v_user, public._gen_affiliate_code())
    returning * into v_aff;
  end if;

  v_pct := coalesce(v_aff.commission_pct, public._default_commission_pct());

  return query select v_aff.id, v_aff.code, v_aff.status, v_pct, v_aff.created_at;
end;
$$;

revoke all on function public.affiliate_create_for_self() from public;
grant execute on function public.affiliate_create_for_self() to authenticated;


-- ─── User RPC: my dashboard stats ──────────────────────────────────────────
create or replace function public.affiliate_my_summary()
returns table (
  id                       bigint,
  code                     text,
  status                   text,
  commission_pct           numeric,
  clicks_total             bigint,
  clicks_30d               bigint,
  sales_total              bigint,
  sales_30d                bigint,
  commission_pending_cents bigint,
  commission_paid_cents    bigint,
  currency                 text,
  recent                   jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_aff  public.affiliates%rowtype;
begin
  if v_user is null then
    raise exception 'not signed in';
  end if;

  select * into v_aff from public.affiliates where user_id = v_user;
  if not found then
    return;
  end if;

  return query
  with
    clicks as (
      select
        count(*)::bigint                                                          as total,
        count(*) filter (where created_at >= now() - interval '30 days')::bigint  as last_30
      from public.affiliate_clicks where affiliate_id = v_aff.id
    ),
    sales as (
      select
        count(*)::bigint                                                          as total,
        count(*) filter (where created_at >= now() - interval '30 days')::bigint  as last_30,
        coalesce(sum(commission_cents) filter (where status = 'pending'), 0)::bigint as pending,
        coalesce(sum(commission_cents) filter (where status = 'paid'), 0)::bigint    as paid
      from public.affiliate_referrals where affiliate_id = v_aff.id
    ),
    recent as (
      select coalesce(jsonb_agg(item order by row_idx), '[]'::jsonb) as items
      from (
        select
          row_number() over (order by r.created_at desc) as row_idx,
          jsonb_build_object(
            'created_at',       r.created_at,
            'amount_cents',     r.amount_cents,
            'commission_cents', r.commission_cents,
            'commission_pct',   r.commission_pct,
            'currency',         r.currency,
            'status',           r.status
          ) as item
        from public.affiliate_referrals r
        where r.affiliate_id = v_aff.id
        order by r.created_at desc
        limit 25
      ) sub
    )
  select
    v_aff.id,
    v_aff.code,
    v_aff.status,
    coalesce(v_aff.commission_pct, public._default_commission_pct()),
    clicks.total,
    clicks.last_30,
    sales.total,
    sales.last_30,
    sales.pending,
    sales.paid,
    'usd'::text,
    recent.items
  from clicks, sales, recent;
end;
$$;

revoke all on function public.affiliate_my_summary() from public;
grant execute on function public.affiliate_my_summary() to authenticated;


-- ─── Public RPC: track a click ─────────────────────────────────────────────
-- Public; deduped per (affiliate, ua_hash, UTC day) so refreshes don't pad.
create or replace function public.track_affiliate_click(
  p_code text,
  p_path text default null
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_aff_id    bigint;
  v_headers   jsonb;
  v_ip        text;
  v_ua        text;
  v_country   text;
  v_ua_hash   text;
  v_day       date := (now() at time zone 'utc')::date;
begin
  if p_code is null or length(trim(p_code)) = 0 then return; end if;

  select id into v_aff_id from public.affiliates
   where code = upper(trim(p_code)) and status = 'active';
  if v_aff_id is null then return; end if;

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
  v_ua_hash := encode(digest(trim(v_ip) || '|' || v_ua, 'sha256'), 'hex');

  if p_path is not null and length(p_path) > 512 then
    p_path := left(p_path, 512);
  end if;

  insert into public.affiliate_clicks (affiliate_id, ua_hash, country, path, day)
  values (v_aff_id, v_ua_hash, v_country, nullif(p_path, ''), v_day)
  on conflict (affiliate_id, ua_hash, day) do nothing;
end;
$$;

revoke all on function public.track_affiliate_click(text, text) from public;
grant execute on function public.track_affiliate_click(text, text) to anon, authenticated;


-- ─── Webhook helper: attribute a Stripe sale to an affiliate ──────────────
-- Called by the Stripe webhook Edge Function (which runs as service_role).
-- Returns the new referral id, or null if attribution didn't apply (no code,
-- unknown code, paused affiliate, self-referral, non-stripe license, dup).
create or replace function public.affiliate_attribute_sale(
  p_license_id  bigint,
  p_code        text,
  p_buyer_email text default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_aff       public.affiliates%rowtype;
  v_license   public.licenses%rowtype;
  v_pct       numeric;
  v_amount    bigint;
  v_currency  text;
  v_aff_email text;
  v_id        bigint;
begin
  if p_license_id is null then return null; end if;
  if p_code is null or length(trim(p_code)) = 0 then return null; end if;

  select * into v_aff from public.affiliates
   where code = upper(trim(p_code)) and status = 'active';
  if not found then return null; end if;

  select * into v_license from public.licenses where id = p_license_id;
  if not found then return null; end if;
  if v_license.source <> 'stripe' then return null; end if;

  -- Anti-self-referral: buyer email == affiliate's auth email.
  if p_buyer_email is not null and length(trim(p_buyer_email)) > 0 then
    select email into v_aff_email from auth.users where id = v_aff.user_id;
    if v_aff_email is not null
       and lower(trim(p_buyer_email)) = lower(trim(v_aff_email)) then
      return null;
    end if;
  end if;

  -- Idempotent on license_id (one referral per sale).
  if exists (select 1 from public.affiliate_referrals where license_id = p_license_id) then
    return null;
  end if;

  v_amount   := coalesce(v_license.amount_cents, 0);
  v_currency := coalesce(v_license.currency, 'usd');
  v_pct      := coalesce(v_aff.commission_pct, public._default_commission_pct());

  insert into public.affiliate_referrals (
    affiliate_id, license_id, amount_cents, currency,
    commission_pct, commission_cents, status
  ) values (
    v_aff.id, p_license_id, v_amount, v_currency,
    v_pct, floor(v_amount * v_pct / 100)::bigint, 'pending'
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.affiliate_attribute_sale(bigint, text, text) from public, anon, authenticated;
grant execute on function public.affiliate_attribute_sale(bigint, text, text) to service_role;


-- ─── Admin RPCs ────────────────────────────────────────────────────────────
create or replace function public.admin_get_default_commission_pct()
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  return public._default_commission_pct();
end;
$$;

revoke all on function public.admin_get_default_commission_pct() from public;
grant execute on function public.admin_get_default_commission_pct() to authenticated;


create or replace function public.admin_set_default_commission_pct(p_pct numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_pct is null or p_pct < 0 or p_pct > 100 then
    raise exception 'commission_pct must be between 0 and 100';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('default_commission_pct', p_pct::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end;
$$;

revoke all on function public.admin_set_default_commission_pct(numeric) from public;
grant execute on function public.admin_set_default_commission_pct(numeric) to authenticated;


create or replace function public.admin_set_affiliate_commission(
  p_affiliate_id bigint,
  p_pct          numeric  -- pass null to fall back to default
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_pct is not null and (p_pct < 0 or p_pct > 100) then
    raise exception 'commission_pct must be between 0 and 100';
  end if;
  update public.affiliates set commission_pct = p_pct where id = p_affiliate_id;
  if not found then
    raise exception 'affiliate not found';
  end if;
end;
$$;

revoke all on function public.admin_set_affiliate_commission(bigint, numeric) from public;
grant execute on function public.admin_set_affiliate_commission(bigint, numeric) to authenticated;


create or replace function public.admin_set_affiliate_status(
  p_affiliate_id bigint,
  p_status       text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_status not in ('active','paused') then
    raise exception 'status must be active or paused';
  end if;
  update public.affiliates set status = p_status where id = p_affiliate_id;
  if not found then
    raise exception 'affiliate not found';
  end if;
end;
$$;

revoke all on function public.admin_set_affiliate_status(bigint, text) from public;
grant execute on function public.admin_set_affiliate_status(bigint, text) to authenticated;


create or replace function public.admin_list_affiliates()
returns table (
  id                       bigint,
  user_id                  uuid,
  email                    text,
  code                     text,
  status                   text,
  commission_pct_override  numeric,
  commission_pct_effective numeric,
  clicks_total             bigint,
  clicks_30d               bigint,
  sales_total              bigint,
  commission_pending_cents bigint,
  commission_paid_cents    bigint,
  created_at               timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_default numeric := public._default_commission_pct();
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;

  return query
  select
    a.id,
    a.user_id,
    u.email::text,
    a.code,
    a.status,
    a.commission_pct,
    coalesce(a.commission_pct, v_default),
    coalesce(c.total, 0),
    coalesce(c.last_30, 0),
    coalesce(r.total, 0),
    coalesce(r.pending, 0),
    coalesce(r.paid, 0),
    a.created_at
  from public.affiliates a
  left join auth.users u on u.id = a.user_id
  left join lateral (
    select
      count(*)::bigint                                                         as total,
      count(*) filter (where created_at >= now() - interval '30 days')::bigint as last_30
    from public.affiliate_clicks where affiliate_id = a.id
  ) c on true
  left join lateral (
    select
      count(*)::bigint                                                              as total,
      coalesce(sum(commission_cents) filter (where status = 'pending'), 0)::bigint  as pending,
      coalesce(sum(commission_cents) filter (where status = 'paid'),    0)::bigint  as paid
    from public.affiliate_referrals where affiliate_id = a.id
  ) r on true
  order by a.created_at desc;
end;
$$;

revoke all on function public.admin_list_affiliates() from public;
grant execute on function public.admin_list_affiliates() to authenticated;


create or replace function public.admin_list_referrals(
  p_status       text   default null,
  p_affiliate_id bigint default null,
  p_limit        int    default 100
) returns table (
  id               bigint,
  affiliate_id     bigint,
  affiliate_code   text,
  affiliate_email  text,
  license_id       bigint,
  buyer_email      text,
  amount_cents     bigint,
  currency         text,
  commission_pct   numeric,
  commission_cents bigint,
  status           text,
  payout_note      text,
  paid_at          timestamptz,
  created_at       timestamptz
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
    r.id,
    r.affiliate_id,
    a.code,
    au.email::text,
    r.license_id,
    bu.email::text,
    r.amount_cents,
    r.currency,
    r.commission_pct,
    r.commission_cents,
    r.status,
    r.payout_note,
    r.paid_at,
    r.created_at
  from public.affiliate_referrals r
  join public.affiliates a on a.id = r.affiliate_id
  left join auth.users au on au.id = a.user_id
  left join public.licenses l on l.id = r.license_id
  left join auth.users bu on bu.id = l.user_id
  where (p_status is null or r.status = p_status)
    and (p_affiliate_id is null or r.affiliate_id = p_affiliate_id)
  order by r.created_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

revoke all on function public.admin_list_referrals(text, bigint, int) from public;
grant execute on function public.admin_list_referrals(text, bigint, int) to authenticated;


create or replace function public.admin_mark_referral_paid(
  p_referral_id bigint,
  p_payout_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  update public.affiliate_referrals
     set status      = 'paid',
         paid_at     = now(),
         payout_note = nullif(trim(coalesce(p_payout_note, '')), '')
   where id = p_referral_id and status = 'pending';
  if not found then
    raise exception 'referral not found or not pending';
  end if;
end;
$$;

revoke all on function public.admin_mark_referral_paid(bigint, text) from public;
grant execute on function public.admin_mark_referral_paid(bigint, text) to authenticated;
