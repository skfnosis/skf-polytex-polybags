-- ============================================================================
-- ACCOUNTING MODULE — payment vouchers get real voucher numbers and voiding,
-- and a proper Journal Voucher (JV) primitive is added from scratch.
-- ============================================================================
-- DESIGN NOTES
-- - CRV/BRV/CPV/BPV are not a new concept: they are the existing
--   record_payment() receipt/payment split by which cash_bank_kind
--   (cash vs bank) the money moved through. This migration only adds
--   voucher numbering (CRV-01/BRV-01/CPV-01/BPV-01, chosen from the
--   selected cash/bank account's kind) and a void_payment() to match every
--   other document type's "never delete, only void" rule — payments already
--   had status/voided_at/voided_by columns from day one but no void RPC.
-- - Permission model: these four voucher types share ONE page key,
--   entry_voucher (like Sale's three doc types all share entry_sale), so
--   the permission grid doesn't grow 4 separate rows for what is one
--   screen with four tabs. record_payment's permission check moves from
--   entry_sale/entry_purchase to entry_voucher accordingly.
-- - JV is genuinely new: journal_vouchers (header) + journal_voucher_lines
--   (N lines, each an account + debit or credit), gated by a new
--   entry_jv page. create_journal_voucher requires total debit = total
--   credit and at least 2 lines, matching the answered question. Lines can
--   target a party's own ledger account (chart_of_accounts type='party')
--   for adjustments — the RPC resolves party_id from that account so
--   v_party_balances / party statements pick the entry up correctly.
-- - Chart of Accounts needs no schema change: it's already RLS-gated by
--   "admin manages chart of accounts" (insert/update/delete) with open
--   read for all authenticated users, so the new Admin-page management UI
--   just uses direct table reads/writes, no new RPC.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Payment vouchers: numbering + void.
-- ----------------------------------------------------------------------------

create sequence public.crv_seq start 1;
create sequence public.brv_seq start 1;
create sequence public.cpv_seq start 1;
create sequence public.bpv_seq start 1;

create or replace function public.next_voucher_no(p_direction text, p_kind text)
returns text language plpgsql as $$
begin
  if p_direction = 'receipt' and p_kind = 'bank' then
    return 'BRV-' || lpad(nextval('public.brv_seq')::text, 2, '0');
  elsif p_direction = 'receipt' then
    return 'CRV-' || lpad(nextval('public.crv_seq')::text, 2, '0');
  elsif p_direction = 'payment' and p_kind = 'bank' then
    return 'BPV-' || lpad(nextval('public.bpv_seq')::text, 2, '0');
  else
    return 'CPV-' || lpad(nextval('public.cpv_seq')::text, 2, '0');
  end if;
end; $$;
alter function public.next_voucher_no(text, text) set search_path = public;

alter table public.payments add column voucher_no text unique;
alter table public.payments add column void_reason text;

create or replace function public.record_payment(
  p_payment_date date, p_party_id uuid, p_direction text, p_amount numeric,
  p_method text, p_cash_bank_account_id uuid, p_linked_invoice_id uuid, p_notes text
) returns uuid language plpgsql security definer as $$
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

  select cash_bank_kind into v_kind from public.chart_of_accounts where id = p_cash_bank_account_id;
  v_voucher_no := public.next_voucher_no(p_direction, coalesce(v_kind, 'cash'));

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;

  insert into public.payments (voucher_no, payment_date, party_id, direction, amount, method,
                                cash_bank_account_id, linked_invoice_id, notes, created_by)
  values (v_voucher_no, p_payment_date, p_party_id, p_direction, p_amount, p_method,
          p_cash_bank_account_id, p_linked_invoice_id, p_notes, auth.uid())
  returning id into v_payment_id;

  -- Receipt: debit cash/bank, credit party (reduces what they owe us).
  -- Payment: debit party (reduces what we owe them), credit cash/bank.
  if p_direction = 'receipt' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, p_amount, 0, 'payment', v_payment_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, v_party_account, p_party_id, 0, p_amount, 'payment', v_payment_id);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, v_party_account, p_party_id, p_amount, 0, 'payment', v_payment_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, 0, p_amount, 'payment', v_payment_id);
  end if;

  return v_payment_id;
end; $$;
grant execute on function public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text) to authenticated;
alter function public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text) set search_path = public;

create or replace function public.void_payment(p_payment_id uuid, p_reason text)
returns void language plpgsql security definer as $$
declare
  v_payment public.payments;
begin
  select * into v_payment from public.payments where id = p_payment_id;
  if v_payment is null then raise exception 'Voucher not found'; end if;
  if v_payment.status = 'voided' then raise exception 'Voucher already voided'; end if;
  if not public.has_permission('entry_voucher', 'approve') then
    raise exception 'Not permitted to void vouchers';
  end if;

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
  select current_date, account_id, party_id, credit, debit, 'void', v_payment.id
  from public.ledger_entries where reference_type = 'payment' and reference_id = v_payment.id;

  update public.payments
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_payment_id;
end; $$;
grant execute on function public.void_payment(uuid, text) to authenticated;
alter function public.void_payment(uuid, text) set search_path = public;

drop policy "payments viewable with entry view or reports" on public.payments;
create policy "payments viewable with entry_voucher view or reports" on public.payments for select
  using (public.has_permission('entry_voucher', 'view') or public.has_permission('reports', 'view'));

-- ----------------------------------------------------------------------------
-- Journal Voucher: header + N lines, must balance.
-- ----------------------------------------------------------------------------

create sequence public.jv_seq start 1;

create table public.journal_vouchers (
  id uuid primary key default gen_random_uuid(),
  voucher_no text unique not null,
  voucher_date date not null,
  narration text,
  total_amount numeric not null default 0,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  voided_at timestamptz,
  voided_by uuid references public.profiles(id),
  void_reason text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.journal_voucher_lines (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.journal_vouchers(id) on delete cascade,
  account_id uuid not null references public.chart_of_accounts(id),
  party_id uuid references public.parties(id),
  debit numeric not null default 0,
  credit numeric not null default 0,
  line_narration text
);

create index on public.journal_voucher_lines (voucher_id);

alter table public.ledger_entries drop constraint ledger_entries_reference_type_check;
alter table public.ledger_entries add constraint ledger_entries_reference_type_check
  check (reference_type in ('invoice', 'expense', 'payment', 'opening_balance', 'void', 'journal_voucher'));

create or replace function public.create_journal_voucher(
  p_voucher_date date, p_narration text, p_lines jsonb
) returns uuid language plpgsql security definer as $$
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

    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_voucher_date, v_account_id, v_party_id,
            coalesce((v_line->>'debit')::numeric, 0), coalesce((v_line->>'credit')::numeric, 0),
            'journal_voucher', v_voucher_id);
  end loop;

  return v_voucher_id;
end; $$;
grant execute on function public.create_journal_voucher(date, text, jsonb) to authenticated;
alter function public.create_journal_voucher(date, text, jsonb) set search_path = public;

create or replace function public.void_journal_voucher(p_voucher_id uuid, p_reason text)
returns void language plpgsql security definer as $$
declare
  v_voucher public.journal_vouchers;
begin
  select * into v_voucher from public.journal_vouchers where id = p_voucher_id;
  if v_voucher is null then raise exception 'Journal voucher not found'; end if;
  if v_voucher.status = 'voided' then raise exception 'Journal voucher already voided'; end if;
  if not public.has_permission('entry_jv', 'approve') then
    raise exception 'Not permitted to void journal vouchers';
  end if;

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
  select current_date, account_id, party_id, credit, debit, 'void', v_voucher.id
  from public.ledger_entries where reference_type = 'journal_voucher' and reference_id = v_voucher.id;

  update public.journal_vouchers
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_voucher_id;
end; $$;
grant execute on function public.void_journal_voucher(uuid, text) to authenticated;
alter function public.void_journal_voucher(uuid, text) set search_path = public;

alter table public.journal_vouchers enable row level security;
alter table public.journal_voucher_lines enable row level security;

create policy "jv viewable with entry_jv view" on public.journal_vouchers for select
  using (public.has_permission('entry_jv', 'view'));
create policy "jv lines viewable with entry_jv view" on public.journal_voucher_lines for select
  using (public.has_permission('entry_jv', 'view'));
