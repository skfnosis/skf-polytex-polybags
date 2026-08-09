-- ============================================================================
-- DRAWINGS — a system account for owner withdrawals, tracked separately
-- from ordinary business expenses on the Dashboard.
-- ============================================================================
-- No new posting mechanism needed: Drawings is recorded through the
-- existing Journal Voucher (debit Drawings, credit Cash/Bank) — JV already
-- accepts any chart_of_accounts row as a line target, and v_trial_balance
-- already aggregates ledger_entries per account regardless of type. Adding
-- 'drawings' as its own type (rather than reusing 'expense') is what lets
-- the Dashboard tell "Total Expenses" and "Drawings" apart with a plain
-- type filter instead of matching on the account name.
-- ============================================================================

alter table public.chart_of_accounts drop constraint chart_of_accounts_type_check;
alter table public.chart_of_accounts add constraint chart_of_accounts_type_check
  check (type in ('sales', 'purchase', 'expense', 'cash_bank', 'party', 'drawings'));

insert into public.chart_of_accounts (name, type, is_system)
values ('Owner''s Drawings', 'drawings', true);
