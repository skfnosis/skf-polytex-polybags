--
-- PostgreSQL database dump
--

\restrict VmX0bpvEpbU7J4pNP2sCV66RsNgjsFjnQQrYe2c1lr3frDeAxXycRJaVLuxiHBT

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Ubuntu 17.11-1.pgdg24.04+2)

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

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if coalesce((v_line->>'debit')::numeric, 0) < 0 or coalesce((v_line->>'credit')::numeric, 0) < 0 then
      raise exception 'Journal voucher line amounts cannot be negative';
    end if;
    if coalesce((v_line->>'debit')::numeric, 0) > 0 and coalesce((v_line->>'credit')::numeric, 0) > 0 then
      raise exception 'A journal voucher line cannot have both a debit and a credit';
    end if;
  end loop;

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
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET row_security TO 'off'
    AS $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
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
-- Name: record_payment(date, uuid, text, numeric, text, uuid, uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_payment(p_payment_date date, p_party_id uuid, p_direction text, p_amount numeric, p_method text, p_cash_bank_account_id uuid, p_linked_invoice_id uuid, p_notes text, p_direct_account_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_payment_id uuid;
  v_other_account uuid;
  v_kind text;
  v_voucher_no text;
begin
  if not public.has_permission('entry_voucher', 'create') then
    raise exception 'Not permitted to record vouchers';
  end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if not exists (
    select 1 from public.chart_of_accounts where id = p_cash_bank_account_id and type = 'cash_bank'
  ) then
    raise exception 'Selected account is not a cash/bank account';
  end if;
  if (p_party_id is null) = (p_direct_account_id is null) then
    raise exception 'Provide exactly one of a party or an account to pay';
  end if;

  if p_direct_account_id is not null then
    if p_direction <> 'payment' then
      raise exception 'Only a payment (money out) can be posted directly to an account';
    end if;
    if not exists (
      select 1 from public.chart_of_accounts where id = p_direct_account_id and type in ('expense', 'drawings')
    ) then
      raise exception 'Selected account must be an expense or drawings account';
    end if;
    v_other_account := p_direct_account_id;
  else
    select ledger_account_id into v_other_account from public.parties where id = p_party_id;
  end if;

  select cash_bank_kind into v_kind from public.chart_of_accounts where id = p_cash_bank_account_id;
  v_voucher_no := public.next_voucher_no(p_direction, coalesce(v_kind, 'cash'));

  insert into public.payments (voucher_no, payment_date, party_id, direct_account_id, direction, amount, method,
                                cash_bank_account_id, linked_invoice_id, notes, created_by)
  values (v_voucher_no, p_payment_date, p_party_id, p_direct_account_id, p_direction, p_amount, p_method,
          p_cash_bank_account_id, p_linked_invoice_id, p_notes, auth.uid())
  returning id into v_payment_id;

  if p_direction = 'receipt' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, p_amount, 0, 'payment', v_payment_id, p_notes, v_voucher_no);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, v_other_account, p_party_id, 0, p_amount, 'payment', v_payment_id, p_notes, v_voucher_no);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id, narration, doc_no)
    values (p_payment_date, v_other_account, p_party_id, p_amount, 0, 'payment', v_payment_id, p_notes, v_voucher_no);
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
-- Name: update_invoice(uuid, uuid, date, jsonb, text, uuid, numeric, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_invoice(p_invoice_id uuid, p_party_id uuid, p_invoice_date date, p_items jsonb, p_supplier_invoice_no text DEFAULT NULL::text, p_linked_order_id uuid DEFAULT NULL::uuid, p_transport numeric DEFAULT 0, p_loading numeric DEFAULT 0, p_discount numeric DEFAULT 0, p_tax numeric DEFAULT 0, p_customer_po_no text DEFAULT NULL::text, p_narration text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
    reserved_for_party_id uuid,
    fulfilled_from_item_id uuid,
    color text,
    gsm text,
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
    party_id uuid,
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
    direct_account_id uuid,
    CONSTRAINT payments_direction_check CHECK ((direction = ANY (ARRAY['receipt'::text, 'payment'::text]))),
    CONSTRAINT payments_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'bank_transfer'::text, 'cheque'::text, 'other'::text]))),
    CONSTRAINT payments_party_or_direct_account_check CHECK (((party_id IS NOT NULL) <> (direct_account_id IS NOT NULL))),
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
-- Name: v_open_purchase_reservations; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_open_purchase_reservations WITH (security_invoker='true') AS
 SELECT ii.id,
    ii.invoice_id,
    ii.item_id,
    ii.quantity,
    ii.unit,
    ii.rate,
    ii.description,
    ii.reserved_for_party_id,
    i.invoice_no,
    i.invoice_date,
    it.name AS item_name,
    it.item_type
   FROM ((public.invoice_items ii
     JOIN public.invoices i ON ((i.id = ii.invoice_id)))
     LEFT JOIN public.items it ON ((it.id = ii.item_id)))
  WHERE ((ii.reserved_for_party_id IS NOT NULL) AND (i.invoice_type = 'purchase'::text) AND (i.status = 'posted'::text) AND (NOT (EXISTS ( SELECT 1
           FROM (public.invoice_items s
             JOIN public.invoices si ON ((si.id = s.invoice_id)))
          WHERE ((s.fulfilled_from_item_id = ii.id) AND (si.status = 'posted'::text))))));


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
21c01cc6-ee96-4dcd-83c2-64871c947d95	AWAMI DYEING	party	f	2026-08-06 21:18:20.995209+00	\N	\N
a0a21a09-6446-4de1-adfe-3a8ff21ed57b	GONDAL DYEING	party	f	2026-08-06 21:18:20.995209+00	\N	\N
15d11f17-44ee-4a3b-9ace-7fd690a91023	BHUTTA DYEING	party	f	2026-08-06 21:18:20.995209+00	\N	\N
85f9697c-6bc7-466e-bc6e-bd62edab7b56	MUNAWAR INDUSTRIES	party	f	2026-08-06 21:18:20.995209+00	\N	\N
e0069fdb-38ed-4475-b4e7-a51af40322ee	BLUE HORIZON	party	f	2026-08-06 21:18:20.995209+00	\N	\N
460aa95d-1519-4435-b641-3e76f6e0016e	NEKA PAK	party	f	2026-08-06 21:18:20.995209+00	\N	\N
4ebee95b-f8ec-43c6-be50-5879ecf064e3	ZAK ENTERPRISES	party	f	2026-08-06 21:18:20.995209+00	\N	\N
9682f10e-5b8d-46d2-99d0-98d8010a7f8d	UMER PLASTIC	party	f	2026-08-06 21:18:20.995209+00	\N	\N
5a6b672c-cf6a-40ed-96d6-1c683bf71b65	Owner's Drawings	drawings	t	2026-08-09 19:56:17.864476+00	\N	\N
d5cbfa4c-bc77-4560-8995-b2f8928aff38	Opening Balance Equity	capital	t	2026-08-11 16:37:27.579308+00	\N	\N
425dc932-ca69-4c03-97fa-b08750e4851a	FORTA	party	f	2026-08-17 21:32:32.707225+00	\N	\N
e6a42291-8735-4930-ac69-9669207641a0	SEDATE	party	f	2026-08-17 21:32:32.707225+00	\N	\N
f45cdab6-64d0-47e8-b800-6de1b9921c90	Loans Receivable	asset	f	2026-08-17 21:32:32.707225+00	\N	\N
f8c3d4ac-ec1f-4c5f-9007-e829c6bf7ab5	Loans Payables	liability	f	2026-08-17 21:32:32.707225+00	\N	\N
d2a9abd2-6f4b-4eeb-85e5-77eb64b3a894	IVAR	party	f	2026-08-17 21:36:50.502286+00	\N	\N
711995c7-e7c2-456b-a80b-85485676ff2d	DANISH SHAKIR	party	f	2026-08-17 21:36:50.502286+00	\N	\N
a5a3e8ce-c000-4e8a-8b0b-bec262abbe32	ZUBAIR ENTERPRISE	party	f	2026-08-17 21:36:50.502286+00	\N	\N
b2e3af17-88bf-4aa9-95ed-d58b6d8cb7f9	SKILL SPORTS	party	f	2026-08-17 21:36:50.502286+00	\N	\N
4e15577b-2ac6-486d-ab03-9a1a438a21b2	Committee Receivable	asset	f	2026-08-17 21:42:01.509215+00	\N	\N
546958e7-c3e6-415a-ba96-04534550a760	MEHMOOD KARACHI	party	f	2026-08-17 21:44:51.107649+00	\N	\N
ee3ed7a5-d2be-425c-9b0b-318c8cf646e6	RS PLASTIC	party	f	2026-08-17 21:48:22.363723+00	\N	\N
34b3947f-3d7a-4a6e-ad06-74bdfa09d55c	Zakat	drawings	f	2026-08-17 22:31:03.552244+00	\N	\N
c1279a3f-8815-4485-b393-96778ef5a521	Donation	expense	f	2026-08-17 22:31:03.552244+00	\N	\N
c601aae0-067b-436a-9008-626e12fedc44	Cash Sale	party	f	2026-08-19 18:20:12.812449+00	\N	\N
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
1	2026-08-19 03:13:48+00
\.


--
-- Data for Name: invoice_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.invoice_items (id, invoice_id, quantity, unit, rate, description, item_id, narration, reserved_for_party_id, fulfilled_from_item_id, color, gsm) FROM stdin;
bc70f6c0-5a98-4b94-a316-7973770aa3a5	aab8c3ef-5ba3-49dc-8859-05cb730c6ec7	500	KG	1000	LLD Polybag	7f06a687-636e-4f8a-b4be-8fb4d4090352	Check	\N	\N	\N	\N
8854508f-5831-42a2-8ce5-4b9732b3f0b8	68987bdb-747f-4263-b7cb-f496f4582025	250	KG	1550	Scuba Fabric	89acf469-10bd-48f9-bcd1-24497e4cf3b3	\N	\N	\N	Black	\N
52bfd468-1a3f-43dd-b002-7abe43447d21	68987bdb-747f-4263-b7cb-f496f4582025	125	KG	1550	Scuba Fabric	89acf469-10bd-48f9-bcd1-24497e4cf3b3	\N	\N	\N	Navy 193932 TPG	\N
312db585-eef0-4e28-821a-12219c95ae6d	68987bdb-747f-4263-b7cb-f496f4582025	125	KG	1550	Scuba Fabric	89acf469-10bd-48f9-bcd1-24497e4cf3b3	\N	\N	\N	Frost Grey TPG 170000	\N
202fcecd-f3ac-43ea-8905-1086eeae6f14	68987bdb-747f-4263-b7cb-f496f4582025	125	KG	1550	Scuba Fabric	89acf469-10bd-48f9-bcd1-24497e4cf3b3	\N	\N	\N	Walnut TPG 181112	\N
f513e2a9-5dd6-4719-acbe-a2851cf89910	68987bdb-747f-4263-b7cb-f496f4582025	125	KG	1550	Scuba Fabric	89acf469-10bd-48f9-bcd1-24497e4cf3b3	\N	\N	\N	Merlot TPG 191534	\N
\.


--
-- Data for Name: invoices; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.invoices (id, invoice_no, invoice_type, brand_key, category, party_id, invoice_date, total_amount, status, voided_at, voided_by, void_reason, created_by, created_at, supplier_invoice_no, linked_order_id, transport_charges, loading_charges, discount_amount, tax_amount, customer_po_no, narration) FROM stdin;
aab8c3ef-5ba3-49dc-8859-05cb730c6ec7	PI-03	purchase	skf_polybags	polybags	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-17	500000	posted	\N	\N	\N	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-17 22:22:14.92634+00	468	\N	0	0	0	0	\N	\N
68987bdb-747f-4263-b7cb-f496f4582025	SO-01	sale_order	skf_polytex	fabric	4b3d374d-0009-4eb5-bb4d-b91eedba0505	2026-08-04	1162500	posted	\N	\N	\N	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-18 21:57:52.833678+00	\N	\N	0	0	0	0	\N	\N
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
7f06a687-636e-4f8a-b4be-8fb4d4090352	LLD Polybag	polybags	PCS	1000	\N	t	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N	product
89acf469-10bd-48f9-bcd1-24497e4cf3b3	Scuba Fabric	fabric	KG	\N	\N	t	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-18 21:37:25.397985+00	\N	in_house	88-92% Polyester 8-12% Spandex 	product
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
d92a88d3-e57f-4b3f-8f59-3050cfd2c516	2026-08-15	21c01cc6-ee96-4dcd-83c2-64871c947d95	1cbc3bf5-99fb-4e0f-98a6-7ab4ba1a85ac	1630596	0	opening_balance	1cbc3bf5-99fb-4e0f-98a6-7ab4ba1a85ac	2026-08-17 21:32:32.707225+00	Opening balance	\N
c7ed4c76-6af4-4155-8c3d-ac31f02d7f0b	2026-08-15	a0a21a09-6446-4de1-adfe-3a8ff21ed57b	6622aa8e-84f7-49e6-a885-370bf0f71839	1252048	0	opening_balance	6622aa8e-84f7-49e6-a885-370bf0f71839	2026-08-17 21:32:32.707225+00	Opening balance	\N
338b27fe-0ca1-4a0b-afbc-30ee93c76f99	2026-08-15	15d11f17-44ee-4a3b-9ace-7fd690a91023	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	1375684	0	opening_balance	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	2026-08-17 21:32:32.707225+00	Opening balance	\N
ef17c0da-7b9e-4477-b63b-bd28f768bbac	2026-08-15	85f9697c-6bc7-466e-bc6e-bd62edab7b56	8ab0c533-557a-4eb2-ad83-66cbb309582d	916842	0	opening_balance	8ab0c533-557a-4eb2-ad83-66cbb309582d	2026-08-17 21:32:32.707225+00	Opening balance	\N
1d202da3-0a3f-4944-b2fe-6825e60862d1	2026-08-15	e0069fdb-38ed-4475-b4e7-a51af40322ee	cb109f23-d502-485d-992a-a41ed5da24b9	980837	0	opening_balance	cb109f23-d502-485d-992a-a41ed5da24b9	2026-08-17 21:32:32.707225+00	Opening balance	\N
ad336e67-59c9-4f7c-92ad-dc5ede498e3b	2026-08-15	460aa95d-1519-4435-b641-3e76f6e0016e	ff67951f-a22a-4487-ad34-fae532eb358d	138999	0	opening_balance	ff67951f-a22a-4487-ad34-fae532eb358d	2026-08-17 21:32:32.707225+00	Opening balance	\N
43bdc3e0-f91d-4db1-a5db-c88bd52a8ca5	2026-08-15	9682f10e-5b8d-46d2-99d0-98d8010a7f8d	7eb5eb63-c1d3-4ed9-bf13-696b45397a3a	0	810911	opening_balance	7eb5eb63-c1d3-4ed9-bf13-696b45397a3a	2026-08-17 21:32:32.707225+00	Opening balance	\N
096ac7b5-f5e7-479f-80fd-e5295eb2b389	2026-08-15	4ebee95b-f8ec-43c6-be50-5879ecf064e3	3df7c6fc-b219-4436-99c4-4caba186a5ae	0	5127640	opening_balance	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-17 21:32:32.707225+00	Opening balance	\N
0b7d2deb-8983-42a1-98b5-056ee3a04e98	2026-08-15	425dc932-ca69-4c03-97fa-b08750e4851a	0fea589d-e163-49b4-9fa6-cdc95867c38b	17900	0	opening_balance	0fea589d-e163-49b4-9fa6-cdc95867c38b	2026-08-17 21:32:32.707225+00	Opening balance	\N
5e613974-3682-4ca7-b9c1-99f5d99288c9	2026-08-15	e6a42291-8735-4930-ac69-9669207641a0	295c6b52-b21d-4a69-898b-6f0ada645c69	151749	0	opening_balance	295c6b52-b21d-4a69-898b-6f0ada645c69	2026-08-17 21:32:32.707225+00	Opening balance	\N
e7758d8f-d645-48c4-b521-62d2db78d2ae	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	1cbc3bf5-99fb-4e0f-98a6-7ab4ba1a85ac	0	1630596	opening_balance	1cbc3bf5-99fb-4e0f-98a6-7ab4ba1a85ac	2026-08-17 21:32:32.707225+00	Opening balance	\N
6d7f5661-2398-4ddb-a7c4-9d2d2772afbb	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	6622aa8e-84f7-49e6-a885-370bf0f71839	0	1252048	opening_balance	6622aa8e-84f7-49e6-a885-370bf0f71839	2026-08-17 21:32:32.707225+00	Opening balance	\N
7551ff41-ce6a-4ea2-9640-20f166d21408	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	0	1375684	opening_balance	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	2026-08-17 21:32:32.707225+00	Opening balance	\N
c4eed301-94e8-4276-a66c-f2a0ceddbe15	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	8ab0c533-557a-4eb2-ad83-66cbb309582d	0	916842	opening_balance	8ab0c533-557a-4eb2-ad83-66cbb309582d	2026-08-17 21:32:32.707225+00	Opening balance	\N
c7511b37-f555-46bf-b88e-f59df0b52489	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	cb109f23-d502-485d-992a-a41ed5da24b9	0	980837	opening_balance	cb109f23-d502-485d-992a-a41ed5da24b9	2026-08-17 21:32:32.707225+00	Opening balance	\N
3cfde82b-3417-4dc5-a4ee-5374f10e99a6	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	ff67951f-a22a-4487-ad34-fae532eb358d	0	138999	opening_balance	ff67951f-a22a-4487-ad34-fae532eb358d	2026-08-17 21:32:32.707225+00	Opening balance	\N
089d3859-c1bb-4ad2-a281-4cafe2013e10	2026-08-15	4d83866f-efb8-43d0-954a-b424f2711003	7eb5eb63-c1d3-4ed9-bf13-696b45397a3a	810911	0	opening_balance	7eb5eb63-c1d3-4ed9-bf13-696b45397a3a	2026-08-17 21:32:32.707225+00	Opening balance	\N
69ea5728-3847-4b2c-9f68-52d7cf79985b	2026-08-15	4d83866f-efb8-43d0-954a-b424f2711003	3df7c6fc-b219-4436-99c4-4caba186a5ae	5127640	0	opening_balance	3df7c6fc-b219-4436-99c4-4caba186a5ae	2026-08-17 21:32:32.707225+00	Opening balance	\N
a957ded9-7540-4cb2-8c1f-9cc4237f8142	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	0fea589d-e163-49b4-9fa6-cdc95867c38b	0	17900	opening_balance	0fea589d-e163-49b4-9fa6-cdc95867c38b	2026-08-17 21:32:32.707225+00	Opening balance	\N
42843e9d-2a42-4a92-aa3c-4afd4283b8af	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	295c6b52-b21d-4a69-898b-6f0ada645c69	0	151749	opening_balance	295c6b52-b21d-4a69-898b-6f0ada645c69	2026-08-17 21:32:32.707225+00	Opening balance	\N
a5a99208-ce24-45e0-b607-2698a40e2a70	2026-08-15	f45cdab6-64d0-47e8-b800-6de1b9921c90	\N	600000	0	opening_balance	f45cdab6-64d0-47e8-b800-6de1b9921c90	2026-08-17 21:32:32.707225+00	Opening balance	\N
d51da710-8495-4fdc-ad9c-b275426f7714	2026-08-15	d5cbfa4c-bc77-4560-8995-b2f8928aff38	\N	0	600000	opening_balance	f45cdab6-64d0-47e8-b800-6de1b9921c90	2026-08-17 21:32:32.707225+00	Opening balance — Loans Receivable	\N
9e675e69-3ade-4edb-aaa7-68dc17806215	2026-08-15	f8c3d4ac-ec1f-4c5f-9007-e829c6bf7ab5	\N	0	400000	opening_balance	f8c3d4ac-ec1f-4c5f-9007-e829c6bf7ab5	2026-08-17 21:32:32.707225+00	Opening balance	\N
f26468fd-66b0-4496-8941-ce81fd7ce0b8	2026-08-15	d5cbfa4c-bc77-4560-8995-b2f8928aff38	\N	400000	0	opening_balance	f8c3d4ac-ec1f-4c5f-9007-e829c6bf7ab5	2026-08-17 21:32:32.707225+00	Opening balance — Loans Payables	\N
550fcd97-cb48-4cc5-b95e-54b65db02901	2026-08-15	46ff676e-30cb-49e1-901b-f714a0c05ed1	\N	100000	0	opening_balance	46ff676e-30cb-49e1-901b-f714a0c05ed1	2026-08-17 21:32:32.707225+00	Opening balance	\N
f705e035-c4bd-4966-93a8-17914f2ceaf5	2026-08-15	d5cbfa4c-bc77-4560-8995-b2f8928aff38	\N	0	100000	opening_balance	46ff676e-30cb-49e1-901b-f714a0c05ed1	2026-08-17 21:32:32.707225+00	Opening balance — Cash in Hand	\N
bbf0cd6e-d56c-4ea9-be3c-23c53adeda79	2026-08-15	d2a9abd2-6f4b-4eeb-85e5-77eb64b3a894	4b3d374d-0009-4eb5-bb4d-b91eedba0505	0	581250	opening_balance	4b3d374d-0009-4eb5-bb4d-b91eedba0505	2026-08-17 21:36:50.502286+00	Advance — Opening balance	\N
411fca87-50ba-4e58-b912-320c9736dec8	2026-08-15	711995c7-e7c2-456b-a80b-85485676ff2d	1a2ad29f-f058-453a-bf99-e9e1d1dbdc7f	0	275000	opening_balance	1a2ad29f-f058-453a-bf99-e9e1d1dbdc7f	2026-08-17 21:36:50.502286+00	Advance — Opening balance	\N
b080e9b3-3473-4dba-998c-d2aa9aa8fa2a	2026-08-15	a5a3e8ce-c000-4e8a-8b0b-bec262abbe32	7c8ce4e5-42ba-4465-83ef-fa4a208fb5a8	712824	0	opening_balance	7c8ce4e5-42ba-4465-83ef-fa4a208fb5a8	2026-08-17 21:36:50.502286+00	Opening balance	\N
52654000-4ebf-4c82-84d5-38d6facde3bc	2026-08-15	b2e3af17-88bf-4aa9-95ed-d58b6d8cb7f9	6765a6ef-fc2b-4543-a143-4795901bb6ee	61000	0	opening_balance	6765a6ef-fc2b-4543-a143-4795901bb6ee	2026-08-17 21:36:50.502286+00	Opening balance	\N
c90d1d4f-364c-4f75-9985-0d38a6052d7f	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	7c8ce4e5-42ba-4465-83ef-fa4a208fb5a8	0	712824	opening_balance	7c8ce4e5-42ba-4465-83ef-fa4a208fb5a8	2026-08-17 21:36:50.502286+00	Opening balance	\N
b21a2ee6-e584-4e52-b98b-4812df1598c9	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	6765a6ef-fc2b-4543-a143-4795901bb6ee	0	61000	opening_balance	6765a6ef-fc2b-4543-a143-4795901bb6ee	2026-08-17 21:36:50.502286+00	Opening balance	\N
2a71f524-3b20-465a-8fe3-251b41d175ce	2026-08-15	4e15577b-2ac6-486d-ab03-9a1a438a21b2	\N	290000	0	opening_balance	4e15577b-2ac6-486d-ab03-9a1a438a21b2	2026-08-17 21:42:01.509215+00	Opening balance	\N
8c18f3ae-fe97-46c5-83b2-d807248c4333	2026-08-15	d5cbfa4c-bc77-4560-8995-b2f8928aff38	\N	0	290000	opening_balance	4e15577b-2ac6-486d-ab03-9a1a438a21b2	2026-08-17 21:42:01.509215+00	Opening balance — Committee Receivable	\N
c5822c80-0707-4995-8897-03b944f22aab	2026-08-15	546958e7-c3e6-415a-ba96-04534550a760	4118c128-41c0-40fa-9c46-35fbc42d230f	514968	0	opening_balance	4118c128-41c0-40fa-9c46-35fbc42d230f	2026-08-17 21:44:51.107649+00	Opening balance	\N
6eaf8cc5-5f0e-49a2-982d-063d048fd2bf	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	4118c128-41c0-40fa-9c46-35fbc42d230f	0	514968	opening_balance	4118c128-41c0-40fa-9c46-35fbc42d230f	2026-08-17 21:44:51.107649+00	Opening balance	\N
c781a7e3-a375-47f2-b60d-b5e437823cb0	2026-08-15	ee3ed7a5-d2be-425c-9b0b-318c8cf646e6	635db2c3-1801-44a6-822a-cf1dbc116223	2762574	0	opening_balance	635db2c3-1801-44a6-822a-cf1dbc116223	2026-08-17 21:48:22.363723+00	Opening balance	\N
677be3b0-7b9e-496d-813a-d463a6582e90	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	635db2c3-1801-44a6-822a-cf1dbc116223	0	2762574	opening_balance	635db2c3-1801-44a6-822a-cf1dbc116223	2026-08-17 21:48:22.363723+00	Opening balance	\N
b2276662-8f1f-4ea4-8d57-27a4aca24491	2026-08-17	4d83866f-efb8-43d0-954a-b424f2711003	3df7c6fc-b219-4436-99c4-4caba186a5ae	500000	0	invoice	aab8c3ef-5ba3-49dc-8859-05cb730c6ec7	2026-08-17 22:22:14.92634+00	Check	PI-03
6031b0ab-232f-4ad3-a629-4e83133e7511	2026-08-17	4ebee95b-f8ec-43c6-be50-5879ecf064e3	3df7c6fc-b219-4436-99c4-4caba186a5ae	0	500000	invoice	aab8c3ef-5ba3-49dc-8859-05cb730c6ec7	2026-08-17 22:22:14.92634+00	Check	PI-03
9ccaf33b-8da3-43b8-8e22-0f4db8c59759	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	4b3d374d-0009-4eb5-bb4d-b91eedba0505	581250	0	opening_balance	4b3d374d-0009-4eb5-bb4d-b91eedba0505	2026-08-17 21:36:50.502286+00	Advance — Opening balance	\N
e486c136-6a4e-40d2-aad5-21dde1f76ea0	2026-08-15	6005ba1e-cd53-4805-9502-6a48a899f6eb	1a2ad29f-f058-453a-bf99-e9e1d1dbdc7f	275000	0	opening_balance	1a2ad29f-f058-453a-bf99-e9e1d1dbdc7f	2026-08-17 21:36:50.502286+00	Advance — Opening balance	\N
ce599981-547d-481a-ae65-27387e486361	2026-08-19	46ff676e-30cb-49e1-901b-f714a0c05ed1	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	4000	0	payment	0606e531-b3a8-42ea-9dd8-b1095f273dc3	2026-08-19 18:20:49.793524+00	Evabag advance 	CRV-02
319ea285-80ce-4e2e-9590-5d6f2c735f57	2026-08-19	c601aae0-067b-436a-9008-626e12fedc44	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	0	4000	payment	0606e531-b3a8-42ea-9dd8-b1095f273dc3	2026-08-19 18:20:49.793524+00	Evabag advance 	CRV-02
a2364620-aa02-4213-8d5b-62b8ca6e1819	2026-07-21	46ff676e-30cb-49e1-901b-f714a0c05ed1	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	552271	0	payment	c02312df-b225-484e-9aff-c7847cb02e56	2026-08-19 19:17:40.390395+00	Chq rec	CRV-03
ac798d18-d1c9-4a22-9baa-65046a7f2650	2026-07-21	15d11f17-44ee-4a3b-9ace-7fd690a91023	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	0	552271	payment	c02312df-b225-484e-9aff-c7847cb02e56	2026-08-19 19:17:40.390395+00	Chq rec	CRV-03
0fe0faa2-d511-4a54-931a-bcf80d08c7c7	2026-08-19	46ff676e-30cb-49e1-901b-f714a0c05ed1	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	0	552271	void	c02312df-b225-484e-9aff-c7847cb02e56	2026-08-19 19:22:21.292949+00	Void — Delete	CRV-03
ba4672fa-5102-410d-be31-0d3f2d3b7631	2026-08-19	15d11f17-44ee-4a3b-9ace-7fd690a91023	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	552271	0	void	c02312df-b225-484e-9aff-c7847cb02e56	2026-08-19 19:22:21.292949+00	Void — Delete	CRV-03
a64ed034-b258-4e2c-a04b-49910fb41937	2026-08-20	46ff676e-30cb-49e1-901b-f714a0c05ed1	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	12250	0	payment	6cf08db6-0e54-4614-b7ba-4bcd96818ee6	2026-08-20 11:43:57.640587+00	Eva bag	CRV-04
cdaeb243-b988-43b1-af95-a99a899f2220	2026-08-20	c601aae0-067b-436a-9008-626e12fedc44	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	0	12250	payment	6cf08db6-0e54-4614-b7ba-4bcd96818ee6	2026-08-20 11:43:57.640587+00	Eva bag	CRV-04
2dcde557-c6c7-4ce2-a969-8c4753fd6194	2026-08-20	46ff676e-30cb-49e1-901b-f714a0c05ed1	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	12250	0	payment	a6557338-3bd7-449f-a27d-04ab055dd09e	2026-08-20 11:43:58.623234+00	Eva bag	CRV-05
5f1d2b77-2cfd-4820-8acd-e394b42c341a	2026-08-20	c601aae0-067b-436a-9008-626e12fedc44	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	0	12250	payment	a6557338-3bd7-449f-a27d-04ab055dd09e	2026-08-20 11:43:58.623234+00	Eva bag	CRV-05
c2c68a07-1017-404b-ba92-b37828bbd75e	2026-08-20	46ff676e-30cb-49e1-901b-f714a0c05ed1	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	0	12250	void	a6557338-3bd7-449f-a27d-04ab055dd09e	2026-08-20 11:44:26.729523+00	Void — Delete	CRV-05
27b46b90-6fc4-4075-9fc8-b81bb455b71b	2026-08-20	c601aae0-067b-436a-9008-626e12fedc44	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	12250	0	void	a6557338-3bd7-449f-a27d-04ab055dd09e	2026-08-20 11:44:26.729523+00	Void — Delete	CRV-05
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
1cbc3bf5-99fb-4e0f-98a6-7ab4ba1a85ac	AWAMI DYEING	customer	{}	\N	\N	21c01cc6-ee96-4dcd-83c2-64871c947d95	1630596	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
6622aa8e-84f7-49e6-a885-370bf0f71839	GONDAL DYEING	customer	{}	\N	\N	a0a21a09-6446-4de1-adfe-3a8ff21ed57b	1252048	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
67ef9cf6-0e5a-464e-adb3-0badb476a7f0	BHUTTA DYEING	customer	{}	\N	\N	15d11f17-44ee-4a3b-9ace-7fd690a91023	1375684	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
8ab0c533-557a-4eb2-ad83-66cbb309582d	MUNAWAR INDUSTRIES	customer	{}	\N	\N	85f9697c-6bc7-466e-bc6e-bd62edab7b56	916842	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
cb109f23-d502-485d-992a-a41ed5da24b9	BLUE HORIZON	customer	{}	\N	\N	e0069fdb-38ed-4475-b4e7-a51af40322ee	980837	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
ff67951f-a22a-4487-ad34-fae532eb358d	NEKA PAK	customer	{}	\N	\N	460aa95d-1519-4435-b641-3e76f6e0016e	138999	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
7eb5eb63-c1d3-4ed9-bf13-696b45397a3a	UMER PLASTIC	supplier	{}	\N	\N	9682f10e-5b8d-46d2-99d0-98d8010a7f8d	-810911	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
3df7c6fc-b219-4436-99c4-4caba186a5ae	ZAK ENTERPRISES	supplier	{}	\N	\N	4ebee95b-f8ec-43c6-be50-5879ecf064e3	-5127640	\N	2026-08-06 21:18:20.995209+00	\N	\N	\N
0fea589d-e163-49b4-9fa6-cdc95867c38b	FORTA	customer	{}	\N	\N	425dc932-ca69-4c03-97fa-b08750e4851a	17900	\N	2026-08-17 21:32:32.707225+00	\N	\N	\N
295c6b52-b21d-4a69-898b-6f0ada645c69	SEDATE	customer	{}	\N	\N	e6a42291-8735-4930-ac69-9669207641a0	151749	\N	2026-08-17 21:32:32.707225+00	\N	\N	\N
7c8ce4e5-42ba-4465-83ef-fa4a208fb5a8	ZUBAIR ENTERPRISE	customer	{}	\N	\N	a5a3e8ce-c000-4e8a-8b0b-bec262abbe32	712824	\N	2026-08-17 21:36:50.502286+00	\N	\N	\N
6765a6ef-fc2b-4543-a143-4795901bb6ee	SKILL SPORTS	customer	{}	\N	\N	b2e3af17-88bf-4aa9-95ed-d58b6d8cb7f9	61000	\N	2026-08-17 21:36:50.502286+00	\N	\N	\N
4118c128-41c0-40fa-9c46-35fbc42d230f	MEHMOOD KARACHI	customer	{}	\N	\N	546958e7-c3e6-415a-ba96-04534550a760	514968	\N	2026-08-17 21:44:51.107649+00	\N	\N	\N
635db2c3-1801-44a6-822a-cf1dbc116223	RS PLASTIC	customer	{}	\N	\N	ee3ed7a5-d2be-425c-9b0b-318c8cf646e6	2762574	\N	2026-08-17 21:48:22.363723+00	\N	\N	\N
4b3d374d-0009-4eb5-bb4d-b91eedba0505	IVAR	customer	{}	\N	\N	d2a9abd2-6f4b-4eeb-85e5-77eb64b3a894	-581250	\N	2026-08-17 21:36:50.502286+00	\N	\N	\N
1a2ad29f-f058-453a-bf99-e9e1d1dbdc7f	DANISH SHAKIR	customer	{}	\N	\N	711995c7-e7c2-456b-a80b-85485676ff2d	-275000	\N	2026-08-17 21:36:50.502286+00	\N	\N	\N
258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	Cash Sale	customer	{fabric,polybags}	\N	\N	c601aae0-067b-436a-9008-626e12fedc44	0	3b485a4c-5dcb-4a33-885c-7a9f62427783	2026-08-19 18:20:12.812449+00	\N	\N	\N
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payments (id, payment_date, party_id, direction, amount, method, cash_bank_account_id, linked_invoice_id, notes, status, voided_at, voided_by, created_by, created_at, voucher_no, void_reason, direct_account_id) FROM stdin;
0606e531-b3a8-42ea-9dd8-b1095f273dc3	2026-08-19	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	receipt	4000	cash	46ff676e-30cb-49e1-901b-f714a0c05ed1	\N	Evabag advance 	posted	\N	\N	e7399901-e484-46a3-95dc-60bc308f5426	2026-08-19 18:20:49.793524+00	CRV-02	\N	\N
c02312df-b225-484e-9aff-c7847cb02e56	2026-07-21	67ef9cf6-0e5a-464e-adb3-0badb476a7f0	receipt	552271	cash	46ff676e-30cb-49e1-901b-f714a0c05ed1	\N	Chq rec	voided	2026-08-19 19:22:21.292949+00	e7399901-e484-46a3-95dc-60bc308f5426	e7399901-e484-46a3-95dc-60bc308f5426	2026-08-19 19:17:40.390395+00	CRV-03	Delete	\N
6cf08db6-0e54-4614-b7ba-4bcd96818ee6	2026-08-20	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	receipt	12250	cash	46ff676e-30cb-49e1-901b-f714a0c05ed1	\N	Eva bag	posted	\N	\N	e7399901-e484-46a3-95dc-60bc308f5426	2026-08-20 11:43:57.640587+00	CRV-04	\N	\N
a6557338-3bd7-449f-a27d-04ab055dd09e	2026-08-20	258e6e99-919e-4ec0-aab5-4d8cd36fa1b7	receipt	12250	cash	46ff676e-30cb-49e1-901b-f714a0c05ed1	\N	Eva bag	voided	2026-08-20 11:44:26.729523+00	e7399901-e484-46a3-95dc-60bc308f5426	e7399901-e484-46a3-95dc-60bc308f5426	2026-08-20 11:43:58.623234+00	CRV-05	Delete	\N
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
6e35da24-728d-4645-86bc-db7d1d764fd0	7f06a687-636e-4f8a-b4be-8fb4d4090352	2026-08-17	500	0	KG	purchase_bill	aab8c3ef-5ba3-49dc-8859-05cb730c6ec7	2026-08-17 22:22:14.92634+00
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

SELECT pg_catalog.setval('public.crv_seq', 5, true);


--
-- Name: jv_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.jv_seq', 1, false);


--
-- Name: purchase_invoice_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.purchase_invoice_seq', 3, true);


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

SELECT pg_catalog.setval('public.sale_order_seq', 1, true);


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
-- Name: invoice_items_fulfilled_from_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_items_fulfilled_from_item_id_idx ON public.invoice_items USING btree (fulfilled_from_item_id);


--
-- Name: invoice_items_invoice_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_items_invoice_id_idx ON public.invoice_items USING btree (invoice_id);


--
-- Name: invoice_items_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_items_item_id_idx ON public.invoice_items USING btree (item_id);


--
-- Name: invoice_items_reserved_for_party_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_items_reserved_for_party_id_idx ON public.invoice_items USING btree (reserved_for_party_id);


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
-- Name: invoice_items invoice_items_fulfilled_from_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_fulfilled_from_item_id_fkey FOREIGN KEY (fulfilled_from_item_id) REFERENCES public.invoice_items(id);


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
-- Name: invoice_items invoice_items_reserved_for_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_reserved_for_party_id_fkey FOREIGN KEY (reserved_for_party_id) REFERENCES public.parties(id);


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
-- Name: payments payments_direct_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_direct_account_id_fkey FOREIGN KEY (direct_account_id) REFERENCES public.chart_of_accounts(id);


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

CREATE POLICY "admin can manage profiles" ON public.profiles USING (public.is_admin()) WITH CHECK (public.is_admin());


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

\unrestrict VmX0bpvEpbU7J4pNP2sCV66RsNgjsFjnQQrYe2c1lr3frDeAxXycRJaVLuxiHBT

