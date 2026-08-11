-- ============================================================================
-- PARTY OPENING BALANCE — settable after a party already exists.
-- ============================================================================
-- create_party() only ever posted an opening balance at creation time; there
-- was no way to add one to a party created earlier without one (e.g. a
-- vendor/customer entered before their historical balance was known). This
-- mirrors create_party's existing posting pattern exactly — same accounts,
-- same signs — just callable after the fact. Guarded to only fire once
-- (current opening_balance must be 0) so it can't silently double-post if
-- called twice.
--
-- Sign convention (matches create_party): positive amount = party owes us
-- (debits the party's own ledger row); negative amount = we owe the party
-- (credits it) — e.g. an unpaid balance carried forward for a supplier.
-- ============================================================================

create or replace function public.set_party_opening_balance(p_party_id uuid, p_amount numeric)
returns void language plpgsql security definer as $$
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
grant execute on function public.set_party_opening_balance(uuid, numeric) to authenticated;
alter function public.set_party_opening_balance(uuid, numeric) set search_path = public;
