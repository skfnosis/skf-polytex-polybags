-- ============================================================================
-- DASHBOARD — Month-wise Sales/Purchase/Expenses/Profit breakdown, correctly
-- sourced from real postings (replaces dashboard_monthly_profit).
-- ============================================================================
-- dashboard_monthly_profit's "expenses" column read from public.expenses —
-- a standalone expense-entry table from the original schema that nothing in
-- the app has written to since expenses moved to Payment Vouchers (CPV/BPV)
-- and Journal Vouchers posted against expense-type chart_of_accounts rows.
-- That made the Growth chart's Total Profit line silently overstate profit
-- (expenses always read as 0). This migration replaces it with a single RPC
-- that sources expenses from ledger_entries/chart_of_accounts — the same
-- real posting data every other report in this app already uses — and adds
-- the Fabric/Poly Bag sales split the new month-wise dashboard table needs,
-- so the chart and the table share one source of truth instead of two.
--
-- Not brand-split: expenses (CPV/BPV/JV postings) carry no brand_key in the
-- schema, so "Expenses" and "Profit" are company-wide per month, same as
-- the existing Dashboard "Expense & Drawings" row already treats them.
-- Drawings are deliberately excluded from Profit (owner withdrawal, not a
-- business expense), matching the pre-existing dashboard semantics.
-- ============================================================================

drop function if exists public.dashboard_monthly_profit(date, date);

create or replace function public.dashboard_monthly_breakdown(p_from date, p_to date)
returns table(
  month date,
  fabric_sales numeric,
  polybag_sales numeric,
  total_sales numeric,
  total_purchase numeric,
  expenses numeric,
  profit numeric
)
language sql security definer stable as $$
  with months as (
    select date_trunc('month', gs)::date as month
    from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') gs
  ),
  sales as (
    select date_trunc('month', i.invoice_date)::date as month, b.category, sum(i.total_amount) as amt
    from public.invoices i
    join public.brand_settings b on b.brand_key = i.brand_key
    where i.invoice_type = 'sale' and i.status = 'posted'
    group by 1, 2
  ),
  purchases as (
    select date_trunc('month', i.invoice_date)::date as month, sum(i.total_amount) as amt
    from public.invoices i
    where i.invoice_type = 'purchase' and i.status = 'posted'
    group by 1
  ),
  expense_totals as (
    select date_trunc('month', l.entry_date)::date as month, sum(l.debit) - sum(l.credit) as amt
    from public.ledger_entries l
    join public.chart_of_accounts a on a.id = l.account_id
    where a.type = 'expense'
    group by 1
  )
  select
    m.month,
    coalesce((select amt from sales s where s.month = m.month and s.category = 'fabric'), 0) as fabric_sales,
    coalesce((select amt from sales s where s.month = m.month and s.category = 'polybags'), 0) as polybag_sales,
    coalesce((select sum(amt) from sales s where s.month = m.month), 0) as total_sales,
    coalesce((select amt from purchases p where p.month = m.month), 0) as total_purchase,
    coalesce((select amt from expense_totals e where e.month = m.month), 0) as expenses,
    coalesce((select sum(amt) from sales s where s.month = m.month), 0)
      - coalesce((select amt from purchases p where p.month = m.month), 0)
      - coalesce((select amt from expense_totals e where e.month = m.month), 0) as profit
  from months m
  where public.has_permission('dashboard', 'view')
  order by m.month;
$$;
grant execute on function public.dashboard_monthly_breakdown(date, date) to authenticated;
alter function public.dashboard_monthly_breakdown(date, date) set search_path = public;
