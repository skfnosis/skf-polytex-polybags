-- ============================================================================
-- MATERIAL CHART — a browsable, category-wise Item Master (parallel to
-- Chart of Accounts), with a guided "Add Fabric" flow: Category -> Group
-- (In House / Knitting + Dying, fabric only) -> Name -> Composition
-- (fabric only) -> Unit.
-- ============================================================================
-- Also fixes page_permissions_page_key_check, which was never updated when
-- entry_voucher/entry_jv replaced entry_expense/reports — savePagePermissions
-- upserts a row per PAGES key in one batch, so granting ANY user's
-- permissions has been failing outright since that rename. Brings the
-- constraint in line with the live PAGES keys plus the new item_master page.
-- ============================================================================

alter table public.items add column if not exists fabric_group text;
alter table public.items add column if not exists composition text;
alter table public.items add constraint items_fabric_group_check
  check (fabric_group is null or fabric_group in ('in_house', 'knitting_dying'));

create or replace function public.create_item(
  p_name text, p_category text, p_default_unit text,
  p_fabric_group text default null, p_composition text default null
) returns uuid language plpgsql security definer as $$
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
grant execute on function public.create_item(text, text, text, text, text) to authenticated;
alter function public.create_item(text, text, text, text, text) set search_path = public;

create or replace function public.update_item(
  p_item_id uuid, p_name text, p_default_unit text,
  p_fabric_group text default null, p_composition text default null
) returns void language plpgsql security definer as $$
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
grant execute on function public.update_item(uuid, text, text, text, text) to authenticated;
alter function public.update_item(uuid, text, text, text, text) set search_path = public;

alter table public.page_permissions drop constraint page_permissions_page_key_check;
alter table public.page_permissions add constraint page_permissions_page_key_check
  check (page_key in (
    'dashboard', 'entry_voucher', 'entry_jv', 'entry_sale', 'entry_purchase',
    'item_master', 'party_master', 'settings'
  ));
