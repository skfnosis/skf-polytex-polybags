-- ============================================================================
-- SECURITY / DATA-INTEGRITY FIX: two more RPCs found missing input
-- validation while auditing the rest of the write functions.
-- ============================================================================
-- 1. record_payment() never checked that p_cash_bank_account_id actually
--    refers to a type='cash_bank' account. The app's own Voucher entry form
--    restricts the picker to real cash/bank accounts client-side, but the
--    RPC itself accepts ANY chart_of_accounts id. Since parties are
--    readable by every authenticated user (needed for the party picker),
--    anyone holding only entry_voucher/create -- an ordinary cashier's
--    permission -- could call record_payment directly with, say, a
--    customer's own ledger account id as the "cash/bank" leg and post a
--    fabricated receipt/payment straight into that party's ledger --
--    effectively getting the power of a Journal Voucher line (normally
--    gated behind the separate, higher-trust entry_jv permission) without
--    ever needing entry_jv access. Fixed by checking the account's type
--    server-side, same as the permission check already guards who can call
--    the function at all.
--
-- 2. create_journal_voucher() validated that total debit = total credit and
--    is greater than zero, but never checked individual lines: a line could
--    carry a negative debit/credit (which nets out the same as a positive
--    entry on the other side, just via a nonsensical negative number) or
--    have both a debit and a credit set on the same line. Neither breaks
--    the trial balance, but both produce ledger rows that don't correspond
--    to a real transaction and can render oddly on statements/reports.
--    Fixed by validating each line before posting.
-- ============================================================================

create or replace function public.record_payment(
  p_payment_date date, p_party_id uuid, p_direction text, p_amount numeric,
  p_method text, p_cash_bank_account_id uuid, p_linked_invoice_id uuid, p_notes text
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_payment_id uuid;
  v_party_account uuid;
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

  select cash_bank_kind into v_kind from public.chart_of_accounts where id = p_cash_bank_account_id;
  v_voucher_no := public.next_voucher_no(p_direction, coalesce(v_kind, 'cash'));

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;

  insert into public.payments (voucher_no, payment_date, party_id, direction, amount, method,
                                cash_bank_account_id, linked_invoice_id, notes, created_by)
  values (v_voucher_no, p_payment_date, p_party_id, p_direction, p_amount, p_method,
          p_cash_bank_account_id, p_linked_invoice_id, p_notes, auth.uid())
  returning id into v_payment_id;

  if p_direction = 'receipt' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, p_amount, 0, 'payment', v_payment_id, p_notes, v_voucher_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, v_party_account, p_party_id, 0, p_amount, 'payment', v_payment_id, p_notes, v_voucher_no);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, v_party_account, p_party_id, p_amount, 0, 'payment', v_payment_id, p_notes, v_voucher_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, 0, p_amount, 'payment', v_payment_id, p_notes, v_voucher_no);
  end if;

  return v_payment_id;
end; $$;
grant execute on function public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text) to authenticated;

create or replace function public.create_journal_voucher(
  p_voucher_date date, p_narration text, p_lines jsonb
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_voucher_id uuid;
  v_voucher_no text;
  v_line jsonb;
  v_account_id uuid;
  v_party_id uuid;
  v_total_debit numeric;
  v_total_credit numeric;
begin
  if not public.has_permission('entry_jv', 'create') then
    raise exception 'Not permitted to create journal vouchers';
  end if;
  if jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal voucher needs at least two lines';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if coalesce((v_line->>'debit')::numeric, 0) < 0 or coalesce((v_line->>'credit')::numeric, 0) < 0 then
      raise exception 'Journal voucher line amounts cannot be negative';
    end if;
    if coalesce((v_line->>'debit')::numeric, 0) > 0 and coalesce((v_line->>'credit')::numeric, 0) > 0 then
      raise exception 'A journal voucher line cannot have both a debit and a credit';
    end if;
  end loop;

  select coalesce(sum((l->>'debit')::numeric), 0), coalesce(sum((l->>'credit')::numeric), 0)
    into v_total_debit, v_total_credit
    from jsonb_array_elements(p_lines) l;

  if v_total_debit <> v_total_credit or v_total_debit <= 0 then
    raise exception 'Journal voucher must balance: total debit must equal total credit, and be greater than zero';
  end if;

  v_voucher_no := 'JV-' || lpad(nextval('public.jv_seq')::text, 2, '0');

  insert into public.journal_vouchers (voucher_no, voucher_date, narration, total_amount, created_by)
  values (v_voucher_no, p_voucher_date, p_narration, v_total_debit, auth.uid())
  returning id into v_voucher_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_account_id := (v_line->>'account_id')::uuid;
    select id into v_party_id from public.parties where ledger_account_id = v_account_id;

    insert into public.journal_voucher_lines (voucher_id, account_id, party_id, debit, credit, line_narration)
    values (v_voucher_id, v_account_id, v_party_id,
            coalesce((v_line->>'debit')::numeric, 0), coalesce((v_line->>'credit')::numeric, 0),
            v_line->>'narration');

    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_voucher_date, v_account_id, v_party_id,
            coalesce((v_line->>'debit')::numeric, 0), coalesce((v_line->>'credit')::numeric, 0),
            'journal_voucher', v_voucher_id,
            coalesce(nullif(v_line->>'narration', ''), p_narration), v_voucher_no);
  end loop;

  return v_voucher_id;
end; $$;
grant execute on function public.create_journal_voucher(date, text, jsonb) to authenticated;
