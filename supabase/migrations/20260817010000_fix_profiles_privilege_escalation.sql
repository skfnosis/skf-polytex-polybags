-- ============================================================================
-- SECURITY FIX: privilege escalation via the "admin can manage profiles" RLS
-- policy on public.profiles.
-- ============================================================================
-- That policy (added by 20260804000002_fix_profiles_rls_recursion.sql to cure
-- an infinite-recursion bug) is:
--   for all using (has_permission('settings', 'view'))
-- has_permission('settings','view') is true for real admins, but ALSO true
-- for any ordinary user who has been granted plain "View" access to the
-- Settings page via the Admin > Users permission grid -- a completely normal
-- admin action (e.g. letting a trusted employee see the Voucher Audit tab).
-- Because this is a FOR ALL policy with no separate WITH CHECK clause, the
-- USING expression governs INSERT/UPDATE/DELETE too. So a "settings viewer"
-- who is not an admin could, with one authenticated REST call to their own
-- Supabase project (no app UI involved), UPDATE their own profiles row and
-- set is_admin = true -- a full privilege escalation to admin.
--
-- Fix: gate the write policy on a real, non-recursive is_admin() check
-- instead of the page-permission proxy. This mirrors the row_security=off
-- technique already used for has_permission() so it doesn't reintroduce the
-- self-referencing-policy recursion the prior migration fixed.
-- ============================================================================

create or replace function public.is_admin()
returns boolean language sql security definer stable as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;
alter function public.is_admin() set row_security = off;
grant execute on function public.is_admin() to authenticated;

drop policy "admin can manage profiles" on public.profiles;
create policy "admin can manage profiles" on public.profiles for all
  using (public.is_admin())
  with check (public.is_admin());
