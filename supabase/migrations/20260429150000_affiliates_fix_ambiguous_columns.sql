-- Fix "column reference is ambiguous" in three affiliate functions.
-- Each function's RETURNS TABLE OUT params (status, created_at) collided with
-- same-named columns in the queried tables (licenses, affiliate_referrals,
-- affiliate_clicks). Alias the tables and qualify the column refs.
--
-- CREATE OR REPLACE FUNCTION preserves existing grants, so no re-grant needed.

-- ─── affiliate_create_for_self ─────────────────────────────────────────────
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

  if not exists (
    select 1 from public.licenses l
     where l.user_id = v_user
       and l.status  = 'active'
       and l.source <> 'stripe'
  ) then
    raise exception 'not eligible';
  end if;

  select * into v_aff from public.affiliates a where a.user_id = v_user;
  if not found then
    insert into public.affiliates (user_id, code)
    values (v_user, public._gen_affiliate_code())
    returning * into v_aff;
  end if;

  v_pct := coalesce(v_aff.commission_pct, public._default_commission_pct());

  return query select v_aff.id, v_aff.code, v_aff.status, v_pct, v_aff.created_at;
end;
$$;


-- ─── affiliate_my_summary ──────────────────────────────────────────────────
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

  select * into v_aff from public.affiliates a where a.user_id = v_user;
  if not found then
    return;
  end if;

  return query
  with
    clicks as (
      select
        count(*)::bigint                                                            as total,
        count(*) filter (where c.created_at >= now() - interval '30 days')::bigint  as last_30
      from public.affiliate_clicks c
      where c.affiliate_id = v_aff.id
    ),
    sales as (
      select
        count(*)::bigint                                                              as total,
        count(*) filter (where r.created_at >= now() - interval '30 days')::bigint    as last_30,
        coalesce(sum(r.commission_cents) filter (where r.status = 'pending'), 0)::bigint as pending,
        coalesce(sum(r.commission_cents) filter (where r.status = 'paid'),    0)::bigint as paid
      from public.affiliate_referrals r
      where r.affiliate_id = v_aff.id
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


-- ─── admin_list_affiliates ─────────────────────────────────────────────────
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
      count(*)::bigint                                                              as total,
      count(*) filter (where ac.created_at >= now() - interval '30 days')::bigint   as last_30
    from public.affiliate_clicks ac
    where ac.affiliate_id = a.id
  ) c on true
  left join lateral (
    select
      count(*)::bigint                                                                 as total,
      coalesce(sum(ar.commission_cents) filter (where ar.status = 'pending'), 0)::bigint as pending,
      coalesce(sum(ar.commission_cents) filter (where ar.status = 'paid'),    0)::bigint as paid
    from public.affiliate_referrals ar
    where ar.affiliate_id = a.id
  ) r on true
  order by a.created_at desc;
end;
$$;
