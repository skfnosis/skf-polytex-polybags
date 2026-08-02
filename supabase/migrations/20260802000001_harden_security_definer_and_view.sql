-- Fix: v_trial_balance ran with the view owner's privileges by default,
-- bypassing the RLS check on ledger_entries (which gates on
-- has_permission('reports'|'dashboard'|'party_master','view')). Switching
-- to security_invoker makes it run as the querying user, so the existing
-- RLS policies on chart_of_accounts/ledger_entries apply as intended.
alter view public.v_trial_balance set (security_invoker = true);

-- Pin search_path on every SECURITY DEFINER function so a malicious
-- search_path set by the caller can't redirect unqualified references.
alter function public.handle_new_user() set search_path = public;
alter function public.email_for_username(text) set search_path = public;
alter function public.has_permission(text, text) set search_path = public;
alter function public.create_party(text, text, text[], text, text, numeric) set search_path = public;
alter function public.next_invoice_no(text) set search_path = public;
alter function public.create_invoice(text, text, text, uuid, date, jsonb) set search_path = public;
alter function public.void_invoice(uuid, text) set search_path = public;
alter function public.create_expense(date, uuid, uuid, text, text, numeric) set search_path = public;
alter function public.void_expense(uuid, text) set search_path = public;
alter function public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text) set search_path = public;
alter function public.dashboard_summary(date, date, text) set search_path = public;
