-- ============================================================================
-- ADMIN PANEL + PARTY CONTACT DETAILS + CHART OF ACCOUNTS TYPES
-- ============================================================================
-- - parties gains email/ntn/stn (mobile already existed as `contact`), plus
--   an update_party() RPC so existing customers/vendors can be edited from
--   Chart of Accounts / the Sale & Purchase quick-add flows.
-- - chart_of_accounts.type gains asset/liability/capital/income so the
--   ledger-account (non-party) side of Chart of Accounts can categorize a
--   real 5-type accounting structure, not just expense/sales/purchase.
-- - fetch_unposted_documents(): an admin-only integrity check. Every write
--   path (create_invoice / record_payment / create_journal_voucher) posts
--   its ledger rows in the same transaction as the header row, so this
--   should always come back empty — it exists to catch anything that
--   doesn't (future bug, manual DB edit), not because a known gap exists.
-- ============================================================================

alter table public.parties add column if not exists email text;
alter table public.parties add column if not exists ntn text;
alter table public.parties add column if not exists stn text;

create or replace function public.create_party(
  p_name text, p_type text, p_category text[], p_contact text,
  p_address text, p_opening_balance numeric default 0,
  p_email text default null, p_ntn text default null, p_stn text default null
) returns uuid language plpgsql security definer as $$
declare
  v_account_id uuid;
  v_party_id uuid;
begin
  if not (public.has_permission('party_master','create')
          or public.has_permission('entry_sale','create')
          or public.has_permission('entry_purchase','create')) then
    raise exception 'Not permitted to add parties';
  end if;

  insert into public.chart_of_accounts (name, type) values (p_name, 'party')
    returning id into v_account_id;

  insert into public.parties (name, type, category, contact, address,
                               ledger_account_id, opening_balance, created_by,
                               email, ntn, stn)
  values (p_name, p_type, p_category, p_contact, p_address,
          v_account_id, p_opening_balance, auth.uid(),
          p_email, p_ntn, p_stn)
  returning id into v_party_id;

  if p_opening_balance <> 0 then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (current_date, v_account_id, v_party_id,
            greatest(p_opening_balance, 0), greatest(-p_opening_balance, 0),
            'opening_balance', v_party_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    select current_date,
           (select id from public.chart_of_accounts where type = case when p_type = 'customer' then 'sales' else 'purchase' end limit 1),
           v_party_id,
           greatest(-p_opening_balance, 0), greatest(p_opening_balance, 0),
           'opening_balance', v_party_id;
  end if;

  return v_party_id;
end; $$;
grant execute on function public.create_party(text, text, text[], text, text, numeric, text, text, text) to authenticated;
alter function public.create_party(text, text, text[], text, text, numeric, text, text, text) set search_path = public;

create or replace function public.update_party(
  p_party_id uuid, p_name text, p_contact text, p_address text,
  p_email text default null, p_ntn text default null, p_stn text default null,
  p_category text[] default null
) returns void language plpgsql security definer as $$
begin
  if not (public.has_permission('party_master','edit')
          or public.has_permission('entry_sale','edit')
          or public.has_permission('entry_purchase','edit')) then
    raise exception 'Not permitted to edit parties';
  end if;

  update public.parties set
    name = coalesce(p_name, name),
    contact = p_contact,
    address = p_address,
    email = p_email,
    ntn = p_ntn,
    stn = p_stn,
    category = coalesce(p_category, category)
  where id = p_party_id;

  update public.chart_of_accounts a set name = p_name
  from public.parties p
  where p.id = p_party_id and a.id = p.ledger_account_id and p_name is not null;
end; $$;
grant execute on function public.update_party(uuid, text, text, text, text, text, text, text[]) to authenticated;
alter function public.update_party(uuid, text, text, text, text, text, text, text[]) set search_path = public;

alter table public.chart_of_accounts drop constraint chart_of_accounts_type_check;
alter table public.chart_of_accounts add constraint chart_of_accounts_type_check
  check (type in ('sales', 'purchase', 'expense', 'cash_bank', 'party', 'drawings',
                   'asset', 'liability', 'capital', 'income'));

create or replace function public.fetch_unposted_documents()
returns table(
  doc_type text, doc_no text, doc_date date, party_name text,
  amount numeric, ledger_total numeric, note text
) language plpgsql security definer as $$
begin
  if not coalesce((select is_admin from public.profiles where id = auth.uid()), false) then
    raise exception 'Admin only';
  end if;

  return query
  select t.doc_type, t.doc_no, t.doc_date, t.party_name, t.amount, t.ledger_total, t.note
  from (
    select
      'Invoice'::text as doc_type, i.invoice_no as doc_no, i.invoice_date as doc_date,
      p.name as party_name, i.total_amount as amount,
      coalesce((select sum(l.debit) from public.ledger_entries l
                where l.reference_type = 'invoice' and l.reference_id = i.id), 0) as ledger_total,
      case when not exists (select 1 from public.ledger_entries l
                             where l.reference_type = 'invoice' and l.reference_id = i.id)
           then 'No ledger entries found for this document'
           else 'Ledger total does not match document total' end as note
    from public.invoices i
    join public.parties p on p.id = i.party_id
    where i.status = 'posted'
      and i.invoice_type in ('sale', 'purchase', 'sale_return', 'purchase_return')
      and (
        not exists (select 1 from public.ledger_entries l where l.reference_type = 'invoice' and l.reference_id = i.id)
        or (select coalesce(sum(l.debit),0) - coalesce(sum(l.credit),0) from public.ledger_entries l
            where l.reference_type = 'invoice' and l.reference_id = i.id) <> 0
      )

    union all

    select
      'Voucher'::text, coalesce(pay.voucher_no, '—'), pay.payment_date,
      pr.name, pay.amount,
      coalesce((select sum(l.debit) from public.ledger_entries l
                where l.reference_type = 'payment' and l.reference_id = pay.id), 0),
      case when not exists (select 1 from public.ledger_entries l
                             where l.reference_type = 'payment' and l.reference_id = pay.id)
           then 'No ledger entries found for this voucher'
           else 'Ledger total does not match voucher amount' end
    from public.payments pay
    join public.parties pr on pr.id = pay.party_id
    where pay.status = 'posted'
      and (
        not exists (select 1 from public.ledger_entries l where l.reference_type = 'payment' and l.reference_id = pay.id)
        or (select coalesce(sum(l.debit),0) - coalesce(sum(l.credit),0) from public.ledger_entries l
            where l.reference_type = 'payment' and l.reference_id = pay.id) <> 0
      )

    union all

    select
      'Journal Voucher'::text, jv.voucher_no, jv.voucher_date,
      coalesce(jv.narration, '—'), jv.total_amount,
      coalesce((select sum(l.debit) from public.ledger_entries l
                where l.reference_type = 'journal_voucher' and l.reference_id = jv.id), 0),
      case when not exists (select 1 from public.ledger_entries l
                             where l.reference_type = 'journal_voucher' and l.reference_id = jv.id)
           then 'No ledger entries found for this voucher'
           else 'Ledger total does not match voucher amount' end
    from public.journal_vouchers jv
    where jv.status = 'posted'
      and (
        not exists (select 1 from public.ledger_entries l where l.reference_type = 'journal_voucher' and l.reference_id = jv.id)
        or (select coalesce(sum(l.debit),0) - coalesce(sum(l.credit),0) from public.ledger_entries l
            where l.reference_type = 'journal_voucher' and l.reference_id = jv.id) <> 0
      )
  ) t
  order by t.doc_date desc;
end; $$;
grant execute on function public.fetch_unposted_documents() to authenticated;
alter function public.fetch_unposted_documents() set search_path = public;
