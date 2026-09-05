-- ============================================================================
-- Add an optional cheque number to Bank Receipt/Payment vouchers (BRV/BPV).
-- Cash vouchers (CRV/CPV) never show this field — there's no cheque to
-- reference.
-- ============================================================================

alter table public.payments add column cheque_no text;

-- Adding a parameter to record_payment creates a NEW overload under
-- CREATE OR REPLACE rather than replacing the old one — drop the old
-- 9-arg signature explicitly so it can't be called to bypass validation
-- added here later, same class of stale-overload issue fixed before.
drop function if exists public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text, uuid);

create or replace function public.record_payment(
  p_payment_date date, p_party_id uuid, p_direction text, p_amount numeric,
  p_method text, p_cash_bank_account_id uuid, p_linked_invoice_id uuid, p_notes text,
  p_direct_account_id uuid default null, p_cheque_no text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_payment_id uuid;
  v_other_account uuid;
  v_kind text;
  v_voucher_no text;
begin
  if not public.has_permission('entry_voucher', 'create') then
    raise exception 'Not permitted to record vouchers';
  end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if not exists (
    select 1 from public.chart_of_accounts where id = p_cash_bank_account_id and type = 'cash_bank'
  ) then
    raise exception 'Selected account is not a cash/bank account';
  end if;
  if (p_party_id is null) = (p_direct_account_id is null) then
    raise exception 'Provide exactly one of a party or an account to pay';
  end if;

  if p_direct_account_id is not null then
    if p_direction <> 'payment' then
      raise exception 'Only a payment (money out) can be posted directly to an account';
    end if;
    if not exists (
      select 1 from public.chart_of_accounts where id = p_direct_account_id and type in ('expense', 'drawings')
    ) then
      raise exception 'Selected account must be an expense or drawings account';
    end if;
    v_other_account := p_direct_account_id;
  else
    select ledger_account_id into v_other_account from public.parties where id = p_party_id;
  end if;

  select cash_bank_kind into v_kind from public.chart_of_accounts where id = p_cash_bank_account_id;
  v_voucher_no := public.next_voucher_no(p_direction, coalesce(v_kind, 'cash'));

  insert into public.payments (voucher_no, payment_date, party_id, direct_account_id, direction, amount, method,
                                cash_bank_account_id, linked_invoice_id, notes, cheque_no, created_by)
  values (v_voucher_no, p_payment_date, p_party_id, p_direct_account_id, p_direction, p_amount, p_method,
          p_cash_bank_account_id, p_linked_invoice_id, p_notes, nullif(p_cheque_no, ''), auth.uid())
  returning id into v_payment_id;

  if p_direction = 'receipt' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, p_amount, 0, 'payment', v_payment_id, p_notes, v_voucher_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, v_other_account, p_party_id, 0, p_amount, 'payment', v_payment_id, p_notes, v_voucher_no);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, v_other_account, p_party_id, p_amount, 0, 'payment', v_payment_id, p_notes, v_voucher_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, 0, p_amount, 'payment', v_payment_id, p_notes, v_voucher_no);
  end if;

  return v_payment_id;
end; $$;
grant execute on function public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text, uuid, text) to authenticated;
