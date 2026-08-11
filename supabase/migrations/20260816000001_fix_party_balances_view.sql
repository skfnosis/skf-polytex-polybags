-- ============================================================================
-- FIX v_party_balances — was summing both legs of every posting.
-- ============================================================================
-- create_invoice/record_payment/etc. denormalize party_id onto BOTH ledger
-- rows of a transaction (the party's own account AND the offsetting trade/
-- cash account) so all activity "about" a party is easy to filter. The
-- original view joined on that same party_id with no account filter, so it
-- summed both legs of every transaction — which always net to zero. Every
-- party's Dashboard balance (Total Receivable/Payable, customer/vendor
-- drill-downs) has been silently showing 0 since this view was introduced.
-- Fix: join specifically on the party's own ledger account.
-- ============================================================================

create or replace view public.v_party_balances as
select
  p.id as party_id, p.name, p.type, p.category,
  coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) as balance
from public.parties p
left join public.ledger_entries l on l.account_id = p.ledger_account_id
group by p.id, p.name, p.type, p.category;
alter view public.v_party_balances set (security_invoker = true);
