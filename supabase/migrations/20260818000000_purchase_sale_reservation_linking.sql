-- ============================================================================
-- PURCHASE -> SALE RESERVATION LINKING
-- ============================================================================
-- Lets a Purchase Bill line be earmarked for a specific customer at the time
-- of purchase ("this lot is already sold to X"), then surfaces those
-- earmarked-but-not-yet-billed lines as suggestions when entering that same
-- customer's Sale Bill, and marks a purchase line "Billed" once a sale line
-- has been filled from it.
--
-- Both new columns live directly on invoice_items and travel through
-- create_invoice/update_invoice's existing p_items jsonb array (new optional
-- keys reserved_for_party_id / fulfilled_from_item_id per line) -- no new
-- top-level function params needed, since both are per-line, not per-invoice.
-- ============================================================================

alter table public.invoice_items add column reserved_for_party_id uuid references public.parties(id);
alter table public.invoice_items add column fulfilled_from_item_id uuid references public.invoice_items(id);
create index on public.invoice_items (reserved_for_party_id);
create index on public.invoice_items (fulfilled_from_item_id);

-- Purchase Bill lines reserved for a customer that haven't been pulled into
-- a (posted) Sale Bill yet -- what the Sale Bill's suggestion panel reads.
create or replace view public.v_open_purchase_reservations as
select
  ii.id, ii.invoice_id, ii.item_id, ii.quantity, ii.unit, ii.rate, ii.description,
  ii.reserved_for_party_id, i.invoice_no, i.invoice_date,
  it.name as item_name, it.item_type
from public.invoice_items ii
join public.invoices i on i.id = ii.invoice_id
left join public.items it on it.id = ii.item_id
where ii.reserved_for_party_id is not null
  and i.invoice_type = 'purchase'
  and i.status = 'posted'
  and not exists (
    select 1 from public.invoice_items s
    join public.invoices si on si.id = s.invoice_id
    where s.fulfilled_from_item_id = ii.id and si.status = 'posted'
  );
alter view public.v_open_purchase_reservations set (security_invoker = true);

-- ----------------------------------------------------------------------------
-- create_invoice / update_invoice -- same bodies as before, just reading two
-- more optional keys off each line's jsonb payload into invoice_items.
-- ----------------------------------------------------------------------------

create or replace function public.create_invoice(
  p_invoice_type text, p_brand_key text, p_category text,
  p_party_id uuid, p_invoice_date date, p_items jsonb,
  p_supplier_invoice_no text default null,
  p_linked_order_id uuid default null,
  p_transport numeric default 0,
  p_loading numeric default 0,
  p_discount numeric default 0,
  p_tax numeric default 0,
  p_customer_po_no text default null,
  p_narration text default null
) returns uuid language plpgsql security definer as $$
declare
  v_page text := 'entry_purchase';
  v_invoice_id uuid;
  v_invoice_no text;
  v_subtotal numeric := 0;
  v_total numeric := 0;
  v_item jsonb;
  v_item_id uuid;
  v_is_service boolean;
  v_party_account uuid;
  v_trade_account uuid;
  v_ledger_narration text;
begin
  if p_invoice_type in ('sale', 'sale_order', 'sale_return') then
    v_page := 'entry_sale';
  end if;
  if not public.has_permission(v_page, 'create') then
    raise exception 'Not permitted to create % invoices', p_invoice_type;
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Invoice must have at least one line item';
  end if;

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;
  select id into v_trade_account from public.chart_of_accounts
    where type = case when p_invoice_type in ('sale','sale_order','sale_return') then 'sales' else 'purchase' end limit 1;

  v_invoice_no := public.next_invoice_no(p_invoice_type);

  insert into public.invoices (
    invoice_no, invoice_type, brand_key, category, party_id, invoice_date, created_by,
    supplier_invoice_no, linked_order_id, transport_charges, loading_charges, discount_amount, tax_amount,
    customer_po_no, narration
  )
  values (
    v_invoice_no, p_invoice_type, p_brand_key, p_category, p_party_id, p_invoice_date, auth.uid(),
    p_supplier_invoice_no, p_linked_order_id, coalesce(p_transport,0), coalesce(p_loading,0),
    coalesce(p_discount,0), coalesce(p_tax,0), p_customer_po_no, p_narration
  )
  returning id into v_invoice_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_item_id := nullif(v_item->>'item_id', '')::uuid;
    v_is_service := coalesce(v_item->>'item_type', 'product') = 'service';

    insert into public.invoice_items (
      invoice_id, quantity, unit, rate, description, item_id, narration,
      reserved_for_party_id, fulfilled_from_item_id
    )
    values (v_invoice_id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description',
            v_item_id,
            nullif(v_item->>'narration', ''),
            nullif(v_item->>'reserved_for_party_id', '')::uuid,
            nullif(v_item->>'fulfilled_from_item_id', '')::uuid);
    v_subtotal := v_subtotal + (v_item->>'quantity')::numeric * (v_item->>'rate')::numeric;

    if not v_is_service and v_item_id is not null and p_invoice_type in ('purchase','purchase_order') then
      if p_invoice_type = 'purchase' then
        insert into public.stock_movements (item_id, movement_date, quantity_in, unit, reference_type, reference_id)
        values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'purchase_bill', v_invoice_id);
        update public.items set last_purchase_rate = (v_item->>'rate')::numeric where id = v_item_id;
      end if;
    elsif not v_is_service and v_item_id is not null and p_invoice_type = 'purchase_return' then
      insert into public.stock_movements (item_id, movement_date, quantity_out, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'purchase_return', v_invoice_id);
    elsif not v_is_service and v_item_id is not null and p_invoice_type = 'sale' then
      insert into public.stock_movements (item_id, movement_date, quantity_out, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'sale_bill', v_invoice_id);
      update public.items set last_sale_rate = (v_item->>'rate')::numeric where id = v_item_id;
    elsif not v_is_service and v_item_id is not null and p_invoice_type = 'sale_return' then
      insert into public.stock_movements (item_id, movement_date, quantity_in, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'sale_return', v_invoice_id);
    elsif v_is_service and v_item_id is not null and p_invoice_type in ('purchase','purchase_return') then
      update public.items set last_purchase_rate = (v_item->>'rate')::numeric where id = v_item_id;
    elsif v_is_service and v_item_id is not null and p_invoice_type = 'sale' then
      update public.items set last_sale_rate = (v_item->>'rate')::numeric where id = v_item_id;
    end if;
  end loop;

  select string_agg(distinct x, '; ') into v_ledger_narration
    from jsonb_array_elements(p_items) e, lateral (select nullif(e->>'narration', '') as x) s
    where x is not null;
  v_ledger_narration := coalesce(v_ledger_narration, p_narration);

  if p_invoice_type in ('purchase_order', 'sale_order') then
    update public.invoices set total_amount = v_subtotal where id = v_invoice_id;
    return v_invoice_id;
  end if;

  v_total := v_subtotal + coalesce(p_transport,0) + coalesce(p_loading,0)
             + coalesce(p_tax,0) - coalesce(p_discount,0);
  update public.invoices set total_amount = v_total where id = v_invoice_id;

  if p_invoice_type = 'sale' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
  elsif p_invoice_type = 'purchase' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
  elsif p_invoice_type = 'purchase_return' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id, v_ledger_narration, v_invoice_no);
  end if;

  return v_invoice_id;
end; $$;
grant execute on function public.create_invoice(
  text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text, text
) to authenticated;
alter function public.create_invoice(
  text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text, text
) set search_path = public;

create or replace function public.update_invoice(
  p_invoice_id uuid,
  p_party_id uuid, p_invoice_date date, p_items jsonb,
  p_supplier_invoice_no text default null,
  p_linked_order_id uuid default null,
  p_transport numeric default 0,
  p_loading numeric default 0,
  p_discount numeric default 0,
  p_tax numeric default 0,
  p_customer_po_no text default null,
  p_narration text default null
) returns void language plpgsql security definer as $$
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
    and reference_type in ('purchase_bill','purchase_return','sale_bill','sale_return');

  delete from public.invoice_items where invoice_id = v_invoice.id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_item_id := nullif(v_item->>'item_id', '')::uuid;
    v_is_service := coalesce(v_item->>'item_type', 'product') = 'service';

    insert into public.invoice_items (
      invoice_id, quantity, unit, rate, description, item_id, narration,
      reserved_for_party_id, fulfilled_from_item_id
    )
    values (v_invoice.id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description',
            v_item_id,
            nullif(v_item->>'narration', ''),
            nullif(v_item->>'reserved_for_party_id', '')::uuid,
            nullif(v_item->>'fulfilled_from_item_id', '')::uuid);
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
grant execute on function public.update_invoice(
  uuid, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text, text
) to authenticated;
alter function public.update_invoice(
  uuid, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text, text
) set search_path = public;
