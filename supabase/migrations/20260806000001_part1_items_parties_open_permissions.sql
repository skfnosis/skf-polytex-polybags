-- ============================================================================
-- PART 1 — item catalog reseed, party seed data, and opening up party
-- creation to every authenticated user.
-- ============================================================================
-- DESIGN NOTES
-- - Item catalog: the brief now fixes the whole item list to 6 known
--   "qualities" instead of a free-growing catalog — Fabric under SKF
--   PolyTex, and LLD/EVA/HD Polybag, BOPP, PP under SKF PolyBags (same
--   category split the schema already enforces). Units are trimmed to just
--   KG and PCS everywhere (see the App.jsx unit-list change alongside this
--   migration) — default_unit here is just the form's starting pick, both
--   units stay selectable per line either way. The items table was empty
--   (no seed existed before), so this is a plain insert, not an archive.
--   The old items_default_unit_check / invoice_items_unit_check constraints
--   (bags/rolls/kg/meters/pieces) are replaced with just ('KG','PCS').
-- - Party seed: 12 named parties from the brief. FARAZ SPORTS trades as
--   both a customer and a supplier, so it gets two independent party rows
--   (matching how create_party already works — name is not unique, each
--   row gets its own ledger account). One customer row for FARAZ SPORTS
--   already exists from earlier testing, so that insert is skipped.
-- - create_party's permission check (party_master OR entry_sale OR
--   entry_purchase 'create') is removed entirely — any authenticated user
--   can now add a customer or supplier, full stop, per explicit request.
-- ============================================================================

alter table public.items drop constraint items_default_unit_check;
alter table public.items add constraint items_default_unit_check check (default_unit in ('KG','PCS'));

alter table public.invoice_items drop constraint invoice_items_unit_check;
alter table public.invoice_items add constraint invoice_items_unit_check check (unit in ('KG','PCS'));

insert into public.items (name, category, default_unit) values
  ('Fabric',       'fabric',   'KG'),
  ('LLD Polybag',  'polybags', 'PCS'),
  ('EVA Bag',      'polybags', 'PCS'),
  ('HD Polybag',   'polybags', 'PCS'),
  ('BOPP',         'polybags', 'PCS'),
  ('PP',           'polybags', 'PCS');

do $$
declare
  v_name text;
  v_account_id uuid;
begin
  foreach v_name in array array[
    'CASH SALE', 'FARAZ SPORTS', 'FARAZ HOSIERY', 'AWAMI DYEING', 'GONDAL DYEING',
    'BHUTTA DYEING', 'MUNAWAR INDUSTRIES', 'BLUE HORIZON', 'NEKA PAK', 'RS PLASTIC'
  ] loop
    if not exists (select 1 from public.parties where name = v_name and type = 'customer') then
      insert into public.chart_of_accounts (name, type) values (v_name, 'party') returning id into v_account_id;
      insert into public.parties (name, type, category, ledger_account_id) values (v_name, 'customer', '{}', v_account_id);
    end if;
  end loop;

  foreach v_name in array array['ZAK ENTERPRISES', 'UMER PLASTIC', 'FARAZ SPORTS'] loop
    if not exists (select 1 from public.parties where name = v_name and type = 'supplier') then
      insert into public.chart_of_accounts (name, type) values (v_name, 'party') returning id into v_account_id;
      insert into public.parties (name, type, category, ledger_account_id) values (v_name, 'supplier', '{}', v_account_id);
    end if;
  end loop;
end $$;

create or replace function public.create_party(
  p_name text, p_type text, p_category text[], p_contact text,
  p_address text, p_opening_balance numeric default 0
) returns uuid language plpgsql security definer as $$
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
alter function public.create_party(text, text, text[], text, text, numeric) set search_path = public;
