--
-- PostgreSQL database dump
--

\restrict DGzhw1gxvc7etiCYIJazdHXfYQ5cHkAyny1KzYE6EPuznKgd49smH0hYaqaOpzC

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.10 (Ubuntu 17.10-1.pgdg24.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: create_account(text, text, text, uuid, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_account(p_name text, p_type text, p_cash_bank_kind text DEFAULT NULL::text, p_parent_account_id uuid DEFAULT NULL::uuid, p_opening_balance numeric DEFAULT 0, p_opening_balance_type text DEFAULT 'debit'::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_account_id uuid;
  v_equity_account_id uuid;
  v_debit numeric;
  v_credit numeric;
begin
  if not coalesce((select is_admin from public.profiles where id = auth.uid()), false) then
    raise exception 'Admin only';
  end if;
  if p_opening_balance_type not in ('debit', 'credit') then
    raise exception 'Opening balance type must be debit or credit';
  end if;

  insert into public.chart_of_accounts (name, type, cash_bank_kind, parent_account_id)
  values (p_name, p_type, case when p_type = 'cash_bank' then p_cash_bank_kind else null end, p_parent_account_id)
  returning id into v_account_id;

  if p_opening_balance > 0 then
    select id into v_equity_account_id from public.chart_of_accounts where name = 'Opening Balance Equity' and is_system limit 1;

    if p_opening_balance_type = 'debit' then
      v_debit := p_opening_balance; v_credit := 0;
    else
      v_debit := 0; v_credit := p_opening_balance;
    end if;

    insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id, narration)
    values (current_date, v_account_id, v_debit, v_credit, 'opening_balance', v_account_id, 'Opening balance');
    insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id, narration)
    values (current_date, v_equity_account_id, v_credit, v_debit, 'opening_balance', v_account_id, 'Opening balance — ' || p_name);
  end if;

  return v_account_id;
end; $$;


--
-- Name: create_expense(date, uuid, uuid, text, text, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_expense(p_expense_date date, p_expense_account_id uuid, p_cash_bank_account_id uuid, p_brand_key text, p_description text, p_amount numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_expense_id uuid;
begin
  if not public.has_permission('entry_expense', 'create') then
    raise exception 'Not permitted to create expenses';
  end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;

  insert into public.expenses (expense_date, expense_account_id, cash_bank_account_id,
                                brand_key, description, amount, created_by)
  values (p_expense_date, p_expense_account_id, p_cash_bank_account_id,
          p_brand_key, p_description, p_amount, auth.uid())
  returning id into v_expense_id;

  insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id)
  values (p_expense_date, p_expense_account_id, p_amount, 0, 'expense', v_expense_id);
  insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id)
  values (p_expense_date, p_cash_bank_account_id, 0, p_amount, 'expense', v_expense_id);

  return v_expense_id;
end; $$;


--
-- Name: create_invoice(text, text, text, uuid, date, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_invoice(p_invoice_type text, p_brand_key text, p_category text, p_party_id uuid, p_invoice_date date, p_items jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_page text := case when p_invoice_type = 'sale' then 'entry_sale' else 'entry_purchase' end;
  v_invoice_id uuid;
  v_invoice_no text;
  v_total numeric := 0;
  v_item jsonb;
  v_party_account uuid;
  v_trade_account uuid; -- Sales or Purchase account
begin
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

  insert into public.invoices (invoice_no, invoice_type, brand_key, category, party_id, invoice_date, created_by)
  values (v_invoice_no, p_invoice_type, p_brand_key, p_category, p_party_id, p_invoice_date, auth.uid())
  returning id into v_invoice_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    insert into public.invoice_items (invoice_id, quantity, unit, rate, description)
    values (v_invoice_id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description');
    v_total := v_total + (v_item->>'quantity')::numeric * (v_item->>'rate')::numeric;
  end loop;

  update public.invoices set total_amount = v_total where id = v_invoice_id;

  -- Sale: debit the customer (they owe us more), credit Sales.
  -- Purchase: debit Purchase (expense of goods), credit the supplier (we owe more).
  if p_invoice_type = 'sale' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  end if;

  return v_invoice_id;
end; $$;


--
-- Name: create_invoice(text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_invoice(p_invoice_type text, p_brand_key text, p_category text, p_party_id uuid, p_invoice_date date, p_items jsonb, p_supplier_invoice_no text DEFAULT NULL::text, p_linked_order_id uuid DEFAULT NULL::uuid, p_transport numeric DEFAULT 0, p_loading numeric DEFAULT 0, p_discount numeric DEFAULT 0, p_tax numeric DEFAULT 0) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  end if;

  return v_invoice_id;
end; $$;


--
-- Name: create_invoice(text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_invoice(p_invoice_type text, p_brand_key text, p_category text, p_party_id uuid, p_invoice_date date, p_items jsonb, p_supplier_invoice_no text DEFAULT NULL::text, p_linked_order_id uuid DEFAULT NULL::uuid, p_transport numeric DEFAULT 0, p_loading numeric DEFAULT 0, p_discount numeric DEFAULT 0, p_tax numeric DEFAULT 0, p_customer_po_no text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
  elsif p_invoice_type = 'purchase_return' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  end if;

  return v_invoice_id;
end; $$;


--
-- Name: create_invoice(text, text, text, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_invoice(p_invoice_type text, p_brand_key text, p_category text, p_party_id uuid, p_invoice_date date, p_items jsonb, p_supplier_invoice_no text DEFAULT NULL::text, p_linked_order_id uuid DEFAULT NULL::uuid, p_transport numeric DEFAULT 0, p_loading numeric DEFAULT 0, p_discount numeric DEFAULT 0, p_tax numeric DEFAULT 0, p_customer_po_no text DEFAULT NULL::text, p_narration text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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

    insert into public.invoice_items (invoice_id, quantity, unit, rate, description, item_id, narration)
    values (v_invoice_id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description',
            v_item_id,
            nullif(v_item->>'narration', ''));
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


--
-- Name: create_item(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_item(p_name text, p_category text, p_default_unit text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: create_item(text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_item(p_name text, p_category text, p_default_unit text, p_fabric_group text DEFAULT NULL::text, p_composition text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_item_id uuid;
begin
  if not (public.has_permission('entry_purchase','create')
          or public.has_permission('entry_sale','create')
          or public.has_permission('item_master','create')) then
    raise exception 'Not permitted to add items';
  end if;

  insert into public.items (name, category, default_unit, fabric_group, composition, created_by)
  values (p_name, p_category, p_default_unit,
          case when p_category = 'fabric' then p_fabric_group else null end,
          case when p_category = 'fabric' then p_composition else null end,
          auth.uid())
  returning id into v_item_id;

  return v_item_id;
end; $$;


--
-- Name: create_item(text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_item(p_name text, p_category text, p_default_unit text, p_fabric_group text DEFAULT NULL::text, p_composition text DEFAULT NULL::text, p_item_type text DEFAULT 'product'::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_item_id uuid;
begin
  if not (public.has_permission('entry_purchase','create')
          or public.has_permission('entry_sale','create')
          or public.has_permission('item_master','create')) then
    raise exception 'Not permitted to add items';
  end if;

  insert into public.items (name, category, default_unit, fabric_group, composition, item_type, created_by)
  values (p_name, p_category, p_default_unit,
          case when p_category = 'fabric' then p_fabric_group else null end,
          case when p_category = 'fabric' then p_composition else null end,
          coalesce(p_item_type, 'product'),
          auth.uid())
  returning id into v_item_id;

  return v_item_id;
end; $$;


--
-- Name: create_journal_voucher(date, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_journal_voucher(p_voucher_date date, p_narration text, p_lines jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: create_party(text, text, text[], text, text, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_party(p_name text, p_type text, p_category text[], p_contact text, p_address text, p_opening_balance numeric DEFAULT 0) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_account_id uuid;
  v_party_id uuid;
begin
  insert into public.chart_of_accounts (name, type) values (p_name, 'party')
    returning id into v_account_id;

  insert into public.parties (name, type, category, contact, address,
                               ledger_account_id, opening_balance, created_by)
  values (p_name, p_type, p_category, p_contact, p_address,
          v_account_id, p_opening_balance, auth.uid())
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


--
-- Name: create_party(text, text, text[], text, text, numeric, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_party(p_name text, p_type text, p_category text[], p_contact text, p_address text, p_opening_balance numeric DEFAULT 0, p_email text DEFAULT NULL::text, p_ntn text DEFAULT NULL::text, p_stn text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: dashboard_cashflow(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_cashflow(p_from date, p_to date) RETURNS TABLE(cash_in numeric, cash_out numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    coalesce((select sum(amount) from public.payments
      where direction = 'receipt' and status = 'posted' and payment_date between p_from and p_to), 0),
    coalesce((select sum(amount) from public.payments
      where direction = 'payment' and status = 'posted' and payment_date between p_from and p_to), 0)
    + coalesce((select sum(amount) from public.expenses
      where status = 'posted' and expense_date between p_from and p_to), 0)
  where public.has_permission('dashboard', 'view');
$$;


--
-- Name: dashboard_monthly_breakdown(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_monthly_breakdown(p_from date, p_to date) RETURNS TABLE(month date, fabric_sales numeric, polybag_sales numeric, total_sales numeric, total_purchase numeric, expenses numeric, profit numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with months as (
    select date_trunc('month', gs)::date as month
    from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') gs
  ),
  sales as (
    select date_trunc('month', i.invoice_date)::date as month, b.category, sum(i.total_amount) as amt
    from public.invoices i
    join public.brand_settings b on b.brand_key = i.brand_key
    where i.invoice_type = 'sale' and i.status = 'posted'
    group by 1, 2
  ),
  purchases as (
    select date_trunc('month', i.invoice_date)::date as month, sum(i.total_amount) as amt
    from public.invoices i
    where i.invoice_type = 'purchase' and i.status = 'posted'
    group by 1
  ),
  expense_totals as (
    select date_trunc('month', l.entry_date)::date as month, sum(l.debit) - sum(l.credit) as amt
    from public.ledger_entries l
    join public.chart_of_accounts a on a.id = l.account_id
    where a.type = 'expense'
    group by 1
  )
  select
    m.month,
    coalesce((select amt from sales s where s.month = m.month and s.category = 'fabric'), 0) as fabric_sales,
    coalesce((select amt from sales s where s.month = m.month and s.category = 'polybags'), 0) as polybag_sales,
    coalesce((select sum(amt) from sales s where s.month = m.month), 0) as total_sales,
    coalesce((select amt from purchases p where p.month = m.month), 0) as total_purchase,
    coalesce((select amt from expense_totals e where e.month = m.month), 0) as expenses,
    coalesce((select sum(amt) from sales s where s.month = m.month), 0)
      - coalesce((select amt from purchases p where p.month = m.month), 0)
      - coalesce((select amt from expense_totals e where e.month = m.month), 0) as profit
  from months m
  where public.has_permission('dashboard', 'view')
  order by m.month;
$$;


--
-- Name: dashboard_receivables_overdue(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_receivables_overdue() RETURNS TABLE(total_receivables numeric, overdue_receivables numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    coalesce((select sum(balance) from public.v_party_balances where type = 'customer' and balance > 0), 0),
    coalesce((select sum(outstanding) from public.v_invoice_outstanding
      where invoice_type = 'sale' and outstanding > 0 and invoice_date < current_date - 30), 0)
  where public.has_permission('dashboard', 'view');
$$;


--
-- Name: dashboard_sales_overview(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_sales_overview(p_from date, p_to date) RETURNS TABLE(category text, quantity numeric, amount numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select i.category, coalesce(sum(ii.quantity), 0), coalesce(sum(ii.amount), 0)
  from public.invoices i join public.invoice_items ii on ii.invoice_id = i.id
  where i.invoice_type = 'sale' and i.status = 'posted'
    and i.invoice_date between p_from and p_to
    and public.has_permission('dashboard', 'view')
  group by i.category;
$$;


--
-- Name: dashboard_summary(date, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_summary(p_from date, p_to date, p_brand text DEFAULT NULL::text) RETURNS TABLE(sales numeric, purchase numeric, expenses numeric, profit numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'sale' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0) as sales,
    coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'purchase' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0) as purchase,
    coalesce((select sum(amount) from public.expenses
              where status = 'posted' and expense_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand or brand_key is null)), 0) as expenses,
    coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'sale' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0)
    - coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'purchase' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0)
    - coalesce((select sum(amount) from public.expenses
              where status = 'posted' and expense_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand or brand_key is null)), 0) as profit;
$$;


--
-- Name: dashboard_top_customers(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_top_customers(p_from date, p_to date) RETURNS TABLE(party_id uuid, name text, total_sales numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select p.id, p.name, sum(i.total_amount)
  from public.invoices i join public.parties p on p.id = i.party_id
  where i.invoice_type = 'sale' and i.status = 'posted'
    and i.invoice_date between p_from and p_to
    and public.has_permission('dashboard', 'view')
  group by p.id, p.name
  order by sum(i.total_amount) desc
  limit 5;
$$;


--
-- Name: email_for_username(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.email_for_username(p_username text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select u.email
  from auth.users u
  join public.profiles p on p.id = u.id
  where p.username = p_username and p.active = true
  limit 1;
$$;


--
-- Name: fetch_unposted_documents(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fetch_unposted_documents() RETURNS TABLE(doc_type text, doc_no text, doc_date date, party_name text, amount numeric, ledger_total numeric, note text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.profiles (id, username, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
          coalesce(new.raw_user_meta_data->>'full_name', 'New User'));
  return new;
end; $$;


--
-- Name: has_permission(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_permission(p_page text, p_action text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET row_security TO 'off'
    AS $$
  select
    coalesce((select is_admin from public.profiles where id = auth.uid()), false)
    or exists (
      select 1 from public.page_permissions pp
      where pp.user_id = auth.uid() and pp.page_key = p_page
        and case p_action
              when 'view' then pp.can_view
              when 'create' then pp.can_create
              when 'edit' then pp.can_edit
              when 'approve' then pp.can_approve
              else false
            end
    );
$$;


--
-- Name: next_invoice_no(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.next_invoice_no(p_invoice_type text) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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


--
-- Name: next_voucher_no(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.next_voucher_no(p_direction text, p_kind text) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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


--
-- Name: record_payment(date, uuid, text, numeric, text, uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_payment(p_payment_date date, p_party_id uuid, p_direction text, p_amount numeric, p_method text, p_cash_bank_account_id uuid, p_linked_invoice_id uuid, p_notes text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


--
-- Name: set_party_opening_balance(uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_party_opening_balance(p_party_id uuid, p_amount numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_party public.parties;
begin
  if not (public.has_permission('party_master','edit')
          or public.has_permission('entry_sale','edit')
          or public.has_permission('entry_purchase','edit')) then
    raise exception 'Not permitted to edit parties';
  end if;

  select * into v_party from public.parties where id = p_party_id;
  if v_party is null then raise exception 'Party not found'; end if;
  if v_party.opening_balance <> 0 then
    raise exception 'Party already has an opening balance set — void the existing opening_balance ledger entries first if it needs to change';
  end if;

  update public.parties set opening_balance = p_amount where id = p_party_id;

  if p_amount <> 0 then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration)
    values (current_date, v_party.ledger_account_id, p_party_id,
            greatest(p_amount, 0), greatest(-p_amount, 0),
            'opening_balance', p_party_id, 'Opening balance');
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration)
    select current_date,
           (select id from public.chart_of_accounts where type = case when v_party.type = 'customer' then 'sales' else 'purchase' end limit 1),
           p_party_id,
           greatest(-p_amount, 0), greatest(p_amount, 0),
           'opening_balance', p_party_id, 'Opening balance';
  end if;
end; $$;


--
-- Name: update_item(uuid, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_item(p_item_id uuid, p_name text, p_default_unit text, p_fabric_group text DEFAULT NULL::text, p_composition text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not (public.has_permission('entry_purchase','edit')
          or public.has_permission('entry_sale','edit')
          or public.has_permission('item_master','edit')) then
    raise exception 'Not permitted to edit items';
  end if;

  update public.items set
    name = coalesce(p_name, name),
    default_unit = coalesce(p_default_unit, default_unit),
    fabric_group = case when category = 'fabric' then p_fabric_group else null end,
    composition = case when category = 'fabric' then p_composition else null end
  where id = p_item_id;
end; $$;


--
-- Name: update_party(uuid, text, text, text, text, text, text, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_party(p_party_id uuid, p_name text, p_contact text, p_address text, p_email text DEFAULT NULL::text, p_ntn text DEFAULT NULL::text, p_stn text DEFAULT NULL::text, p_category text[] DEFAULT NULL::text[]) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: void_expense(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.void_expense(p_expense_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_expense public.expenses;
begin
  select * into v_expense from public.expenses where id = p_expense_id;
  if v_expense is null then raise exception 'Expense not found'; end if;
  if v_expense.status = 'voided' then raise exception 'Expense already voided'; end if;
  if not public.has_permission('entry_expense', 'approve') then
    raise exception 'Not permitted to void expenses';
  end if;

  insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id)
  select current_date, account_id, credit, debit, 'void', v_expense.id
  from public.ledger_entries where reference_type = 'expense' and reference_id = v_expense.id;

  update public.expenses
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_expense_id;
end; $$;


--
-- Name: void_invoice(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: void_journal_voucher(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.void_journal_voucher(p_voucher_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: void_payment(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.void_payment(p_payment_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    id integer DEFAULT 1 NOT NULL,
    low_cash_threshold numeric DEFAULT 0 NOT NULL,
    high_payables_threshold numeric DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_settings_id_check CHECK ((id = 1))
);


--
-- Name: bpv_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bpv_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: brand_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brand_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brand_key text NOT NULL,
    display_name text NOT NULL,
    category text NOT NULL,
    logo_url text,
    address text,
    contact_info text,
    CONSTRAINT brand_settings_brand_key_check CHECK ((brand_key = ANY (ARRAY['skf_polytex'::text, 'skf_polybags'::text]))),
    CONSTRAINT brand_settings_category_check CHECK ((category = ANY (ARRAY['fabric'::text, 'polybags'::text])))
);


--
-- Name: brv_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.brv_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chart_of_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chart_of_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    cash_bank_kind text,
    parent_account_id uuid,
    CONSTRAINT chart_of_accounts_cash_bank_kind_check CHECK (((cash_bank_kind IS NULL) OR (cash_bank_kind = ANY (ARRAY['cash'::text, 'bank'::text])))),
    CONSTRAINT chart_of_accounts_type_check CHECK ((type = ANY (ARRAY['sales'::text, 'purchase'::text, 'expense'::text, 'cash_bank'::text, 'party'::text, 'drawings'::text, 'asset'::text, 'liability'::text, 'capital'::text, 'income'::text])))
);


--
-- Name: cpv_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cpv_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crv_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crv_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: expenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    expense_date date NOT NULL,
    expense_account_id uuid NOT NULL,
    cash_bank_account_id uuid NOT NULL,
    brand_key text,
    description text,
    amount numeric NOT NULL,
    status text DEFAULT 'posted'::text NOT NULL,
    voided_at timestamp with time zone,
    voided_by uuid,
    void_reason text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT expenses_status_check CHECK ((status = ANY (ARRAY['posted'::text, 'voided'::text])))
);


--
-- Name: heartbeat; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heartbeat (
    id integer DEFAULT 1 NOT NULL,
    pinged_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: invoice_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_id uuid NOT NULL,
    quantity numeric NOT NULL,
    unit text NOT NULL,
    rate numeric NOT NULL,
    description text,
    amount numeric GENERATED ALWAYS AS ((quantity * rate)) STORED,
    item_id uuid,
    narration text,
    CONSTRAINT invoice_items_unit_check CHECK ((unit = ANY (ARRAY['KG'::text, 'PCS'::text])))
);


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_no text NOT NULL,
    invoice_type text NOT NULL,
    brand_key text NOT NULL,
    category text NOT NULL,
    party_id uuid NOT NULL,
    invoice_date date NOT NULL,
    total_amount numeric DEFAULT 0 NOT NULL,
    status text DEFAULT 'posted'::text NOT NULL,
    voided_at timestamp with time zone,
    voided_by uuid,
    void_reason text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    supplier_invoice_no text,
    linked_order_id uuid,
    transport_charges numeric DEFAULT 0 NOT NULL,
    loading_charges numeric DEFAULT 0 NOT NULL,
    discount_amount numeric DEFAULT 0 NOT NULL,
    tax_amount numeric DEFAULT 0 NOT NULL,
    customer_po_no text,
    narration text,
    CONSTRAINT invoices_category_check CHECK ((category = ANY (ARRAY['fabric'::text, 'polybags'::text]))),
    CONSTRAINT invoices_invoice_type_check CHECK ((invoice_type = ANY (ARRAY['sale'::text, 'purchase'::text, 'purchase_order'::text, 'purchase_return'::text, 'sale_order'::text, 'sale_return'::text]))),
    CONSTRAINT invoices_status_check CHECK ((status = ANY (ARRAY['posted'::text, 'voided'::text])))
);


--
-- Name: items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    category text NOT NULL,
    default_unit text NOT NULL,
    last_purchase_rate numeric,
    last_sale_rate numeric,
    active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    manual_stock_value numeric,
    fabric_group text,
    composition text,
    item_type text DEFAULT 'product'::text NOT NULL,
    CONSTRAINT items_category_check CHECK ((category = ANY (ARRAY['fabric'::text, 'polybags'::text]))),
    CONSTRAINT items_default_unit_check CHECK ((default_unit = ANY (ARRAY['KG'::text, 'PCS'::text]))),
    CONSTRAINT items_fabric_group_check CHECK (((fabric_group IS NULL) OR (fabric_group = ANY (ARRAY['in_house'::text, 'knitting_dying'::text])))),
    CONSTRAINT items_item_type_check CHECK ((item_type = ANY (ARRAY['product'::text, 'service'::text])))
);


--
-- Name: journal_voucher_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_voucher_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    voucher_id uuid NOT NULL,
    account_id uuid NOT NULL,
    party_id uuid,
    debit numeric DEFAULT 0 NOT NULL,
    credit numeric DEFAULT 0 NOT NULL,
    line_narration text
);


--
-- Name: journal_vouchers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_vouchers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    voucher_no text NOT NULL,
    voucher_date date NOT NULL,
    narration text,
    total_amount numeric DEFAULT 0 NOT NULL,
    status text DEFAULT 'posted'::text NOT NULL,
    voided_at timestamp with time zone,
    voided_by uuid,
    void_reason text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT journal_vouchers_status_check CHECK ((status = ANY (ARRAY['posted'::text, 'voided'::text])))
);


--
-- Name: jv_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.jv_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entry_date date NOT NULL,
    account_id uuid NOT NULL,
    party_id uuid,
    debit numeric DEFAULT 0 NOT NULL,
    credit numeric DEFAULT 0 NOT NULL,
    reference_type text NOT NULL,
    reference_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    narration text,
    doc_no text,
    CONSTRAINT ledger_entries_reference_type_check CHECK ((reference_type = ANY (ARRAY['invoice'::text, 'expense'::text, 'payment'::text, 'opening_balance'::text, 'void'::text, 'journal_voucher'::text])))
);


--
-- Name: page_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.page_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    page_key text NOT NULL,
    can_view boolean DEFAULT false NOT NULL,
    can_create boolean DEFAULT false NOT NULL,
    can_edit boolean DEFAULT false NOT NULL,
    can_approve boolean DEFAULT false NOT NULL,
    granted_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT page_permissions_page_key_check CHECK ((page_key = ANY (ARRAY['dashboard'::text, 'entry_voucher'::text, 'entry_jv'::text, 'entry_sale'::text, 'entry_purchase'::text, 'item_master'::text, 'party_master'::text, 'settings'::text])))
);


--
-- Name: parties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parties (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    category text[] DEFAULT '{}'::text[] NOT NULL,
    contact text,
    address text,
    ledger_account_id uuid,
    opening_balance numeric DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    email text,
    ntn text,
    stn text,
    CONSTRAINT parties_type_check CHECK ((type = ANY (ARRAY['customer'::text, 'supplier'::text])))
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_date date NOT NULL,
    party_id uuid NOT NULL,
    direction text NOT NULL,
    amount numeric NOT NULL,
    method text,
    cash_bank_account_id uuid NOT NULL,
    linked_invoice_id uuid,
    notes text,
    status text DEFAULT 'posted'::text NOT NULL,
    voided_at timestamp with time zone,
    voided_by uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    voucher_no text,
    void_reason text,
    CONSTRAINT payments_direction_check CHECK ((direction = ANY (ARRAY['receipt'::text, 'payment'::text]))),
    CONSTRAINT payments_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'bank_transfer'::text, 'cheque'::text, 'other'::text]))),
    CONSTRAINT payments_status_check CHECK ((status = ANY (ARRAY['posted'::text, 'voided'::text])))
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username text NOT NULL,
    full_name text NOT NULL,
    is_admin boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_login timestamp with time zone
);


--
-- Name: purchase_invoice_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.purchase_invoice_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: purchase_order_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.purchase_order_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: purchase_return_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.purchase_return_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sale_invoice_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sale_invoice_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sale_order_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sale_order_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sale_return_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sale_return_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stock_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_movements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    item_id uuid NOT NULL,
    movement_date date NOT NULL,
    quantity_in numeric DEFAULT 0 NOT NULL,
    quantity_out numeric DEFAULT 0 NOT NULL,
    unit text NOT NULL,
    reference_type text NOT NULL,
    reference_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stock_movements_reference_type_check CHECK ((reference_type = ANY (ARRAY['purchase_bill'::text, 'purchase_return'::text, 'sale_bill'::text, 'sale_return'::text, 'adjustment'::text, 'void'::text])))
);


--
-- Name: v_invoice_outstanding; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_invoice_outstanding WITH (security_invoker='true') AS
 SELECT id AS invoice_id,
    invoice_no,
    invoice_type,
    party_id,
    invoice_date,
    total_amount,
    (total_amount - COALESCE(( SELECT sum(pm.amount) AS sum
           FROM public.payments pm
          WHERE ((pm.linked_invoice_id = i.id) AND (pm.status = 'posted'::text))), (0)::numeric)) AS outstanding
   FROM public.invoices i
  WHERE (status = 'posted'::text);


--
-- Name: v_party_balances; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_party_balances WITH (security_invoker='true') AS
 SELECT p.id AS party_id,
    p.name,
    p.type,
    p.category,
    (COALESCE(sum(l.debit), (0)::numeric) - COALESCE(sum(l.credit), (0)::numeric)) AS balance
   FROM (public.parties p
     LEFT JOIN public.ledger_entries l ON ((l.account_id = p.ledger_account_id)))
  GROUP BY p.id, p.name, p.type, p.category;


--
-- Name: v_stock_balance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_stock_balance WITH (security_invoker='true') AS
 SELECT i.id AS item_id,
    i.name,
    i.category,
    i.default_unit,
    (COALESCE(sum(m.quantity_in), (0)::numeric) - COALESCE(sum(m.quantity_out), (0)::numeric)) AS qty_on_hand
   FROM (public.items i
     LEFT JOIN public.stock_movements m ON ((m.item_id = i.id)))
  GROUP BY i.id, i.name, i.category, i.default_unit;


--
-- Name: v_trial_balance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_trial_balance WITH (security_invoker='true') AS
 SELECT a.id AS account_id,
    a.name,
    a.type,
    COALESCE(sum(l.debit), (0)::numeric) AS total_debit,
    COALESCE(sum(l.credit), (0)::numeric) AS total_credit,
    (COALESCE(sum(l.debit), (0)::numeric) - COALESCE(sum(l.credit), (0)::numeric)) AS balance
   FROM (public.chart_of_accounts a
     LEFT JOIN public.ledger_entries l ON ((l.account_id = a.id)))
  GROUP BY a.id, a.name, a.type;


--
-- Data for Name: app_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.app_settings (id, low_cash_threshold, high_payables_threshold, updated_at) FROM stdin;
1	0	0	2026-08-04 22:15:21.935755+00
\.


--
-- Data for Name: brand_settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.brand_settings (id, brand_key, display_name, category, logo_url, address, contact_info) FROM stdin;
0299a8a0-2264-4b87-9b93-a30b3714dd85	skf_polytex	SKF PolyTex	fabric	\N	\N	\N
970f2e06-7fbb-4e29-ac4c-61129711a4c2	skf_polybags	SKF PolyBags	polybags	\N	\N	\N
\.


--
-- Data for Name: chart_of_accounts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.chart_of_accounts (id, name, type, is_system, created_at, cash_bank_kind, parent_account_id) FROM stdin;
6005ba1e-cd53-4805-9502-6a48a899f6eb	Sales	sales	t	2026-08-02 20:46:57.542673+00	\N	\N
4d83866f-efb8-43d0-954a-b424f2711003	Purchase	purchase	t	2026-08-02 20:46:57.542673+00	\N	\N
18a17032-5d3c-4f45-8731-7959254e37b0	Fuel & Transport	expense	t	2026-08-02 20:46:57.542673+00	\N	\N
50201935-c3d5-4b05-8424-3f69c7b0507b	Rent	expense	t	2026-08-02 20:46:57.542673+00	\N	\N
d05b4fa1-0ca1-4a2c-ab22-4342f93b0245	Salaries	expense	t	2026-08-02 20:46:57.542673+00	\N	\N
1aea2139-d6a1-4581-b421-04dee3bb2234	Utilities	expense	t	2026-08-02 20:46:57.542673+00	\N	\N
75d2313a-6eea-4ce3-bee0-232fcc06310e	Miscellaneous	expense	t	2026-08-02 20:46:57.542673+00	\N	\N
46ff676e-30cb-49e1-901b-f714a0c05ed1	Cash in Hand	cash_bank	t	2026-08-02 20:46:57.542673+00	cash	\N
8fd89e74-fc8e-4e1d-ba98-f837fd2e6bb6	Bank Account	cash_bank	t	2026-08-02 20:46:57.542673+00	bank	\N
1254f6b8-dc0c-4150-a27a-2f40d24622a5	FARAZ SPORTS	party	f	2026-08-06 19:01:01.515349+00	\N	\N
503a26fb-fd31-421f-a58f-318c73a7ceec	CASH SALE	party	f	2026-08-06 21:18:20.995209+00	\N	\N
14439af5-cb8b-40c8-a17d-5b7f88a6208d	FARAZ HOSIERY	party	f	2026-08-06 21:18:20.995209+00	\N	\N
21c01cc6-ee96-4dcd-83c2-64871c947d95	AWAMI DYEING	party	f	2026-08-06 21:18:20.995209+00	\N	\N
a0a21a09-6446-4de1-adfe-3a8ff21ed57b	GONDAL DYEING	party	f	2026-08-06 21:18:20.995209+00	\N	\N
15d11f17-44ee-4a3b-9ace-7fd690a91023	BHUTTA DYEING	party	f	2026-08-06 21:18:20.995209+00	\N	\N
85f9697c-6bc7-466e-bc6e-bd62edab7b56	MUNAWAR INDUSTRIES	party	f	2026-08-06 21:18:20.995209+00	\N	\N
e0069fdb-38ed-4475-b4e7-a51af40322ee	BLUE HORIZON	party	f	2026-08-06 21:18:20.995209+00	\N	\N
460aa95d-1519-4435-b641-3e76f6e0016e	NEKA PAK	party	f	2026-08-06 21:18:20.995209+00	\N	\N
ab016eb2-4a52-4636-a48e-e10dfa2c67a9	RS PLASTIC	party	f	2026-08-06 21:18:20.995209+00	\N	\N
4ebee95b-f8ec-43c6-be50-5879ecf064e3	ZAK ENTERPRISES	party	f	2026-08-06 21:18:20.995209+00	\N	\N
9682f10e-5b8d-46d2-99d0-98d8010a7f8d	UMER PLASTIC	party	f	2026-08-06 21:18:20.995209+00	\N	\N
2739f933-b52f-43fd-8091-7f4583376cbd	FARAZ SPORTS	party	f	2026-08-06 21:18:20.995209+00	\N	\N
5a6b672c-cf6a-40ed-96d6-1c683bf71b65	Owner's Drawings	drawings	t	2026-08-09 19:56:17.864476+00	\N	\N
d5cbfa4c-bc77-4560-8995-b2f8928aff38	Opening Balance Equity	capital	t	2026-08-11 16:37:27.579308+00	\N	\N
\.


--
-- Data for Name: expenses; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.expenses (id, expense_date, expense_account_id, cash_bank_account_id, brand_key, description, amount, status, voided_at, voided_by, void_reason, created_by, created_at) FROM stdin;
\.


--
-- Data for Name: heartbeat; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.heartbeat (id, pinged_at) FROM stdin;
1	2026-08-02 20:46:57.542673+00
\.


--
-- Data for Name: invoice_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.invoice_items (id, invoice_id, quantity, unit, rate, description, item_id, narration) FROM stdin;
e8dce339-6704-446f-be78-ad412a612f6b	d3ba4e2f-e852-488a-9510-38ea823e76d5	1	PCS	3000	Fabric	9307a034-5509-4f0c-9674-d948f7cd7ece	\N
69d056d0-68f9-4ec1-a95f-6a6959c13261	aaa664ee-8b34-4f37-8258-82bfb30a640d	13.25	KG	825	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
a0a47e51-fb6a-4905-8a56-a86e665d4fc7	aaa664ee-8b34-4f37-8258-82bfb30a640d	134.6	KG	525	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
1afe0314-cc3b-4249-8b51-6179104dc667	aaa664ee-8b34-4f37-8258-82bfb30a640d	265.49	KG	615	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
e127f91c-41cf-4b8b-a337-c14cd925d442	aaa664ee-8b34-4f37-8258-82bfb30a640d	29.2	KG	650	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
75c132cc-f032-4af0-bf5f-370df9da412e	aaa664ee-8b34-4f37-8258-82bfb30a640d	129.5	KG	690	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
c326dbab-e29b-42be-b0ae-49a0e7137878	aaa664ee-8b34-4f37-8258-82bfb30a640d	254	KG	680	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
9a706773-ebb2-4c28-976e-edee719e7b50	aaa664ee-8b34-4f37-8258-82bfb30a640d	355.7	KG	650	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
b6bc6230-5e91-402a-8dab-d31c5287ee7a	aaa664ee-8b34-4f37-8258-82bfb30a640d	31.4	KG	705	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
d42c7b5b-8196-47a5-b95d-4906ea42b7e3	aaa664ee-8b34-4f37-8258-82bfb30a640d	404.35	KG	720	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
bc86a7ae-abed-44d4-a486-4175f79ac28b	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	305.5	KG	710	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
bd02b708-8eee-4c7b-b558-f618e2a622eb	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	81.15	KG	825	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
a2726532-8c07-45b9-9a14-2707604f8c5f	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	25	KG	675	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
83db7813-9e28-4719-8d73-7a556a8a628c	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	406.17	KG	625	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
14282b22-d19e-4987-b3e3-d34112b3a065	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	174.75	KG	640	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
1c5459f5-dc34-4ba2-a828-6cb8c2981c7a	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	50.5	KG	650	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
86b9d1db-8c19-42ad-93eb-6ae4b52d1c14	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	28.5	KG	920	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
8865e162-065b-4983-bb19-b0cd242f4413	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	1	PCS	4690	Block	4237b09a-1618-403a-9c21-18976904a79d	\N
a6592740-114c-4044-bba2-98c8a17af2e6	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	253.15	KG	680	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
836e8af0-643c-47ec-aca5-55e0fdc9d0cd	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	88.35	KG	885	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
bb0ee24e-d7b9-48fc-8d14-2565b1343508	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	30.5	KG	665	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
5a96bac4-774f-461b-a010-a80c86f7bb57	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	50	KG	710	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
3bc7e210-b98c-4c15-ae9a-8b0a60d251a9	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	403.93	KG	625	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
47bcb5ea-9455-4a15-9d67-866646b6e49c	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	62.9	KG	665	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	\N
\.


--
-- Data for Name: invoices; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.invoices (id, invoice_no, invoice_type, brand_key, category, party_id, invoice_date, total_amount, status, voided_at, voided_by, void_reason, created_by, created_at, supplier_invoice_no, linked_order_id, transport_charges, loading_charges, discount_amount, tax_amount, customer_po_no, narration) FROM stdin;
d3ba4e2f-e852-488a-9510-38ea823e76d5	SI-01	sale	skf_polytex	fabric	eb57e29e-f2a3-4310-ae6c-cae53438df4a	2026-08-11	3000	posted	\N	\N	\N	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-11 15:37:12.577229+00	\N	\N	0	0	0	0	Swatch Book	\N
aaa664ee-8b34-4f37-8258-82bfb30a640d	PI-01	purchase	skf_polybags	polybags	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-11	1070401.60	posted	\N	\N	\N	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-11 18:01:20.5374+00	\N	\N	0	0	0	0	\N	\N
ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	PI-02	purchase	skf_polybags	polybags	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-11	1330559.00	posted	\N	\N	\N	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-11 18:51:26.207523+00	\N	\N	0	0	0	0	\N	\N
\.


--
-- Data for Name: items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.items (id, name, category, default_unit, last_purchase_rate, last_sale_rate, active, created_by, created_at, manual_stock_value, fabric_group, composition, item_type) FROM stdin;
681b4a6b-f63f-4eb6-8557-1a8b23878829	EVA Bag	polybags	PCS	\N	\N	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
ca075ed1-3d8d-4a42-b685-2dcfd1533751	HD Polybag	polybags	PCS	\N	\N	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
edcd1631-dd8f-4a56-8356-3487a4293950	BOPP	polybags	PCS	\N	\N	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
bc16062b-8939-428a-8872-7a6d4313be26	PP	polybags	PCS	\N	\N	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
9307a034-5509-4f0c-9674-d948f7cd7ece	Fabric	fabric	KG	\N	3000	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
4237b09a-1618-403a-9c21-18976904a79d	Block	polybags	PCS	4690	\N	t	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-11 18:47:32.639362+00	\N	\N	\N	product
7f06a687-636e-4f8a-b4be-8fb4d4090352	LLD Polybag	polybags	PCS	665	\N	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
\.


--
-- Data for Name: journal_voucher_lines; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.journal_voucher_lines (id, voucher_id, account_id, party_id, debit, credit, line_narration) FROM stdin;
\.


--
-- Data for Name: journal_vouchers; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.journal_vouchers (id, voucher_no, voucher_date, narration, total_amount, status, voided_at, voided_by, void_reason, created_by, created_at) FROM stdin;
\.


--
-- Data for Name: ledger_entries; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ledger_entries (id, entry_date, account_id, party_id, debit, credit, reference_type, reference_id, created_at, narration, doc_no) FROM stdin;
a801a6ad-3a22-429d-9307-b1848910dc74	2026-08-11	46ff676e-30cb-49e1-901b-f714a0c05ed1	c372887f-baa3-4443-93ad-b44058cac5fc	100000	0	payment	b5221cec-d1fb-4c63-ad36-144402fa9134	2026-08-11 15:32:01.706907+00	\N	\N
7af15590-7981-497b-a910-652091f58f60	2026-08-11	14439af5-cb8b-40c8-a17d-5b7f88a6208d	c372887f-baa3-4443-93ad-b44058cac5fc	0	100000	payment	b5221cec-d1fb-4c63-ad36-144402fa9134	2026-08-11 15:32:01.706907+00	\N	\N
f01053c4-c5f1-4d1e-b76a-2c4b80dc34cd	2026-08-11	503a26fb-fd31-421f-a58f-318c73a7ceec	eb57e29e-f2a3-4310-ae6c-cae53438df4a	3000	0	invoice	d3ba4e2f-e852-488a-9510-38ea823e76d5	2026-08-11 15:37:12.577229+00	\N	\N
9596826f-c7e0-4c6c-a8ff-c0b7e389f7bc	2026-08-11	6005ba1e-cd53-4805-9502-6a48a899f6eb	eb57e29e-f2a3-4310-ae6c-cae53438df4a	0	3000	invoice	d3ba4e2f-e852-488a-9510-38ea823e76d5	2026-08-11 15:37:12.577229+00	\N	\N
8ce1c90b-d7df-47dc-8dfb-f022b6733b8b	2026-08-11	4d83866f-efb8-43d0-954a-b424f2711003	3df7c6fc-b219-4436-99c4-4caba186a5ae	1070401.60	0	invoice	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00	\N	PI-01
d3be719c-412b-42e3-b244-ead1620dd0b1	2026-08-11	4ebee95b-f8ec-43c6-be50-5879ecf064e3	3df7c6fc-b219-4436-99c4-4caba186a5ae	0	1070401.60	invoice	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00	\N	PI-01
70366687-b536-402e-b57e-6b83484ba742	2026-08-11	4ebee95b-f8ec-43c6-be50-5879ecf064e3	3df7c6fc-b219-4436-99c4-4caba186a5ae	0	5498859	opening_balance	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-11 18:14:47.836905+00	Opening balance	\N
072f4903-294f-4355-b198-542eb047c4d0	2026-08-11	4d83866f-efb8-43d0-954a-b424f2711003	3df7c6fc-b219-4436-99c4-4caba186a5ae	5498859	0	opening_balance	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-11 18:14:47.836905+00	Opening balance	\N
58badd68-5062-4f5d-972b-e177ebd8f010	2026-08-11	4d83866f-efb8-43d0-954a-b424f2711003	3df7c6fc-b219-4436-99c4-4caba186a5ae	1330559.00	0	invoice	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00	\N	PI-02
db40bc86-53a5-4f50-a8ef-7a1a0dc284c6	2026-08-11	4ebee95b-f8ec-43c6-be50-5879ecf064e3	3df7c6fc-b219-4436-99c4-4caba186a5ae	0	1330559.00	invoice	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00	\N	PI-02
\.


--
-- Data for Name: page_permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.page_permissions (id, user_id, page_key, can_view, can_create, can_edit, can_approve, granted_by, updated_at) FROM stdin;
\.


--
-- Data for Name: parties; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.parties (id, name, type, category, contact, address, ledger_account_id, opening_balance, created_by, created_at, email, ntn, stn) FROM stdin;
1e94c0a2-518f-4c6d-9543-9561ab99f672	FARAZ SPORTS	customer	{polybags}	\N	\N	1254f6b8-dc0c-4150-a27a-2f40d24622a5	0	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-06 19:01:01.515349+00	\N	\N	\N
eb57e29e-f2a3-4310-ae6c-cae53438df4a	CASH SALE	customer	{}	\N	\N	503a26fb-fd31-421f-a58f-318c73a7ceec	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
c372887f-baa3-4443-93ad-b44058cac5fc	FARAZ HOSIERY	customer	{}	\N	\N	14439af5-cb8b-40c8-a17d-5b7f88a6208d	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
1cbc3bf5-99fb-4e0f-98a6-7ab4ba1a85ac	AWAMI DYEING	customer	{}	\N	\N	21c01cc6-ee96-4dcd-83c2-64871c947d95	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
6622aa8e-84f7-49e6-a885-370bf0f71839	GONDAL DYEING	customer	{}	\N	\N	a0a21a09-6446-4de1-adfe-3a8ff21ed57b	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
67ef9cf6-0e5a-464e-adb3-0badb476a7f0	BHUTTA DYEING	customer	{}	\N	\N	15d11f17-44ee-4a3b-9ace-7fd690a91023	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
8ab0c533-557a-4eb2-ad83-66cbb309582d	MUNAWAR INDUSTRIES	customer	{}	\N	\N	85f9697c-6bc7-466e-bc6e-bd62edab7b56	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
cb109f23-d502-485d-992a-a41ed5da24b9	BLUE HORIZON	customer	{}	\N	\N	e0069fdb-38ed-4475-b4e7-a51af40322ee	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
ff67951f-a22a-4487-ad34-fae532eb358d	NEKA PAK	customer	{}	\N	\N	460aa95d-1519-4435-b641-3e76f6e0016e	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
c2cc1639-152c-4734-a8fa-65db6f4dc73e	RS PLASTIC	customer	{}	\N	\N	ab016eb2-4a52-4636-a48e-e10dfa2c67a9	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
7eb5eb63-c1d3-4ed9-bf13-696b45397a3a	UMER PLASTIC	supplier	{}	\N	\N	9682f10e-5b8d-46d2-99d0-98d8010a7f8d	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
03daca9a-96c4-43e4-ab37-ef06b3af3c9b	FARAZ SPORTS	supplier	{}	\N	\N	2739f933-b52f-43fd-8091-7f4583376cbd	0	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
3df7c6fc-b219-4436-99c4-4caba186a5ae	ZAK ENTERPRISES	supplier	{}	\N	\N	4ebee95b-f8ec-43c6-be50-5879ecf064e3	-5498859	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payments (id, payment_date, party_id, direction, amount, method, cash_bank_account_id, linked_invoice_id, notes, status, voided_at, voided_by, created_by, created_at, voucher_no, void_reason) FROM stdin;
b5221cec-d1fb-4c63-ad36-144402fa9134	2026-08-11	c372887f-baa3-4443-93ad-b44058cac5fc	receipt	100000	cash	46ff676e-30cb-49e1-901b-f714a0c05ed1	\N	Cash Rec	posted	\N	\N	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-11 15:32:01.706907+00	CRV-01	\N
\.


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.profiles (id, username, full_name, is_admin, active, created_at, last_login) FROM stdin;
3b485a4c-5dcb-4a33-885c-7a9f62427783	admin	Admin	t	t	2026-08-02 21:45:25.915937+00	\N
9bf3e37d-563c-4521-b422-213316589ff2	saad	Saad Islam Butt	t	t	2026-08-02 21:45:25.915937+00	\N
ce3edee6-abf3-4b6a-ad56-e0949e727b0a	hammad	Hammad Islam Butt	t	t	2026-08-02 21:45:25.915937+00	\N
e7399901-e484-46a3-95dc-60bc308f5426	faraz	Faraz Islam Butt	t	t	2026-08-02 21:45:25.915937+00	\N
\.


--
-- Data for Name: stock_movements; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stock_movements (id, item_id, movement_date, quantity_in, quantity_out, unit, reference_type, reference_id, created_at) FROM stdin;
8e684320-6f03-4908-b060-819afdd5e806	9307a034-5509-4f0c-9674-d948f7cd7ece	2026-08-11	0	1	PCS	sale_bill	d3ba4e2f-e852-488a-9510-38ea823e76d5	2026-08-11 15:37:12.577229+00
10ea7b2b-f3d4-46f4-bcb4-99e2a106274f	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	13.25	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
ff3b7122-e76f-47a3-8be4-a37b54394f02	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	134.6	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
0770f349-4d3d-415f-8da9-d0ed1628e1a8	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	265.49	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
af8dd288-529b-4fe5-aaec-85b6dcb401c7	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	29.2	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
48eef9aa-7e02-4e88-b55d-8c87952085a1	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	129.5	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
50329a5c-264f-4d63-a4e8-ec216cfffb7f	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	254	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
398e406e-5307-4bac-be19-67267478458b	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	355.7	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
bdeb1726-6391-4cdb-adbe-9f65b51c0c44	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	31.4	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
d3808999-c1d7-4bf2-b069-3ba64c3e6b41	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	404.35	0	KG	purchase_bill	aaa664ee-8b34-4f37-8258-82bfb30a640d	2026-08-11 18:01:20.5374+00
865643f4-1b08-461c-925a-07b87922cec5	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	305.5	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
e2e37451-53ff-448f-b9d9-f0d3a482fbc8	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	81.15	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
b7b12556-44e0-434a-8dad-2495567bf2ad	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	25	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
a9afd0dc-2e29-43da-a04f-42b9583b466f	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	406.17	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
33d7bf26-4fa6-4064-858c-1d25909d10e6	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	174.75	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
4cc14950-a2bb-459e-95b2-b5ea3c4e3ade	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	50.5	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
f1b6b255-f166-4fce-82cb-2b1ba312022d	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	28.5	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
2434a32e-8067-442c-bd2e-21cd639eca9d	4237b09a-1618-403a-9c21-18976904a79d	2026-08-11	1	0	PCS	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
8e347e18-6c4e-4ce3-9af8-bda0292032c1	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	253.15	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
293afac2-fcc7-4193-a920-39d660fce0d7	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	88.35	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
9ae03250-622c-4aed-b6a3-d03b2e2ac057	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	30.5	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
36d49bf6-5097-40bc-a825-d3ef79eb729e	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	50	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
2bab5a0e-69bd-47cd-8cd1-800eec078e72	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	403.93	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
3b5e1e49-cde8-4d0b-92cc-4e66acc302e2	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-11	62.9	0	KG	purchase_bill	ca9f6dd0-d4e0-4d7a-b713-a21354f94a13	2026-08-11 18:51:26.207523+00
\.


--
-- Name: bpv_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.bpv_seq', 1, false);


--
-- Name: brv_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.brv_seq', 1, false);


--
-- Name: cpv_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.cpv_seq', 1, false);


--
-- Name: crv_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.crv_seq', 1, true);


--
-- Name: jv_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.jv_seq', 1, false);


--
-- Name: purchase_invoice_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.purchase_invoice_seq', 2, true);


--
-- Name: purchase_order_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.purchase_order_seq', 1, false);


--
-- Name: purchase_return_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.purchase_return_seq', 1, false);


--
-- Name: sale_invoice_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.sale_invoice_seq', 1, true);


--
-- Name: sale_order_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.sale_order_seq', 1, false);


--
-- Name: sale_return_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.sale_return_seq', 1, false);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (id);


--
-- Name: brand_settings brand_settings_brand_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brand_settings
    ADD CONSTRAINT brand_settings_brand_key_key UNIQUE (brand_key);


--
-- Name: brand_settings brand_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brand_settings
    ADD CONSTRAINT brand_settings_pkey PRIMARY KEY (id);


--
-- Name: chart_of_accounts chart_of_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_pkey PRIMARY KEY (id);


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);


--
-- Name: heartbeat heartbeat_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat
    ADD CONSTRAINT heartbeat_pkey PRIMARY KEY (id);


--
-- Name: invoice_items invoice_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_invoice_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_invoice_no_key UNIQUE (invoice_no);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: items items_name_category_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_name_category_key UNIQUE (name, category);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (id);


--
-- Name: journal_voucher_lines journal_voucher_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_voucher_lines
    ADD CONSTRAINT journal_voucher_lines_pkey PRIMARY KEY (id);


--
-- Name: journal_vouchers journal_vouchers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_vouchers
    ADD CONSTRAINT journal_vouchers_pkey PRIMARY KEY (id);


--
-- Name: journal_vouchers journal_vouchers_voucher_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_vouchers
    ADD CONSTRAINT journal_vouchers_voucher_no_key UNIQUE (voucher_no);


--
-- Name: ledger_entries ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (id);


--
-- Name: page_permissions page_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_permissions
    ADD CONSTRAINT page_permissions_pkey PRIMARY KEY (id);


--
-- Name: page_permissions page_permissions_user_id_page_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_permissions
    ADD CONSTRAINT page_permissions_user_id_page_key_key UNIQUE (user_id, page_key);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: payments payments_voucher_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_voucher_no_key UNIQUE (voucher_no);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_username_key UNIQUE (username);


--
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);


--
-- Name: invoice_items_invoice_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_items_invoice_id_idx ON public.invoice_items USING btree (invoice_id);


--
-- Name: invoice_items_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_items_item_id_idx ON public.invoice_items USING btree (item_id);


--
-- Name: invoices_invoice_type_invoice_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoices_invoice_type_invoice_date_idx ON public.invoices USING btree (invoice_type, invoice_date);


--
-- Name: invoices_linked_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoices_linked_order_id_idx ON public.invoices USING btree (linked_order_id);


--
-- Name: invoices_party_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoices_party_id_idx ON public.invoices USING btree (party_id);


--
-- Name: items_category_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX items_category_active_idx ON public.items USING btree (category, active);


--
-- Name: journal_voucher_lines_voucher_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_voucher_lines_voucher_id_idx ON public.journal_voucher_lines USING btree (voucher_id);


--
-- Name: ledger_entries_account_id_entry_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ledger_entries_account_id_entry_date_idx ON public.ledger_entries USING btree (account_id, entry_date);


--
-- Name: ledger_entries_party_id_entry_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ledger_entries_party_id_entry_date_idx ON public.ledger_entries USING btree (party_id, entry_date);


--
-- Name: stock_movements_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stock_movements_item_id_idx ON public.stock_movements USING btree (item_id);


--
-- Name: stock_movements_reference_type_reference_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stock_movements_reference_type_reference_id_idx ON public.stock_movements USING btree (reference_type, reference_id);


--
-- Name: chart_of_accounts chart_of_accounts_parent_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chart_of_accounts
    ADD CONSTRAINT chart_of_accounts_parent_account_id_fkey FOREIGN KEY (parent_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: expenses expenses_brand_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES public.brand_settings(brand_key);


--
-- Name: expenses expenses_cash_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_cash_bank_account_id_fkey FOREIGN KEY (cash_bank_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: expenses expenses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: expenses expenses_expense_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_expense_account_id_fkey FOREIGN KEY (expense_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: expenses expenses_voided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_voided_by_fkey FOREIGN KEY (voided_by) REFERENCES public.profiles(id);


--
-- Name: invoice_items invoice_items_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: invoice_items invoice_items_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id);


--
-- Name: invoices invoices_brand_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES public.brand_settings(brand_key);


--
-- Name: invoices invoices_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: invoices invoices_linked_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_linked_order_id_fkey FOREIGN KEY (linked_order_id) REFERENCES public.invoices(id);


--
-- Name: invoices invoices_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: invoices invoices_voided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_voided_by_fkey FOREIGN KEY (voided_by) REFERENCES public.profiles(id);


--
-- Name: items items_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: journal_voucher_lines journal_voucher_lines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_voucher_lines
    ADD CONSTRAINT journal_voucher_lines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: journal_voucher_lines journal_voucher_lines_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_voucher_lines
    ADD CONSTRAINT journal_voucher_lines_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: journal_voucher_lines journal_voucher_lines_voucher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_voucher_lines
    ADD CONSTRAINT journal_voucher_lines_voucher_id_fkey FOREIGN KEY (voucher_id) REFERENCES public.journal_vouchers(id) ON DELETE CASCADE;


--
-- Name: journal_vouchers journal_vouchers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_vouchers
    ADD CONSTRAINT journal_vouchers_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: journal_vouchers journal_vouchers_voided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_vouchers
    ADD CONSTRAINT journal_vouchers_voided_by_fkey FOREIGN KEY (voided_by) REFERENCES public.profiles(id);


--
-- Name: ledger_entries ledger_entries_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: ledger_entries ledger_entries_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: page_permissions page_permissions_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_permissions
    ADD CONSTRAINT page_permissions_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES public.profiles(id);


--
-- Name: page_permissions page_permissions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.page_permissions
    ADD CONSTRAINT page_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: parties parties_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: parties parties_ledger_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_ledger_account_id_fkey FOREIGN KEY (ledger_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: payments payments_cash_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_cash_bank_account_id_fkey FOREIGN KEY (cash_bank_account_id) REFERENCES public.chart_of_accounts(id);


--
-- Name: payments payments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: payments payments_linked_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_linked_invoice_id_fkey FOREIGN KEY (linked_invoice_id) REFERENCES public.invoices(id);


--
-- Name: payments payments_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: payments payments_voided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_voided_by_fkey FOREIGN KEY (voided_by) REFERENCES public.profiles(id);


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: stock_movements stock_movements_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id);


--
-- Name: profiles admin can manage profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin can manage profiles" ON public.profiles USING (public.has_permission('settings'::text, 'view'::text));


--
-- Name: app_settings admin manages app settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manages app settings" ON public.app_settings USING (COALESCE(( SELECT profiles.is_admin
   FROM public.profiles
  WHERE (profiles.id = auth.uid())), false));


--
-- Name: brand_settings admin manages brand settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manages brand settings" ON public.brand_settings USING (COALESCE(( SELECT profiles.is_admin
   FROM public.profiles
  WHERE (profiles.id = auth.uid())), false));


--
-- Name: chart_of_accounts admin manages chart of accounts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manages chart of accounts" ON public.chart_of_accounts USING (COALESCE(( SELECT profiles.is_admin
   FROM public.profiles
  WHERE (profiles.id = auth.uid())), false));


--
-- Name: items admin manages items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manages items" ON public.items USING (COALESCE(( SELECT profiles.is_admin
   FROM public.profiles
  WHERE (profiles.id = auth.uid())), false));


--
-- Name: page_permissions admin manages permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manages permissions" ON public.page_permissions USING (COALESCE(( SELECT profiles.is_admin
   FROM public.profiles
  WHERE (profiles.id = auth.uid())), false));


--
-- Name: app_settings app settings readable by dashboard view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "app settings readable by dashboard view" ON public.app_settings FOR SELECT USING (public.has_permission('dashboard'::text, 'view'::text));


--
-- Name: app_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: brand_settings brand settings readable by all authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "brand settings readable by all authenticated" ON public.brand_settings FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: brand_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brand_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: chart_of_accounts chart of accounts readable by all authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "chart of accounts readable by all authenticated" ON public.chart_of_accounts FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: chart_of_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: expenses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;

--
-- Name: expenses expenses viewable with entry_expense or reports view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "expenses viewable with entry_expense or reports view" ON public.expenses FOR SELECT USING ((public.has_permission('entry_expense'::text, 'view'::text) OR public.has_permission('reports'::text, 'view'::text)));


--
-- Name: heartbeat; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.heartbeat ENABLE ROW LEVEL SECURITY;

--
-- Name: heartbeat heartbeat readable by service; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "heartbeat readable by service" ON public.heartbeat FOR SELECT USING (true);


--
-- Name: heartbeat heartbeat writable by service; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "heartbeat writable by service" ON public.heartbeat FOR UPDATE USING (true);


--
-- Name: invoice_items invoice items follow parent invoice visibility; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "invoice items follow parent invoice visibility" ON public.invoice_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.invoices i
  WHERE ((i.id = invoice_items.invoice_id) AND (((i.invoice_type = 'sale'::text) AND public.has_permission('entry_sale'::text, 'view'::text)) OR ((i.invoice_type = 'purchase'::text) AND public.has_permission('entry_purchase'::text, 'view'::text)) OR public.has_permission('reports'::text, 'view'::text) OR public.has_permission('dashboard'::text, 'view'::text))))));


--
-- Name: invoice_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;

--
-- Name: invoices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

--
-- Name: items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;

--
-- Name: items items readable by all authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "items readable by all authenticated" ON public.items FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: journal_voucher_lines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.journal_voucher_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_vouchers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.journal_vouchers ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_voucher_lines jv lines viewable with entry_jv view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "jv lines viewable with entry_jv view" ON public.journal_voucher_lines FOR SELECT USING (public.has_permission('entry_jv'::text, 'view'::text));


--
-- Name: journal_vouchers jv viewable with entry_jv view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "jv viewable with entry_jv view" ON public.journal_vouchers FOR SELECT USING (public.has_permission('entry_jv'::text, 'view'::text));


--
-- Name: ledger_entries ledger viewable with reports or dashboard view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "ledger viewable with reports or dashboard view" ON public.ledger_entries FOR SELECT USING ((public.has_permission('reports'::text, 'view'::text) OR public.has_permission('dashboard'::text, 'view'::text) OR public.has_permission('party_master'::text, 'view'::text)));


--
-- Name: ledger_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: page_permissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.page_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: parties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;

--
-- Name: parties parties readable by all authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "parties readable by all authenticated" ON public.parties FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

--
-- Name: payments payments viewable with entry_voucher view or reports; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "payments viewable with entry_voucher view or reports" ON public.payments FOR SELECT USING ((public.has_permission('entry_voucher'::text, 'view'::text) OR public.has_permission('reports'::text, 'view'::text)));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: invoices purchase docs viewable with entry_purchase view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "purchase docs viewable with entry_purchase view" ON public.invoices FOR SELECT USING (((invoice_type = ANY (ARRAY['purchase'::text, 'purchase_order'::text, 'purchase_return'::text])) AND public.has_permission('entry_purchase'::text, 'view'::text)));


--
-- Name: invoices reports view sees all invoices; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "reports view sees all invoices" ON public.invoices FOR SELECT USING ((public.has_permission('reports'::text, 'view'::text) OR public.has_permission('dashboard'::text, 'view'::text)));


--
-- Name: invoices sale docs viewable with entry_sale view; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sale docs viewable with entry_sale view" ON public.invoices FOR SELECT USING (((invoice_type = ANY (ARRAY['sale'::text, 'sale_order'::text, 'sale_return'::text])) AND public.has_permission('entry_sale'::text, 'view'::text)));


--
-- Name: page_permissions self can read own permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "self can read own permissions" ON public.page_permissions FOR SELECT USING (((user_id = auth.uid()) OR public.has_permission('settings'::text, 'view'::text)));


--
-- Name: profiles self or admin can read profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "self or admin can read profiles" ON public.profiles FOR SELECT USING (((auth.uid() = id) OR public.has_permission('settings'::text, 'view'::text)));


--
-- Name: stock_movements stock movements readable with purchase/sale/reports/dashboard v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "stock movements readable with purchase/sale/reports/dashboard v" ON public.stock_movements FOR SELECT USING ((public.has_permission('entry_purchase'::text, 'view'::text) OR public.has_permission('entry_sale'::text, 'view'::text) OR public.has_permission('reports'::text, 'view'::text) OR public.has_permission('dashboard'::text, 'view'::text)));


--
-- Name: stock_movements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict DGzhw1gxvc7etiCYIJazdHXfYQ5cHkAyny1KzYE6EPuznKgd49smH0hYaqaOpzC

