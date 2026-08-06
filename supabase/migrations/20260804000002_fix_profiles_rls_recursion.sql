-- ============================================================================
-- FIX: infinite recursion in the "admin can manage profiles" RLS policy.
-- ============================================================================
-- The original policy (from the very first migration) ran a raw, unprotected
-- subquery against public.profiles from within a policy ON public.profiles:
--   using ((select is_admin from public.profiles where id = auth.uid()))
-- Postgres has to apply RLS to that inner select too, which re-enters the
-- same policy, which runs the same select again — infinite recursion,
-- surfaced to the client as "infinite recursion detected in policy for
-- relation 'profiles'" and breaking every profile fetch (so every login).
--
-- has_permission() already exists as a SECURITY DEFINER function used by
-- every other admin-gated policy in this schema; the only thing stopping it
-- from being reused here is that SECURITY DEFINER alone doesn't bypass RLS —
-- it just runs as the function owner, whose own reads of profiles are still
-- subject to the same policy. Pinning row_security = off on the function
-- makes it provably immune, since it already runs as the owning role which
-- has BYPASSRLS. Rewriting the policy to call has_permission() instead of
-- duplicating the unprotected subquery removes the recursive self-reference.
-- ============================================================================

alter function public.has_permission(text, text) set row_security = off;

drop policy "admin can manage profiles" on public.profiles;
create policy "admin can manage profiles" on public.profiles for all
  using (public.has_permission('settings', 'view'));
