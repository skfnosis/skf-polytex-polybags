-- ============================================================================
-- Fix: editing an already-posted Purchase/Sale Bill or Return has been
-- broken since the Edit feature was introduced. update_invoice reverses the
-- document's old ledger entries with reference_type = 'invoice_edit', but
-- that value was never added to ledger_entries' own check constraint — so
-- every such reversal insert failed with a check-constraint violation. This
-- never surfaced on an Order (which never posts to the ledger, so there was
-- nothing to reverse) — only on a Bill/Return that already had real ledger
-- entries to reverse, which is exactly the case a user hit just now.
-- ============================================================================

alter table public.ledger_entries drop constraint ledger_entries_reference_type_check;
alter table public.ledger_entries add constraint ledger_entries_reference_type_check
  check (reference_type = any (array['invoice', 'invoice_edit', 'expense', 'payment', 'opening_balance', 'void', 'journal_voucher']));
