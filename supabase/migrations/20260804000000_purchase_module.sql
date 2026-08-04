-- ============================================================================
-- PURCHASE MODULE — items master, stock movements, Purchase Order / Return
-- as first-class document types, and richer Purchase Bill fields.
-- ============================================================================
-- DESIGN NOTES
-- - items is a new dynamic master (per category: fabric/polybags), mirroring
--   the parties "add inline while typing" pattern. Stores last_purchase_rate
--   / last_sale_rate so entry screens can auto-fill.
-- - Stock is append-only (stock_movements), matching the ledger_entries
--   pattern already used for money — never mutate a running total in place.
--   v_stock_balance sums it per item.
-- - invoices gains two new invoice_type values: 'purchase_order' (no ledger,
--   no stock — pure reference document) and 'purchase_return' (reverses the
--   ledger direction of a purchase and reduces stock). 'purchase' remains
--   the Purchase Bill and is the only one that increases stock.
-- - create_invoice() keeps its exact original parameter list working for
--   existing 'sale'/'purchase' callers (new params are appended with
--   defaults), so the Sales module is untouched by this migration.
-- - Per the existing design note ("posted documents are never deleted, only
--   voided"), Purchase Order/Return follow the same rule: void_invoice()
--   now also reverses any stock movement it created.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ITEMS MASTER
-- ----------------------------------------------------------------------------

create table public.items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null check (category in ('fabric','polybags')),
  default_unit text not null check (default_unit in ('bags','rolls','kg','meters','pieces')),
  last_purchase_rate numeric,
  last_sale_rate numeric,
  active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (name, category)
);

create index on public.items (category, active);

create or replace function public.create_item(
  p_name text, p_category text, p_default_unit text
) returns uuid language plpgsql security definer as $$
declare
  v_item_id uuid;
begin
  if not (public.has_permission('entry_purchase','create')
          or public.has_permission('entry_sale','create')) then
    raise exception 'Not permitted to add items';
  end if;

  insert into public.items (name, category, default_unit, created_by)
  values (p_name, p_category, p_default_unit, auth.uid())
  returning id into v_item_id;

  return v_item_id;
end; $$;
grant execute on function public.create_item(text, text, text) to authenticated;
alter function public.create_item(text, text, text) set search_path = public;

-- ----------------------------------------------------------------------------
-- 2. STOCK MOVEMENTS  (append-only; written only by create_invoice/void_invoice)
-- ----------------------------------------------------------------------------

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.items(id),
  movement_date date not null,
  quantity_in numeric not null default 0,
  quantity_out numeric not null default 0,
  unit text not null,
  reference_type text not null check (reference_type in (
    'purchase_bill','purchase_return','sale_bill','sale_return','adjustment','void'
  )),
  reference_id uuid,
  created_at timestamptz not null default now()
);

create index on public.stock_movements (item_id);
create index on public.stock_movements (reference_type, reference_id);

create or replace view public.v_stock_balance as
select
  i.id as item_id, i.name, i.category, i.default_unit,
  coalesce(sum(m.quantity_in), 0) - coalesce(sum(m.quantity_out), 0) as qty_on_hand
from public.items i
left join public.stock_movements m on m.item_id = i.id
group by i.id, i.name, i.category, i.default_unit;

alter view public.v_stock_balance set (security_invoker = true);

-- ----------------------------------------------------------------------------
-- 3. INVOICES / INVOICE_ITEMS — new document types + Purchase Bill fields
-- ----------------------------------------------------------------------------

alter table public.invoices drop constraint invoices_invoice_type_check;
alter table public.invoices add constraint invoices_invoice_type_check
  check (invoice_type in ('sale','purchase','purchase_order','purchase_return'));

alter table public.invoices add column supplier_invoice_no text;
alter table public.invoices add column linked_order_id uuid references public.invoices(id);
alter table public.invoices add column transport_charges numeric not null default 0;
alter table public.invoices add column loading_charges numeric not null default 0;
alter table public.invoices add column discount_amount numeric not null default 0;
alter table public.invoices add column tax_amount numeric not null default 0;

alter table public.invoice_items drop constraint invoice_items_unit_check;
alter table public.invoice_items add constraint invoice_items_unit_check
  check (unit in ('meters','kg','pieces','bags','rolls'));
alter table public.invoice_items add column item_id uuid references public.items(id);

create index on public.invoices (linked_order_id);
create index on public.invoice_items (item_id);

-- ----------------------------------------------------------------------------
-- 4. NUMBERING — PO-.. / PR-.. alongside the existing SI-.. / PI-..
-- ----------------------------------------------------------------------------

create sequence public.purchase_order_seq start 1;
create sequence public.purchase_return_seq start 1;

create or replace function public.next_invoice_no(p_invoice_type text)
returns text language plpgsql as $$
begin
  if p_invoice_type = 'sale' then
    return 'SI-' || lpad(nextval('public.sale_invoice_seq')::text, 2, '0');
  elsif p_invoice_type = 'purchase' then
    return 'PI-' || lpad(nextval('public.purchase_invoice_seq')::text, 2, '0');
  elsif p_invoice_type = 'purchase_order' then
    return 'PO-' || lpad(nextval('public.purchase_order_seq')::text, 2, '0');
  else
    return 'PR-' || lpad(nextval('public.purchase_return_seq')::text, 2, '0');
  end if;
end; $$;
alter function public.next_invoice_no(text) set search_path = public;

-- ----------------------------------------------------------------------------
-- 5. CREATE_INVOICE — rewritten with new optional trailing params.
--    Existing 'sale'/'purchase' calls from the Sales module (which never
--    pass the new params) behave exactly as before, just with item_id/stock
--    added for 'purchase'.
-- ----------------------------------------------------------------------------

create or replace function public.create_invoice(
  p_invoice_type text, p_brand_key text, p_category text,
  p_party_id uuid, p_invoice_date date, p_items jsonb,
  p_supplier_invoice_no text default null,
  p_linked_order_id uuid default null,
  p_transport numeric default 0,
  p_loading numeric default 0,
  p_discount numeric default 0,
  p_tax numeric default 0
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
  if p_invoice_type = 'sale' then
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
    where type = case when p_invoice_type = 'sale' then 'sales' else 'purchase' end limit 1;

  v_invoice_no := public.next_invoice_no(p_invoice_type);

  insert into public.invoices (
    invoice_no, invoice_type, brand_key, category, party_id, invoice_date, created_by,
    supplier_invoice_no, linked_order_id, transport_charges, loading_charges, discount_amount, tax_amount
  )
  values (
    v_invoice_no, p_invoice_type, p_brand_key, p_category, p_party_id, p_invoice_date, auth.uid(),
    p_supplier_invoice_no, p_linked_order_id, coalesce(p_transport,0), coalesce(p_loading,0),
    coalesce(p_discount,0), coalesce(p_tax,0)
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

    -- Stock + last-rate memory only for real documents with an item on the line.
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
      update public.items set last_sale_rate = (v_item->>'rate')::numeric where id = v_item_id;
    end if;
  end loop;

  -- Purchase Order carries no financial weight at all — reference only.
  if p_invoice_type = 'purchase_order' then
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
  else -- purchase_return: mirror image of a purchase — reduces payable, reduces cost.
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  end if;

  return v_invoice_id;
end; $$;
grant execute on function public.create_invoice(
  text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric
) to authenticated;
alter function public.create_invoice(
  text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric
) set search_path = public;

-- ----------------------------------------------------------------------------
-- 6. VOID_INVOICE — also reverse any stock movement the document created.
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

  v_page := case when v_invoice.invoice_type = 'sale' then 'entry_sale' else 'entry_purchase' end;
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
    and reference_type in ('purchase_bill','purchase_return');

  update public.invoices
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_invoice_id;
end; $$;
grant execute on function public.void_invoice(uuid, text) to authenticated;
alter function public.void_invoice(uuid, text) set search_path = public;

-- ----------------------------------------------------------------------------
-- 7. RLS
-- ----------------------------------------------------------------------------

alter table public.items enable row level security;
alter table public.stock_movements enable row level security;

create policy "items readable by all authenticated" on public.items
  for select using (auth.role() = 'authenticated');

create policy "stock movements readable with purchase/sale/reports/dashboard view" on public.stock_movements
  for select using (
    public.has_permission('entry_purchase','view') or public.has_permission('entry_sale','view')
    or public.has_permission('reports','view') or public.has_permission('dashboard','view')
  );

-- Replace the old purchase-only invoice select policy with one covering all
-- three purchase document types, still gated the same way.
drop policy "purchase invoices viewable with entry_purchase view" on public.invoices;
create policy "purchase docs viewable with entry_purchase view" on public.invoices for select
  using (invoice_type in ('purchase','purchase_order','purchase_return')
         and public.has_permission('entry_purchase','view'));
