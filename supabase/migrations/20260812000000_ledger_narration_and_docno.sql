-- ============================================================================
-- GENERAL LEDGER — narration + voucher/doc number, denormalized onto
-- ledger_entries at post time.
-- ============================================================================
-- ledger_entries never carried a narration or document-number column —
-- narration lived only on the source documents (invoices/invoice_items,
-- payments.notes, journal_vouchers.narration), and there's no clean 1:1
-- mapping from a ledger row back to "the" narration for a multi-line
-- invoice. Denormalizing both onto ledger_entries at insert time (instead
-- of trying to join them back out at report time) is what makes a General
-- Ledger report's Narration/Description and Voucher No. columns possible
-- without fragile per-reference-type joins. Every function below is
-- recreated with its exact existing signature — same business logic,
-- same permission checks, just two extra values captured on each insert.
-- ============================================================================

alter table public.ledger_entries add column narration text;
alter table public.ledger_entries add column doc_no text;

-- ----------------------------------------------------------------------------
-- create_invoice — narration is the distinct, non-empty line narrations
-- joined with "; " (falls back to the invoice's own narration field, then
-- to null); doc_no is the invoice number.
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

    insert into public.invoice_items (invoice_id, quantity, unit, rate, description, item_id, narration)
    values (v_invoice_id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description',
            v_item_id,
            nullif(v_item->>'narration', ''));
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

-- ----------------------------------------------------------------------------
-- void_invoice — carries the original narration/doc_no forward, tagged.
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

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
  select current_date, account_id, party_id, credit, debit, 'void', v_invoice.id,
         'Void — ' || coalesce(p_reason, narration, ''), doc_no
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
-- record_payment / void_payment — narration is the voucher's notes field.
-- ----------------------------------------------------------------------------
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

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
  select current_date, account_id, party_id, credit, debit, 'void', v_payment.id,
         'Void — ' || coalesce(p_reason, narration, ''), doc_no
  from public.ledger_entries where reference_type = 'payment' and reference_id = v_payment.id;

  update public.payments
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_payment_id;
end; $$;
grant execute on function public.void_payment(uuid, text) to authenticated;
alter function public.void_payment(uuid, text) set search_path = public;

-- ----------------------------------------------------------------------------
-- create_journal_voucher / void_journal_voucher — narration prefers the
-- line's own narration (already collected into journal_voucher_lines but
-- never surfaced onto the ledger), falling back to the voucher-level one.
-- ----------------------------------------------------------------------------
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

    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_voucher_date, v_account_id, v_party_id,
            coalesce((v_line->>'debit')::numeric, 0), coalesce((v_line->>'credit')::numeric, 0),
            'journal_voucher', v_voucher_id,
            coalesce(nullif(v_line->>'narration', ''), p_narration), v_voucher_no);
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

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
  select current_date, account_id, party_id, credit, debit, 'void', v_voucher.id,
         'Void — ' || coalesce(p_reason, narration, ''), doc_no
  from public.ledger_entries where reference_type = 'journal_voucher' and reference_id = v_voucher.id;

  update public.journal_vouchers
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_voucher_id;
end; $$;
grant execute on function public.void_journal_voucher(uuid, text) to authenticated;
alter function public.void_journal_voucher(uuid, text) set search_path = public;

-- ----------------------------------------------------------------------------
-- create_party — opening balance entries also get 'Opening balance' as
-- their narration.
-- ----------------------------------------------------------------------------
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
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration)
    values (current_date, v_account_id, v_party_id,
            greatest(p_opening_balance, 0), greatest(-p_opening_balance, 0),
            'opening_balance', v_party_id, 'Opening balance');
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration)
    select current_date,
           (select id from public.chart_of_accounts where type = case when p_type = 'customer' then 'sales' else 'purchase' end limit 1),
           v_party_id,
           greatest(-p_opening_balance, 0), greatest(p_opening_balance, 0),
           'opening_balance', v_party_id, 'Opening balance';
  end if;

  return v_party_id;
end; $$;
grant execute on function public.create_party(text, text, text[], text, text, numeric, text, text, text) to authenticated;
alter function public.create_party(text, text, text[], text, text, numeric, text, text, text) set search_path = public;
