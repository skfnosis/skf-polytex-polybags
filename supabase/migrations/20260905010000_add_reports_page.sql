-- ============================================================================
-- Reintroduce a "reports" page_key so the new Reports nav item (General
-- Ledger, Trial Balance, Sale/Purchase/Voucher reports, moved out of Chart
-- of Accounts) can be granted like any other page. 'reports' existed in the
-- original page_key check constraint but was dropped when entry_voucher/
-- entry_jv replaced entry_expense/reports — same enum-drift class of bug
-- fixed for ledger_entries_reference_type_check before: the app can only
-- grant a page_key the DB constraint actually allows.
-- ============================================================================

alter table public.page_permissions drop constraint page_permissions_page_key_check;
alter table public.page_permissions add constraint page_permissions_page_key_check
  check (page_key in (
    'dashboard', 'entry_voucher', 'entry_jv', 'entry_sale', 'entry_purchase',
    'item_master', 'party_master', 'reports', 'settings'
  ));
