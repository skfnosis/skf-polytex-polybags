-- ============================================================================
-- DASHBOARD — cash/bank tagging, alert-threshold settings, manual stock
-- valuation, and the aggregate read RPCs the new Dashboard screen needs.
-- ============================================================================
-- DESIGN NOTES
-- - app_settings is a singleton config row (same pattern as heartbeat),
--   holding the two alert thresholds from Settings. Admin-writable directly
--   via RLS (same pattern as brand_settings/chart_of_accounts), since it's
--   config, not a financial posting.
-- - cash_bank_kind tags each cash_bank account as 'cash' or 'bank' so the
--   Dashboard can split "Cash in Hand" vs "Bank Balance" without guessing
--   from the account name.
-- - Stock Value is a manually-entered figure per item (items.manual_stock_value),
--   per the "keep stock light" decision — not auto-computed from rates.
-- - v_party_balances / v_invoice_outstanding are security_invoker views so
--   direct client reads (drill-downs, Top Debtors) respect the existing
--   ledger_entries/invoices RLS. The new RPCs are SECURITY DEFINER (like
--   dashboard_summary) but, unlike dashboard_summary, explicitly check
--   has_permission('dashboard','view') — dashboard_summary itself predates
--   this check and is left as-is here, but it has the same gap: any
--   authenticated user can currently call it regardless of page permission.
-- - "Overdue" receivables use a fixed 30-day term for everyone. Because
--   payments aren't required to link to a specific invoice (a payment can
--   be a lump sum against a party's overall balance), v_invoice_outstanding
--   only nets off payments explicitly linked to that invoice — a general
--   unlinked payment reduces the party's real balance but won't show up
--   against a specific invoice here. This is a known approximation.
-- ============================================================================

create table public.app_settings (
  id int primary key default 1,
  low_cash_threshold numeric not null default 0,
  high_payables_threshold numeric not null default 0,
  updated_at timestamptz not null default now(),
  check (id = 1)
);
insert into public.app_settings (id) values (1);

alter table public.app_settings enable row level security;
create policy "app settings readable by dashboard view" on public.app_settings
  for select using (public.has_permission('dashboard','view'));
create policy "admin manages app settings" on public.app_settings for all
  using (coalesce((select is_admin from public.profiles where id = auth.uid()), false));

alter table public.chart_of_accounts add column cash_bank_kind text
  check (cash_bank_kind is null or cash_bank_kind in ('cash','bank'));
update public.chart_of_accounts set cash_bank_kind = 'cash' where name = 'Cash in Hand';
update public.chart_of_accounts set cash_bank_kind = 'bank' where name = 'Bank Account';

alter table public.items add column manual_stock_value numeric;
create policy "admin manages items" on public.items for all
  using (coalesce((select is_admin from public.profiles where id = auth.uid()), false));

create or replace view public.v_party_balances as
select p.id as party_id, p.name, p.type, p.category,
  coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) as balance
from public.parties p
left join public.ledger_entries l on l.party_id = p.id
group by p.id, p.name, p.type, p.category;
alter view public.v_party_balances set (security_invoker = true);

create or replace view public.v_invoice_outstanding as
select i.id as invoice_id, i.invoice_no, i.invoice_type, i.party_id, i.invoice_date, i.total_amount,
  i.total_amount - coalesce((
    select sum(pm.amount) from public.payments pm
    where pm.linked_invoice_id = i.id and pm.status = 'posted'
  ), 0) as outstanding
from public.invoices i
where i.status = 'posted';
alter view public.v_invoice_outstanding set (security_invoker = true);

create or replace function public.dashboard_cashflow(p_from date, p_to date)
returns table(cash_in numeric, cash_out numeric)
language sql security definer stable as $$
  select
    coalesce((select sum(amount) from public.payments
      where direction = 'receipt' and status = 'posted' and payment_date between p_from and p_to), 0),
    coalesce((select sum(amount) from public.payments
      where direction = 'payment' and status = 'posted' and payment_date between p_from and p_to), 0)
    + coalesce((select sum(amount) from public.expenses
      where status = 'posted' and expense_date between p_from and p_to), 0)
  where public.has_permission('dashboard', 'view');
$$;
grant execute on function public.dashboard_cashflow(date, date) to authenticated;
alter function public.dashboard_cashflow(date, date) set search_path = public;

create or replace function public.dashboard_sales_overview(p_from date, p_to date)
returns table(category text, quantity numeric, amount numeric)
language sql security definer stable as $$
  select i.category, coalesce(sum(ii.quantity), 0), coalesce(sum(ii.amount), 0)
  from public.invoices i join public.invoice_items ii on ii.invoice_id = i.id
  where i.invoice_type = 'sale' and i.status = 'posted'
    and i.invoice_date between p_from and p_to
    and public.has_permission('dashboard', 'view')
  group by i.category;
$$;
grant execute on function public.dashboard_sales_overview(date, date) to authenticated;
alter function public.dashboard_sales_overview(date, date) set search_path = public;

create or replace function public.dashboard_top_customers(p_from date, p_to date)
returns table(party_id uuid, name text, total_sales numeric)
language sql security definer stable as $$
  select p.id, p.name, sum(i.total_amount)
  from public.invoices i join public.parties p on p.id = i.party_id
  where i.invoice_type = 'sale' and i.status = 'posted'
    and i.invoice_date between p_from and p_to
    and public.has_permission('dashboard', 'view')
  group by p.id, p.name
  order by sum(i.total_amount) desc
  limit 5;
$$;
grant execute on function public.dashboard_top_customers(date, date) to authenticated;
alter function public.dashboard_top_customers(date, date) set search_path = public;

create or replace function public.dashboard_monthly_profit(p_from date, p_to date)
returns table(month date, brand_key text, sales numeric, purchase numeric, expenses numeric)
language sql security definer stable as $$
  select
    date_trunc('month', gs)::date as month,
    b.brand_key,
    coalesce((select sum(total_amount) from public.invoices
      where invoice_type = 'sale' and status = 'posted' and brand_key = b.brand_key
        and date_trunc('month', invoice_date) = date_trunc('month', gs)), 0),
    coalesce((select sum(total_amount) from public.invoices
      where invoice_type = 'purchase' and status = 'posted' and brand_key = b.brand_key
        and date_trunc('month', invoice_date) = date_trunc('month', gs)), 0),
    coalesce((select sum(amount) from public.expenses
      where status = 'posted' and (brand_key = b.brand_key or brand_key is null)
        and date_trunc('month', expense_date) = date_trunc('month', gs)), 0)
  from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') gs
  cross join public.brand_settings b
  where public.has_permission('dashboard', 'view')
  order by month, b.brand_key;
$$;
grant execute on function public.dashboard_monthly_profit(date, date) to authenticated;
alter function public.dashboard_monthly_profit(date, date) set search_path = public;

create or replace function public.dashboard_receivables_overdue()
returns table(total_receivables numeric, overdue_receivables numeric)
language sql security definer stable as $$
  select
    coalesce((select sum(balance) from public.v_party_balances where type = 'customer' and balance > 0), 0),
    coalesce((select sum(outstanding) from public.v_invoice_outstanding
      where invoice_type = 'sale' and outstanding > 0 and invoice_date < current_date - 30), 0)
  where public.has_permission('dashboard', 'view');
$$;
grant execute on function public.dashboard_receivables_overdue() to authenticated;
alter function public.dashboard_receivables_overdue() set search_path = public;
