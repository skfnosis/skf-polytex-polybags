-- ============================================================================
-- Admin-visible audit trail of every Edited or Deleted document that
-- affects a party's ledger — Purchase/Sale Order/Bill/Return, CRV/BRV/
-- CPV/BPV, and Journal Voucher. A hard Delete erases the live row itself
-- (see 20260831010000), so without this the fact that something was ever
-- deleted would be unrecoverable; this captures a snapshot at the moment
-- of the edit or delete, independent of the row's later fate.
--
-- Only the three SECURITY DEFINER functions below ever write to this
-- table (no client insert policy — same trust boundary as ledger_entries),
-- and only an admin can read it.
-- ============================================================================

create table public.document_audit_log (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('edited', 'deleted')),
  doc_family text not null check (doc_family in ('invoice', 'payment', 'journal_voucher')),
  doc_type text not null,
  doc_no text not null,
  doc_date date,
  brand_key text,
  party_name text,
  amount numeric,
  performed_by uuid references auth.users(id),
  performed_by_name text,
  performed_at timestamptz not null default now(),
  snapshot jsonb not null
);

create index document_audit_log_performed_at_idx on public.document_audit_log (performed_at desc);
create index document_audit_log_action_idx on public.document_audit_log (action);
create index document_audit_log_brand_key_idx on public.document_audit_log (brand_key);

alter table public.document_audit_log enable row level security;
create policy "admin can view document audit log" on public.document_audit_log
  for select using (public.is_admin());

-- ----------------------------------------------------------------------------
-- update_invoice — log the pre-edit state (old invoice row + its old line
-- items) before anything is overwritten. Same signature as before, so
-- CREATE OR REPLACE genuinely replaces the one live overload.
-- ----------------------------------------------------------------------------
create or replace function public.update_invoice(
  p_invoice_id uuid, p_party_id uuid, p_invoice_date date, p_items jsonb,
  p_supplier_invoice_no text default null, p_linked_order_id uuid default null,
  p_transport numeric default 0, p_loading numeric default 0, p_discount numeric default 0,
  p_tax numeric default 0, p_customer_po_no text default null, p_narration text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_invoice public.invoices;
  v_page text;
  v_subtotal numeric := 0;
  v_total numeric := 0;
  v_item jsonb;
  v_item_id uuid;
  v_is_service boolean;
  v_party_account uuid;
  v_trade_account uuid;
  v_ledger_narration text;
  v_old_items jsonb;
  v_party_name text;
  v_performer_name text;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice is null then raise exception 'Document not found'; end if;
  if v_invoice.status = 'voided' then raise exception 'Cannot edit a voided document — void stays final.'; end if;

  v_page := case when v_invoice.invoice_type in ('sale','sale_order','sale_return') then 'entry_sale' else 'entry_purchase' end;
  if not public.has_permission(v_page, 'approve') then
    raise exception 'Not permitted to edit % documents', v_invoice.invoice_type;
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Document must have at least one line item';
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    if (v_item->>'quantity')::numeric <= 0 then
      raise exception 'Line quantity must be greater than zero';
    end if;
    if (v_item->>'rate')::numeric < 0 then
      raise exception 'Line rate cannot be negative';
    end if;
  end loop;

  select coalesce(jsonb_agg(to_jsonb(ii) - 'invoice_id'), '[]'::jsonb) into v_old_items
    from public.invoice_items ii where ii.invoice_id = v_invoice.id;
  select name into v_party_name from public.parties where id = v_invoice.party_id;
  select coalesce(full_name, username) into v_performer_name from public.profiles where id = auth.uid();

  insert into public.document_audit_log (action, doc_family, doc_type, doc_no, doc_date, brand_key, party_name, amount, performed_by, performed_by_name, snapshot)
  values ('edited', 'invoice', v_invoice.invoice_type, v_invoice.invoice_no, v_invoice.invoice_date, v_invoice.brand_key, v_party_name, v_invoice.total_amount, auth.uid(), v_performer_name,
    jsonb_build_object('invoice', to_jsonb(v_invoice), 'items', v_old_items));

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;
  select id into v_trade_account from public.chart_of_accounts
    where type = case when v_invoice.invoice_type in ('sale','sale_order','sale_return') then 'sales' else 'purchase' end limit 1;

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
  select current_date, account_id, party_id, credit, debit, 'invoice_edit', v_invoice.id,
         'Edit correction — ' || coalesce(v_invoice.narration, v_invoice.invoice_no), doc_no
  from public.ledger_entries where reference_type = 'invoice' and reference_id = v_invoice.id;

  insert into public.stock_movements (item_id, movement_date, quantity_in, quantity_out, unit, reference_type, reference_id)
  select item_id, current_date, quantity_out, quantity_in, unit, 'invoice_edit', v_invoice.id
  from public.stock_movements
  where reference_id = v_invoice.id
    and reference_type in ('purchase_bill', 'purchase_return', 'sale_bill', 'sale_return');

  delete from public.invoice_items where invoice_id = v_invoice.id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_item_id := nullif(v_item->>'item_id', '')::uuid;
    v_is_service := coalesce(v_item->>'item_type', 'product') = 'service';

    insert into public.invoice_items (
      invoice_id, quantity, unit, rate, description, item_id, narration,
      reserved_for_party_id, fulfilled_from_item_id, color, gsm
    )
    values (v_invoice.id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description',
            v_item_id,
            nullif(v_item->>'narration', ''),
            nullif(v_item->>'reserved_for_party_id', '')::uuid,
            nullif(v_item->>'fulfilled_from_item_id', '')::uuid,
            nullif(v_item->>'color', ''),
            nullif(v_item->>'gsm', ''));
    v_subtotal := v_subtotal + (v_item->>'quantity')::numeric * (v_item->>'rate')::numeric;

    if not v_is_service and v_item_id is not null and v_invoice.invoice_type in ('purchase','purchase_order') then
      if v_invoice.invoice_type = 'purchase' then
        insert into public.stock_movements (item_id, movement_date, quantity_in, unit, reference_type, reference_id)
        values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'purchase_bill', v_invoice.id);
        update public.items set last_purchase_rate = (v_item->>'rate')::numeric where id = v_item_id;
      end if;
    elsif not v_is_service and v_item_id is not null and v_invoice.invoice_type = 'purchase_return' then
      insert into public.stock_movements (item_id, movement_date, quantity_out, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'purchase_return', v_invoice.id);
    elsif not v_is_service and v_item_id is not null and v_invoice.invoice_type = 'sale' then
      insert into public.stock_movements (item_id, movement_date, quantity_out, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'sale_bill', v_invoice.id);
      update public.items set last_sale_rate = (v_item->>'rate')::numeric where id = v_item_id;
    elsif not v_is_service and v_item_id is not null and v_invoice.invoice_type = 'sale_return' then
      insert into public.stock_movements (item_id, movement_date, quantity_in, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'sale_return', v_invoice.id);
    elsif v_is_service and v_item_id is not null and v_invoice.invoice_type in ('purchase','purchase_return') then
      update public.items set last_purchase_rate = (v_item->>'rate')::numeric where id = v_item_id;
    elsif v_is_service and v_item_id is not null and v_invoice.invoice_type = 'sale' then
      update public.items set last_sale_rate = (v_item->>'rate')::numeric where id = v_item_id;
    end if;
  end loop;

  select string_agg(distinct x, '; ') into v_ledger_narration
    from jsonb_array_elements(p_items) e, lateral (select nullif(e->>'narration', '') as x) s
    where x is not null;
  v_ledger_narration := coalesce(v_ledger_narration, p_narration);

  if v_invoice.invoice_type in ('purchase_order', 'sale_order') then
    update public.invoices set
      party_id = p_party_id, invoice_date = p_invoice_date, total_amount = v_subtotal,
      supplier_invoice_no = p_supplier_invoice_no, linked_order_id = p_linked_order_id,
      customer_po_no = p_customer_po_no, narration = p_narration
      where id = v_invoice.id;
    return;
  end if;

  v_total := v_subtotal + coalesce(p_transport,0) + coalesce(p_loading,0)
             + coalesce(p_tax,0) - coalesce(p_discount,0);

  update public.invoices set
    party_id = p_party_id, invoice_date = p_invoice_date, total_amount = v_total,
    supplier_invoice_no = p_supplier_invoice_no, linked_order_id = p_linked_order_id,
    transport_charges = coalesce(p_transport,0), loading_charges = coalesce(p_loading,0),
    discount_amount = coalesce(p_discount,0), tax_amount = coalesce(p_tax,0),
    customer_po_no = p_customer_po_no, narration = p_narration
    where id = v_invoice.id;

  if v_invoice.invoice_type = 'sale' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
  elsif v_invoice.invoice_type = 'purchase' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
  elsif v_invoice.invoice_type = 'purchase_return' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice.id, v_ledger_narration, v_invoice.invoice_no);
  end if;
end; $$;

-- ----------------------------------------------------------------------------
-- delete_invoice / delete_payment / delete_journal_voucher — log a full
-- snapshot immediately before the row (and its cascaded children) is
-- actually removed.
-- ----------------------------------------------------------------------------
create or replace function public.delete_invoice(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_invoice public.invoices;
  v_page text;
  v_items jsonb;
  v_party_name text;
  v_performer_name text;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice is null then raise exception 'Invoice not found'; end if;
  if v_invoice.status <> 'voided' then raise exception 'Only a voided document can be deleted — void it first'; end if;

  v_page := case when v_invoice.invoice_type in ('sale', 'sale_order', 'sale_return') then 'entry_sale' else 'entry_purchase' end;
  if not public.has_permission(v_page, 'approve') then
    raise exception 'Not permitted to delete % documents', v_invoice.invoice_type;
  end if;

  select coalesce(jsonb_agg(to_jsonb(ii) - 'invoice_id'), '[]'::jsonb) into v_items
    from public.invoice_items ii where ii.invoice_id = v_invoice.id;
  select name into v_party_name from public.parties where id = v_invoice.party_id;
  select coalesce(full_name, username) into v_performer_name from public.profiles where id = auth.uid();

  insert into public.document_audit_log (action, doc_family, doc_type, doc_no, doc_date, brand_key, party_name, amount, performed_by, performed_by_name, snapshot)
  values ('deleted', 'invoice', v_invoice.invoice_type, v_invoice.invoice_no, v_invoice.invoice_date, v_invoice.brand_key, v_party_name, v_invoice.total_amount, auth.uid(), v_performer_name,
    jsonb_build_object('invoice', to_jsonb(v_invoice), 'items', v_items));

  delete from public.ledger_entries where reference_id = v_invoice.id
    and reference_type in ('invoice', 'void');
  delete from public.stock_movements where reference_id = v_invoice.id
    and reference_type in ('purchase_bill', 'purchase_return', 'sale_bill', 'sale_return', 'void');

  begin
    delete from public.invoices where id = p_invoice_id;
  exception when foreign_key_violation then
    raise exception 'Cannot delete — another document (a linked order/bill, a payment, or a fulfilled reservation) still references this one';
  end;
end; $$;

create or replace function public.delete_payment(p_payment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_payment public.payments;
  v_kind text;
  v_doc_type text;
  v_party_name text;
  v_performer_name text;
begin
  select * into v_payment from public.payments where id = p_payment_id;
  if v_payment is null then raise exception 'Voucher not found'; end if;
  if v_payment.status <> 'voided' then raise exception 'Only a voided voucher can be deleted — void it first'; end if;
  if not public.has_permission('entry_voucher', 'approve') then
    raise exception 'Not permitted to delete vouchers';
  end if;

  select cash_bank_kind into v_kind from public.chart_of_accounts where id = v_payment.cash_bank_account_id;
  v_doc_type := case
    when v_payment.direction = 'receipt' and v_kind = 'bank' then 'brv'
    when v_payment.direction = 'receipt' then 'crv'
    when v_payment.direction = 'payment' and v_kind = 'bank' then 'bpv'
    else 'cpv'
  end;
  select coalesce(p.name, coa.name) into v_party_name
    from (select 1) dummy
    left join public.parties p on p.id = v_payment.party_id
    left join public.chart_of_accounts coa on coa.id = v_payment.direct_account_id;
  select coalesce(full_name, username) into v_performer_name from public.profiles where id = auth.uid();

  insert into public.document_audit_log (action, doc_family, doc_type, doc_no, doc_date, party_name, amount, performed_by, performed_by_name, snapshot)
  values ('deleted', 'payment', v_doc_type, v_payment.voucher_no, v_payment.payment_date, v_party_name, v_payment.amount, auth.uid(), v_performer_name,
    to_jsonb(v_payment));

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

  select coalesce(jsonb_agg(to_jsonb(jvl) - 'voucher_id'), '[]'::jsonb) into v_lines
    from public.journal_voucher_lines jvl where jvl.voucher_id = v_voucher.id;
  select coalesce(full_name, username) into v_performer_name from public.profiles where id = auth.uid();

  insert into public.document_audit_log (action, doc_family, doc_type, doc_no, doc_date, amount, performed_by, performed_by_name, snapshot)
  values ('deleted', 'journal_voucher', 'jv', v_voucher.voucher_no, v_voucher.voucher_date, v_voucher.total_amount, auth.uid(), v_performer_name,
    jsonb_build_object('voucher', to_jsonb(v_voucher), 'lines', v_lines));

  delete from public.ledger_entries where reference_id = v_voucher.id
    and reference_type in ('journal_voucher', 'void');

  delete from public.journal_vouchers where id = p_voucher_id;
end; $$;
