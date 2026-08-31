-- ============================================================================
-- Let a Voided document be permanently deleted — a genuine hard delete, on
-- top of the existing non-destructive Void. Deliberately two-step: a
-- document must already be Voided (its ledger/stock impact already
-- reversed) before Delete is allowed. Nothing here ever deletes a live
-- posted document directly.
--
-- Same permission bar as Void (has_permission(<page>, 'approve')) for each
-- document family: invoices (Purchase/Sale Order/Bill/Return), payments
-- (CRV/BRV/CPV/BPV), journal_vouchers (JV).
--
-- Foreign keys with NO ACTION (invoices.linked_order_id, payments.
-- linked_invoice_id, invoice_items.fulfilled_from_item_id) mean Postgres
-- itself blocks a delete that would orphan a dependent Bill, payment, or
-- fulfilled reservation — caught below and turned into a plain-English
-- error instead of a raw constraint violation.
-- ============================================================================

create or replace function public.delete_invoice(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_invoice public.invoices;
  v_page text;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice is null then raise exception 'Invoice not found'; end if;
  if v_invoice.status <> 'voided' then raise exception 'Only a voided document can be deleted — void it first'; end if;

  v_page := case when v_invoice.invoice_type in ('sale', 'sale_order', 'sale_return') then 'entry_sale' else 'entry_purchase' end;
  if not public.has_permission(v_page, 'approve') then
    raise exception 'Not permitted to delete % documents', v_invoice.invoice_type;
  end if;

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
grant execute on function public.delete_invoice(uuid) to authenticated;

create or replace function public.delete_payment(p_payment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_payment public.payments;
begin
  select * into v_payment from public.payments where id = p_payment_id;
  if v_payment is null then raise exception 'Voucher not found'; end if;
  if v_payment.status <> 'voided' then raise exception 'Only a voided voucher can be deleted — void it first'; end if;
  if not public.has_permission('entry_voucher', 'approve') then
    raise exception 'Not permitted to delete vouchers';
  end if;

  delete from public.ledger_entries where reference_id = v_payment.id
    and reference_type in ('payment', 'void');

  begin
    delete from public.payments where id = p_payment_id;
  exception when foreign_key_violation then
    raise exception 'Cannot delete — another document still references this voucher';
  end;
end; $$;
grant execute on function public.delete_payment(uuid) to authenticated;

create or replace function public.delete_journal_voucher(p_voucher_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_voucher public.journal_vouchers;
begin
  select * into v_voucher from public.journal_vouchers where id = p_voucher_id;
  if v_voucher is null then raise exception 'Journal voucher not found'; end if;
  if v_voucher.status <> 'voided' then raise exception 'Only a voided journal voucher can be deleted — void it first'; end if;
  if not public.has_permission('entry_jv', 'approve') then
    raise exception 'Not permitted to delete journal vouchers';
  end if;

  delete from public.ledger_entries where reference_id = v_voucher.id
    and reference_type in ('journal_voucher', 'void');

  delete from public.journal_vouchers where id = p_voucher_id;
end; $$;
grant execute on function public.delete_journal_voucher(uuid) to authenticated;
