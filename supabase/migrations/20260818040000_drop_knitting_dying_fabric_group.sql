-- ============================================================================
-- Remove "Knitting + Dying" as a fabric group option for SKF PolyTex — no
-- items used it, so "In House" is now the only fabric group.
-- ============================================================================

alter table public.items drop constraint items_fabric_group_check;
alter table public.items add constraint items_fabric_group_check
  check ((fabric_group is null) or (fabric_group = 'in_house'));
