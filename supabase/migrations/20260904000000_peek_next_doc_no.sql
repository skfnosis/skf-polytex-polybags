-- ============================================================================
-- Preview the invoice/voucher number a draft will get once saved, instead of
-- showing a literal "DRAFT" on the Report/Print/Save-Image preview before
-- the document exists. Reads each sequence's current position without
-- consuming it (no nextval call) — same numbers next_invoice_no/
-- next_voucher_no would hand out, just without reserving one. If another
-- save happens between preview and the real save, the previewed number can
-- be off by one; harmless since it's a preview label, not what actually
-- gets stamped on the saved document.
-- ============================================================================

create or replace function public.peek_next_doc_no(p_doc_kind text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_last bigint;
  v_called boolean;
  v_next bigint;
begin
  if p_doc_kind = 'sale' then
    select last_value, is_called into v_last, v_called from public.sale_invoice_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'SI-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'purchase' then
    select last_value, is_called into v_last, v_called from public.purchase_invoice_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'PI-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'purchase_order' then
    select last_value, is_called into v_last, v_called from public.purchase_order_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'PO-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'purchase_return' then
    select last_value, is_called into v_last, v_called from public.purchase_return_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'PR-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'sale_order' then
    select last_value, is_called into v_last, v_called from public.sale_order_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'SO-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'sale_return' then
    select last_value, is_called into v_last, v_called from public.sale_return_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'SR-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'brv' then
    select last_value, is_called into v_last, v_called from public.brv_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'BRV-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'crv' then
    select last_value, is_called into v_last, v_called from public.crv_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'CRV-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'bpv' then
    select last_value, is_called into v_last, v_called from public.bpv_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'BPV-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'cpv' then
    select last_value, is_called into v_last, v_called from public.cpv_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'CPV-' || lpad(v_next::text, 2, '0');
  elsif p_doc_kind = 'jv' then
    select last_value, is_called into v_last, v_called from public.jv_seq;
    v_next := case when v_called then v_last + 1 else v_last end;
    return 'JV-' || lpad(v_next::text, 2, '0');
  else
    raise exception 'Unknown document kind: %', p_doc_kind;
  end if;
end; $$;
grant execute on function public.peek_next_doc_no(text) to authenticated;
