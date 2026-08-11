-- ============================================================================
-- CHART OF ACCOUNTS — Opening Balance (+ a lightweight Parent Account field)
-- ============================================================================
-- Parties already had opening-balance support (create_party). This extends
-- the same idea to any chart_of_accounts row (expense/asset/liability/
-- capital/income/cash_bank) created from the Accounts tab, which previously
-- went through a raw client-side insert with no opening-balance concept at
-- all.
--
-- Accounting rule: an opening balance is NOT a sale/purchase/receipt/
-- payment — it must net against a dedicated Opening Balance Equity account,
-- never against Sales/Purchase (unlike the parties shortcut, which offsets
-- against Sales/Purchase; that's an existing, separate design predating
-- this migration and is left alone here). Every opening balance posted by
-- this new path always has a real, named contra account, so trial balance
-- stays in balance.
-- ============================================================================

alter table public.chart_of_accounts add column parent_account_id uuid references public.chart_of_accounts(id);

insert into public.chart_of_accounts (name, type, is_system)
values ('Opening Balance Equity', 'capital', true);

create or replace function public.create_account(
  p_name text, p_type text, p_cash_bank_kind text default null,
  p_parent_account_id uuid default null,
  p_opening_balance numeric default 0, p_opening_balance_type text default 'debit'
) returns uuid language plpgsql security definer as $$
declare
  v_account_id uuid;
  v_equity_account_id uuid;
  v_debit numeric;
  v_credit numeric;
begin
  if not coalesce((select is_admin from public.profiles where id = auth.uid()), false) then
    raise exception 'Admin only';
  end if;
  if p_opening_balance_type not in ('debit', 'credit') then
    raise exception 'Opening balance type must be debit or credit';
  end if;

  insert into public.chart_of_accounts (name, type, cash_bank_kind, parent_account_id)
  values (p_name, p_type, case when p_type = 'cash_bank' then p_cash_bank_kind else null end, p_parent_account_id)
  returning id into v_account_id;

  if p_opening_balance > 0 then
    select id into v_equity_account_id from public.chart_of_accounts where name = 'Opening Balance Equity' and is_system limit 1;

    if p_opening_balance_type = 'debit' then
      v_debit := p_opening_balance; v_credit := 0;
    else
      v_debit := 0; v_credit := p_opening_balance;
    end if;

    insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id, narration)
    values (current_date, v_account_id, v_debit, v_credit, 'opening_balance', v_account_id, 'Opening balance');
    insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id, narration)
    values (current_date, v_equity_account_id, v_credit, v_debit, 'opening_balance', v_account_id, 'Opening balance — ' || p_name);
  end if;

  return v_account_id;
end; $$;
grant execute on function public.create_account(text, text, text, uuid, numeric, text) to authenticated;
alter function public.create_account(text, text, text, uuid, numeric, text) set search_path = public;
