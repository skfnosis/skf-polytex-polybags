-- ============================================================================
-- Split the single combined "Sales" and "Purchase" accounts into per-brand
-- accounts (SKF PolyTex vs SKF PolyBags), so the Chart of Accounts / General
-- Ledger / Trial Balance can show fabric vs polybags trade activity
-- separately, matching what the Dashboard already computes on the fly from
-- each invoice's own brand/category.
--
-- Historical invoice-linked entries are reclassified onto the new accounts
-- too (there are only 7: 5 posted sale bills + 1 voided purchase's original
-- and reversal entries, all SKF PolyBags) — the old accounts' opening-balance
-- entries are left untouched since they predate the brand split and have no
-- invoice to attribute them to. The old accounts are renamed to reflect that
-- they now only hold that pre-split opening balance.
-- ============================================================================

alter table public.chart_of_accounts
  add column brand_key text references public.brand_settings(brand_key);

insert into public.chart_of_accounts (name, type, brand_key)
values
  ('SKF PolyTex Sales', 'sales', 'skf_polytex'),
  ('SKF PolyBags Sales', 'sales', 'skf_polybags'),
  ('SKF PolyTex Purchase', 'purchase', 'skf_polytex'),
  ('SKF PolyBags Purchase', 'purchase', 'skf_polybags');

update public.chart_of_accounts set name = 'Sales (Opening Balance)'
  where type = 'sales' and brand_key is null;
update public.chart_of_accounts set name = 'Purchase (Opening Balance)'
  where type = 'purchase' and brand_key is null;

-- Reclassify existing invoice/void/invoice_edit entries from the old
-- combined accounts onto the matching new brand-specific account.
update public.ledger_entries le
set account_id = (
  select coa.id from public.chart_of_accounts coa
  where coa.type = 'sales' and coa.brand_key = i.brand_key
)
from public.invoices i
where le.reference_id = i.id
  and le.reference_type in ('invoice', 'void', 'invoice_edit')
  and le.account_id = (select id from public.chart_of_accounts where type = 'sales' and brand_key is null);

update public.ledger_entries le
set account_id = (
  select coa.id from public.chart_of_accounts coa
  where coa.type = 'purchase' and coa.brand_key = i.brand_key
)
from public.invoices i
where le.reference_id = i.id
  and le.reference_type in ('invoice', 'void', 'invoice_edit')
  and le.account_id = (select id from public.chart_of_accounts where type = 'purchase' and brand_key is null);

-- ----------------------------------------------------------------------------
-- create_invoice / update_invoice — pick the trade account by brand, not
-- just by type. Same signatures as before in both cases.
-- ----------------------------------------------------------------------------
create or replace function public.create_invoice(
  p_invoice_type text, p_brand_key text, p_category text, p_party_id uuid, p_invoice_date date, p_items jsonb,
  p_supplier_invoice_no text default null, p_linked_order_id uuid default null,
  p_transport numeric default 0, p_loading numeric default 0, p_discount numeric default 0, p_tax numeric default 0,
  p_customer_po_no text default null, p_narration text default null
) returns uuid language plpgsql security definer set search_path = public as $$
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
  for v_item in select * from jsonb_array_elements(p_items) loop
    if (v_item->>'quantity')::numeric <= 0 then
      raise exception 'Line quantity must be greater than zero';
    end if;
    if (v_item->>'rate')::numeric < 0 then
      raise exception 'Line rate cannot be negative';
    end if;
  end loop;

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;
  select id into v_trade_account from public.chart_of_accounts
    where type = case when p_invoice_type in ('sale','sale_order','sale_return') then 'sales' else 'purchase' end
      and brand_key = p_brand_key
    limit 1;

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
      reserved_for_party_id, fulfilled_from_item_id, color, gsm
    )
    values (v_invoice_id,
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
    where type = case when v_invoice.invoice_type in ('sale','sale_order','sale_return') then 'sales' else 'purchase' end
      and brand_key = v_invoice.brand_key
    limit 1;

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
