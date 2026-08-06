-- ============================================================================
-- SALES MODULE — Sale Order / Sale Return as first-class document types,
-- customer PO capture, and stock movement on Sale Bill / Sale Return.
-- Mirrors the Purchase Module migration's design exactly, in the other
-- direction: Sale Bill decreases stock (soft-warns, never blocks, per the
-- "fast trading tool" decision), Sale Return increases it back.
-- ============================================================================

alter table public.invoices drop constraint invoices_invoice_type_check;
alter table public.invoices add constraint invoices_invoice_type_check
  check (invoice_type in ('sale','purchase','purchase_order','purchase_return','sale_order','sale_return'));

alter table public.invoices add column customer_po_no text;

create sequence public.sale_order_seq start 1;
create sequence public.sale_return_seq start 1;

create or replace function public.next_invoice_no(p_invoice_type text)
returns text language plpgsql as $$
begin
  if p_invoice_type = 'sale' then
    return 'SI-' || lpad(nextval('public.sale_invoice_seq')::text, 2, '0');
  elsif p_invoice_type = 'purchase' then
    return 'PI-' || lpad(nextval('public.purchase_invoice_seq')::text, 2, '0');
  elsif p_invoice_type = 'purchase_order' then
    return 'PO-' || lpad(nextval('public.purchase_order_seq')::text, 2, '0');
  elsif p_invoice_type = 'purchase_return' then
    return 'PR-' || lpad(nextval('public.purchase_return_seq')::text, 2, '0');
  elsif p_invoice_type = 'sale_order' then
    return 'SO-' || lpad(nextval('public.sale_order_seq')::text, 2, '0');
  else
    return 'SR-' || lpad(nextval('public.sale_return_seq')::text, 2, '0');
  end if;
end; $$;
alter function public.next_invoice_no(text) set search_path = public;

-- ----------------------------------------------------------------------------
-- CREATE_INVOICE — add sale_order / sale_return branches, plus stock
-- movement for 'sale' (decrease) and 'sale_return' (increase), and accept
-- p_customer_po_no. Existing callers (Purchase module, and any 'sale' calls
-- that predate customer_po_no) are unaffected: new param has a default.
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
  p_customer_po_no text default null
) returns uuid language plpgsql security definer as $$
declare
  v_page text := 'entry_purchase';
  v_invoice_id uuid;
  v_invoice_no text;
  v_subtotal numeric := 0;
  v_total numeric := 0;
  v_item jsonb;
  v_item_id uuid;
  v_party_account uuid;
  v_trade_account uuid; -- Sales or Purchase account
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
    customer_po_no
  )
  values (
    v_invoice_no, p_invoice_type, p_brand_key, p_category, p_party_id, p_invoice_date, auth.uid(),
    p_supplier_invoice_no, p_linked_order_id, coalesce(p_transport,0), coalesce(p_loading,0),
    coalesce(p_discount,0), coalesce(p_tax,0), p_customer_po_no
  )
  returning id into v_invoice_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_item_id := nullif(v_item->>'item_id', '')::uuid;

    insert into public.invoice_items (invoice_id, quantity, unit, rate, description, item_id)
    values (v_invoice_id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description',
            v_item_id);
    v_subtotal := v_subtotal + (v_item->>'quantity')::numeric * (v_item->>'rate')::numeric;

    if v_item_id is not null and p_invoice_type in ('purchase','purchase_order') then
      if p_invoice_type = 'purchase' then
        insert into public.stock_movements (item_id, movement_date, quantity_in, unit, reference_type, reference_id)
        values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'purchase_bill', v_invoice_id);
        update public.items set last_purchase_rate = (v_item->>'rate')::numeric where id = v_item_id;
      end if;
    elsif v_item_id is not null and p_invoice_type = 'purchase_return' then
      insert into public.stock_movements (item_id, movement_date, quantity_out, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'purchase_return', v_invoice_id);
    elsif v_item_id is not null and p_invoice_type = 'sale' then
      insert into public.stock_movements (item_id, movement_date, quantity_out, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'sale_bill', v_invoice_id);
      update public.items set last_sale_rate = (v_item->>'rate')::numeric where id = v_item_id;
    elsif v_item_id is not null and p_invoice_type = 'sale_return' then
      insert into public.stock_movements (item_id, movement_date, quantity_in, unit, reference_type, reference_id)
      values (v_item_id, p_invoice_date, (v_item->>'quantity')::numeric, v_item->>'unit', 'sale_return', v_invoice_id);
    end if;
  end loop;

  -- Order documents (either direction) carry no financial weight — reference only.
  if p_invoice_type in ('purchase_order', 'sale_order') then
    update public.invoices set total_amount = v_subtotal where id = v_invoice_id;
    return v_invoice_id;
  end if;

  v_total := v_subtotal + coalesce(p_transport,0) + coalesce(p_loading,0)
             + coalesce(p_tax,0) - coalesce(p_discount,0);
  update public.invoices set total_amount = v_total where id = v_invoice_id;

  if p_invoice_type = 'sale' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  elsif p_invoice_type = 'purchase' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  elsif p_invoice_type = 'purchase_return' then -- mirror of a purchase: reduces payable, reduces cost.
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  else -- sale_return: mirror of a sale — reduces receivable, reduces revenue.
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  end if;

  return v_invoice_id;
end; $$;
grant execute on function public.create_invoice(
  text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text
) to authenticated;
alter function public.create_invoice(
  text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text
) set search_path = public;

-- ----------------------------------------------------------------------------
-- VOID_INVOICE — extend the stock reversal to cover sale_bill / sale_return too.
-- ----------------------------------------------------------------------------

create or replace function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void language plpgsql security definer as $$
declare
  v_invoice public.invoices;
  v_page text;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice is null then raise exception 'Invoice not found'; end if;
  if v_invoice.status = 'voided' then raise exception 'Invoice already voided'; end if;

  v_page := case when v_invoice.invoice_type in ('sale','sale_order','sale_return') then 'entry_sale' else 'entry_purchase' end;
  if not public.has_permission(v_page, 'approve') then
    raise exception 'Not permitted to void % invoices', v_invoice.invoice_type;
  end if;

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
  select current_date, account_id, party_id, credit, debit, 'void', v_invoice.id
  from public.ledger_entries where reference_type = 'invoice' and reference_id = v_invoice.id;

  insert into public.stock_movements (item_id, movement_date, quantity_in, quantity_out, unit, reference_type, reference_id)
  select item_id, current_date, quantity_out, quantity_in, unit, 'void', v_invoice.id
  from public.stock_movements
  where reference_id = v_invoice.id
    and reference_type in ('purchase_bill','purchase_return','sale_bill','sale_return');

  update public.invoices
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_invoice_id;
end; $$;
grant execute on function public.void_invoice(uuid, text) to authenticated;
alter function public.void_invoice(uuid, text) set search_path = public;

-- ----------------------------------------------------------------------------
-- RLS — extend the sale invoices policy to cover the two new sale document types.
-- ----------------------------------------------------------------------------

drop policy "sale invoices viewable with entry_sale view" on public.invoices;
create policy "sale docs viewable with entry_sale view" on public.invoices for select
  using (invoice_type in ('sale','sale_order','sale_return')
         and public.has_permission('entry_sale','view'));
