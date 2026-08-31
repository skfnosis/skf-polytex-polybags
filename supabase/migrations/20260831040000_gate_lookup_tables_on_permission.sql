-- ============================================================================
-- parties / chart_of_accounts / items / brand_settings were readable by any
-- authenticated user just for being logged in — every other table in this
-- schema requires an actual granted page permission via has_permission().
-- That gap is unreachable today (there is no self-signup path in the app),
-- but Supabase Auth's email/password signup is a project-level setting, not
-- something this code controls — if it were ever enabled, a bare signed-up
-- account with zero permission grants could read every party's name/contact,
-- the full chart of accounts, and all items. Tightened to require the same
-- bar as everywhere else: is_admin, or at least one granted permission —
-- not a specific page, since Purchase/Sale entry needs to read parties and
-- items regardless of which page permission a user happens to hold.
-- ============================================================================

create or replace function public.has_any_permission()
returns boolean language sql stable security definer set search_path = public as $$
  select
    coalesce((select is_admin from public.profiles where id = auth.uid()), false)
    or exists (
      select 1 from public.page_permissions pp
      where pp.user_id = auth.uid()
        and (pp.can_view or pp.can_create or pp.can_edit or pp.can_approve)
    );
$$;

drop policy "parties readable by all authenticated" on public.parties;
create policy "parties readable by permitted users" on public.parties
  for select using (public.has_any_permission());

drop policy "chart of accounts readable by all authenticated" on public.chart_of_accounts;
create policy "chart of accounts readable by permitted users" on public.chart_of_accounts
  for select using (public.has_any_permission());

drop policy "items readable by all authenticated" on public.items;
create policy "items readable by permitted users" on public.items
  for select using (public.has_any_permission());

drop policy "brand settings readable by all authenticated" on public.brand_settings;
create policy "brand settings readable by permitted users" on public.brand_settings
  for select using (public.has_any_permission());
