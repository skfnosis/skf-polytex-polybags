-- ============================================================================
-- Resolve account/party names into the deleted-payment and deleted-journal-
-- voucher audit snapshots — the raw rows only carry account_id/party_id,
-- which is useless to a human reading the audit detail later (and the
-- referenced account/party could itself be renamed or gone by then).
-- Same signatures as 20260831020000, so this just replaces those bodies.
-- ============================================================================

create or replace function public.delete_payment(p_payment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_payment public.payments;
  v_kind text;
  v_doc_type text;
  v_party_name text;
  v_cash_bank_name text;
  v_direct_account_name text;
  v_performer_name text;
begin
  select * into v_payment from public.payments where id = p_payment_id;
  if v_payment is null then raise exception 'Voucher not found'; end if;
  if v_payment.status <> 'voided' then raise exception 'Only a voided voucher can be deleted — void it first'; end if;
  if not public.has_permission('entry_voucher', 'approve') then
    raise exception 'Not permitted to delete vouchers';
  end if;

  select cash_bank_kind, name into v_kind, v_cash_bank_name from public.chart_of_accounts where id = v_payment.cash_bank_account_id;
  v_doc_type := case
    when v_payment.direction = 'receipt' and v_kind = 'bank' then 'brv'
    when v_payment.direction = 'receipt' then 'crv'
    when v_payment.direction = 'payment' and v_kind = 'bank' then 'bpv'
    else 'cpv'
  end;
  select name into v_party_name from public.parties where id = v_payment.party_id;
  select name into v_direct_account_name from public.chart_of_accounts where id = v_payment.direct_account_id;
  select coalesce(full_name, username) into v_performer_name from public.profiles where id = auth.uid();

  insert into public.document_audit_log (action, doc_family, doc_type, doc_no, doc_date, party_name, amount, performed_by, performed_by_name, snapshot)
  values ('deleted', 'payment', v_doc_type, v_payment.voucher_no, v_payment.payment_date,
    coalesce(v_party_name, v_direct_account_name), v_payment.amount, auth.uid(), v_performer_name,
    jsonb_build_object('payment', to_jsonb(v_payment), 'cash_bank_account_name', v_cash_bank_name,
      'party_name', v_party_name, 'direct_account_name', v_direct_account_name));

  delete from public.ledger_entries where reference_id = v_payment.id
    and reference_type in ('payment', 'void');

  begin
    delete from public.payments where id = p_payment_id;
  exception when foreign_key_violation then
    raise exception 'Cannot delete — another document still references this voucher';
  end;
end; $$;

create or replace function public.delete_journal_voucher(p_voucher_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_voucher public.journal_vouchers;
  v_lines jsonb;
  v_performer_name text;
begin
  select * into v_voucher from public.journal_vouchers where id = p_voucher_id;
  if v_voucher is null then raise exception 'Journal voucher not found'; end if;
  if v_voucher.status <> 'voided' then raise exception 'Only a voided journal voucher can be deleted — void it first'; end if;
  if not public.has_permission('entry_jv', 'approve') then
    raise exception 'Not permitted to delete journal vouchers';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'account_name', coa.name, 'debit', jvl.debit, 'credit', jvl.credit, 'narration', jvl.line_narration
  ) order by jvl.id), '[]'::jsonb) into v_lines
  from public.journal_voucher_lines jvl
  left join public.chart_of_accounts coa on coa.id = jvl.account_id
  where jvl.voucher_id = v_voucher.id;

  select coalesce(full_name, username) into v_performer_name from public.profiles where id = auth.uid();

  insert into public.document_audit_log (action, doc_family, doc_type, doc_no, doc_date, amount, performed_by, performed_by_name, snapshot)
  values ('deleted', 'journal_voucher', 'jv', v_voucher.voucher_no, v_voucher.voucher_date, v_voucher.total_amount, auth.uid(), v_performer_name,
    jsonb_build_object('voucher', to_jsonb(v_voucher), 'lines', v_lines));

  delete from public.ledger_entries where reference_id = v_voucher.id
    and reference_type in ('journal_voucher', 'void');

  delete from public.journal_vouchers where id = p_voucher_id;
end; $$;
