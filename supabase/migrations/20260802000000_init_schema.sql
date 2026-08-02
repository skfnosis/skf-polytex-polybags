-- ============================================================================
-- SKF PolyTex / SKF PolyBags — Unified Trading & Accounting App
-- Target: Supabase (PostgreSQL)
-- ============================================================================
-- HOW TO USE
-- 1. Create a Supabase project (supabase.com), open SQL Editor.
-- 2. Paste this whole file and run it once, top to bottom.
-- 3. It creates every table, the permission model, and every write path
--    (invoices, expenses, payments, voids) as SECURITY DEFINER functions,
--    so the ledger can never go out of sync with what's on screen.
--
-- DESIGN NOTES (decisions made per "go with recommendations")
-- - One brand-neutral shared ledger. brand_key on invoices/expenses is a
--   label for the letterhead only; every row still posts to one
--   chart_of_accounts / ledger_entries pair.
-- - WRITES GO THROUGH FUNCTIONS, NOT RAW INSERTS.
--   Direct INSERT/UPDATE/DELETE on invoices, invoice_items, expenses,
--   payments and ledger_entries is blocked for normal users (no RLS
--   policy grants it). Instead the app calls create_invoice(),
--   create_expense(), record_payment(), void_invoice(), void_expense() —
--   each one is atomic (all rows succeed or none do) and each one checks
--   page_permissions itself, so the permission rule and the posting rule
--   can never drift apart. This is stricter than "trigger recomputes
--   total after the fact" and avoids half-posted invoices.
-- - Permissions are per page AND per action (View / Create / Edit /
--   Approve) rather than a single on/off switch, matching the finer
--   model already used in the Faraz Sports/SKFnosis ERP. Approve is used
--   for voiding a posted invoice/expense.
-- - Invoices are single-category (fabric OR polybags) per the brief's
--   default. A party can be tagged for both categories.
-- - Posted documents are never deleted, only voided. Voiding writes a
--   reversing ledger entry rather than touching the original rows, so
--   the audit trail stays intact.
-- - Cash/Bank is multiple accounts (seeded: Cash in Hand + one Bank
--   Account placeholder) so payments can specify which one.
-- - Expense categories each get their own ledger account (Fuel, Rent,
--   Salaries, Misc seeded) instead of one bucket, so a P&L by category
--   is possible later.
-- - PKR, whole rupees, no decimals, no tax — amount = quantity * rate.
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. USERS / PROFILES
-- Supabase Auth (auth.users) handles login/password. Login is by username,
-- so email_for_username() below resolves username -> email before sign-in.
-- ============================================================================

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  full_name text not null,
  is_admin boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  last_login timestamptz
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, username, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
          coalesce(new.raw_user_meta_data->>'full_name', 'New User'));
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Callable pre-login (anon) so the login screen can turn a typed username
-- into the email Supabase Auth actually needs. Only ever returns an email,
-- nothing else, and only for active accounts.
create or replace function public.email_for_username(p_username text)
returns text language sql security definer stable as $$
  select u.email
  from auth.users u
  join public.profiles p on p.id = u.id
  where p.username = p_username and p.active = true
  limit 1;
$$;
grant execute on function public.email_for_username(text) to anon, authenticated;

-- ============================================================================
-- 2. PAGE PERMISSIONS  (per page, per action: View / Create / Edit / Approve)
-- ============================================================================

create table public.page_permissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  page_key text not null check (page_key in (
    'dashboard','entry_sale','entry_purchase','entry_expense',
    'reports','party_master','settings'
  )),
  can_view boolean not null default false,
  can_create boolean not null default false,
  can_edit boolean not null default false,
  can_approve boolean not null default false,
  granted_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  unique (user_id, page_key)
);

-- Helper used everywhere else: true for admins always, otherwise checks the
-- grid above. action is one of 'view' | 'create' | 'edit' | 'approve'.
create or replace function public.has_permission(p_page text, p_action text)
returns boolean language sql security definer stable as $$
  select
    coalesce((select is_admin from public.profiles where id = auth.uid()), false)
    or exists (
      select 1 from public.page_permissions pp
      where pp.user_id = auth.uid() and pp.page_key = p_page
        and case p_action
              when 'view' then pp.can_view
              when 'create' then pp.can_create
              when 'edit' then pp.can_edit
              when 'approve' then pp.can_approve
              else false
            end
    );
$$;

-- ============================================================================
-- 3. BRANDS
-- ============================================================================

create table public.brand_settings (
  id uuid primary key default gen_random_uuid(),
  brand_key text unique not null check (brand_key in ('skf_polytex','skf_polybags')),
  display_name text not null,
  category text not null check (category in ('fabric','polybags')),
  logo_url text,
  address text,
  contact_info text
);

insert into public.brand_settings (brand_key, display_name, category, logo_url) values
  ('skf_polytex',  'SKF PolyTex',  'fabric',   null),
  ('skf_polybags', 'SKF PolyBags', 'polybags', null);
-- Update logo_url later, e.g.:
-- update public.brand_settings set logo_url = 'https://www.skfpolytex.xyz/images/logo.png' where brand_key = 'skf_polytex';

-- ============================================================================
-- 4. CHART OF ACCOUNTS
-- ============================================================================

create table public.chart_of_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null check (type in ('sales','purchase','expense','cash_bank','party')),
  is_system boolean not null default false, -- true = seeded, can't be deleted
  created_at timestamptz not null default now()
);

insert into public.chart_of_accounts (name, type, is_system) values
  ('Sales',              'sales',     true),
  ('Purchase',           'purchase',  true),
  ('Cash in Hand',       'cash_bank', true),
  ('Bank Account',       'cash_bank', true),
  ('Fuel & Transport',   'expense',   true),
  ('Rent',               'expense',  true),
  ('Salaries',           'expense',  true),
  ('Utilities',          'expense',  true),
  ('Miscellaneous',      'expense',  true);

-- ============================================================================
-- 5. PARTIES  (shared customers/suppliers across both brands)
-- category is an array so one party can trade in both product lines.
-- ============================================================================

create table public.parties (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null check (type in ('customer','supplier')),
  category text[] not null default '{}',   -- subset of {fabric, polybags}
  contact text,
  address text,
  ledger_account_id uuid references public.chart_of_accounts(id),
  opening_balance numeric not null default 0, -- +ve = party owes us
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- Every party automatically gets its own ledger (chart_of_accounts) row so
-- ledger_entries can post against it individually.
create or replace function public.create_party(
  p_name text, p_type text, p_category text[], p_contact text,
  p_address text, p_opening_balance numeric default 0
) returns uuid language plpgsql security definer as $$
declare
  v_account_id uuid;
  v_party_id uuid;
begin
  if not (public.has_permission('party_master','create')
          or public.has_permission('entry_sale','create')
          or public.has_permission('entry_purchase','create')) then
    raise exception 'Not permitted to add parties';
  end if;

  insert into public.chart_of_accounts (name, type) values (p_name, 'party')
    returning id into v_account_id;

  insert into public.parties (name, type, category, contact, address,
                               ledger_account_id, opening_balance, created_by)
  values (p_name, p_type, p_category, p_contact, p_address,
          v_account_id, p_opening_balance, auth.uid())
  returning id into v_party_id;

  if p_opening_balance <> 0 then
    -- customer opening balance = they owe us = debit party, credit a
    -- neutral "Opening Balance Equity" style entry via Sales/Purchase
    -- account of matching type so the trial balance still ties out.
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
grant execute on function public.create_party(text, text, text[], text, text, numeric) to authenticated;

-- ============================================================================
-- 6. INVOICES  +  INVOICE ITEMS
-- invoice_no is per invoice_type (SI-01, SI-02 ... / PI-01, PI-02 ...),
-- shared across both brands (no brand prefix), per the brief.
-- ============================================================================

create sequence public.sale_invoice_seq start 1;
create sequence public.purchase_invoice_seq start 1;

create or replace function public.next_invoice_no(p_invoice_type text)
returns text language plpgsql as $$
begin
  if p_invoice_type = 'sale' then
    return 'SI-' || lpad(nextval('public.sale_invoice_seq')::text, 2, '0');
  else
    return 'PI-' || lpad(nextval('public.purchase_invoice_seq')::text, 2, '0');
  end if;
end; $$;

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_no text unique not null,
  invoice_type text not null check (invoice_type in ('sale','purchase')),
  brand_key text not null references public.brand_settings(brand_key),
  category text not null check (category in ('fabric','polybags')),
  party_id uuid not null references public.parties(id),
  invoice_date date not null,
  total_amount numeric not null default 0,
  status text not null default 'posted' check (status in ('posted','voided')),
  voided_at timestamptz,
  voided_by uuid references public.profiles(id),
  void_reason text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  quantity numeric not null,
  unit text not null check (unit in ('meters','kg','pieces')),
  rate numeric not null,
  description text,
  amount numeric generated always as (quantity * rate) stored
);

create index on public.invoices (invoice_type, invoice_date);
create index on public.invoices (party_id);
create index on public.invoice_items (invoice_id);

-- Atomic: insert invoice header + all line items + post the double-entry
-- ledger rows, in one transaction. p_items is a jsonb array of
-- {quantity, unit, rate, description}.
create or replace function public.create_invoice(
  p_invoice_type text, p_brand_key text, p_category text,
  p_party_id uuid, p_invoice_date date, p_items jsonb
) returns uuid language plpgsql security definer as $$
declare
  v_page text := case when p_invoice_type = 'sale' then 'entry_sale' else 'entry_purchase' end;
  v_invoice_id uuid;
  v_invoice_no text;
  v_total numeric := 0;
  v_item jsonb;
  v_party_account uuid;
  v_trade_account uuid; -- Sales or Purchase account
begin
  if not public.has_permission(v_page, 'create') then
    raise exception 'Not permitted to create % invoices', p_invoice_type;
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Invoice must have at least one line item';
  end if;

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;
  select id into v_trade_account from public.chart_of_accounts
    where type = case when p_invoice_type = 'sale' then 'sales' else 'purchase' end limit 1;

  v_invoice_no := public.next_invoice_no(p_invoice_type);

  insert into public.invoices (invoice_no, invoice_type, brand_key, category, party_id, invoice_date, created_by)
  values (v_invoice_no, p_invoice_type, p_brand_key, p_category, p_party_id, p_invoice_date, auth.uid())
  returning id into v_invoice_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    insert into public.invoice_items (invoice_id, quantity, unit, rate, description)
    values (v_invoice_id,
            (v_item->>'quantity')::numeric,
            v_item->>'unit',
            (v_item->>'rate')::numeric,
            v_item->>'description');
    v_total := v_total + (v_item->>'quantity')::numeric * (v_item->>'rate')::numeric;
  end loop;

  update public.invoices set total_amount = v_total where id = v_invoice_id;

  -- Sale: debit the customer (they owe us more), credit Sales.
  -- Purchase: debit Purchase (expense of goods), credit the supplier (we owe more).
  if p_invoice_type = 'sale' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_trade_account, p_party_id, v_total, 0, 'invoice', v_invoice_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_invoice_date, v_party_account, p_party_id, 0, v_total, 'invoice', v_invoice_id);
  end if;

  return v_invoice_id;
end; $$;
grant execute on function public.create_invoice(text, text, text, uuid, date, jsonb) to authenticated;

-- Void = reverse, never delete. Requires 'approve' on the matching entry page.
create or replace function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void language plpgsql security definer as $$
declare
  v_invoice public.invoices;
  v_page text;
begin
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice is null then raise exception 'Invoice not found'; end if;
  if v_invoice.status = 'voided' then raise exception 'Invoice already voided'; end if;

  v_page := case when v_invoice.invoice_type = 'sale' then 'entry_sale' else 'entry_purchase' end;
  if not public.has_permission(v_page, 'approve') then
    raise exception 'Not permitted to void % invoices', v_invoice.invoice_type;
  end if;

  insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
  select current_date, account_id, party_id, credit, debit, 'void', v_invoice.id
  from public.ledger_entries where reference_type = 'invoice' and reference_id = v_invoice.id;

  update public.invoices
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_invoice_id;
end; $$;
grant execute on function public.void_invoice(uuid, text) to authenticated;

-- ============================================================================
-- 7. EXPENSES
-- ============================================================================

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  expense_date date not null,
  expense_account_id uuid not null references public.chart_of_accounts(id),
  cash_bank_account_id uuid not null references public.chart_of_accounts(id),
  brand_key text references public.brand_settings(brand_key), -- optional: not every expense is brand-specific
  description text,
  amount numeric not null,
  status text not null default 'posted' check (status in ('posted','voided')),
  voided_at timestamptz,
  voided_by uuid references public.profiles(id),
  void_reason text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create or replace function public.create_expense(
  p_expense_date date, p_expense_account_id uuid, p_cash_bank_account_id uuid,
  p_brand_key text, p_description text, p_amount numeric
) returns uuid language plpgsql security definer as $$
declare
  v_expense_id uuid;
begin
  if not public.has_permission('entry_expense', 'create') then
    raise exception 'Not permitted to create expenses';
  end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;

  insert into public.expenses (expense_date, expense_account_id, cash_bank_account_id,
                                brand_key, description, amount, created_by)
  values (p_expense_date, p_expense_account_id, p_cash_bank_account_id,
          p_brand_key, p_description, p_amount, auth.uid())
  returning id into v_expense_id;

  insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id)
  values (p_expense_date, p_expense_account_id, p_amount, 0, 'expense', v_expense_id);
  insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id)
  values (p_expense_date, p_cash_bank_account_id, 0, p_amount, 'expense', v_expense_id);

  return v_expense_id;
end; $$;
grant execute on function public.create_expense(date, uuid, uuid, text, text, numeric) to authenticated;

create or replace function public.void_expense(p_expense_id uuid, p_reason text)
returns void language plpgsql security definer as $$
declare
  v_expense public.expenses;
begin
  select * into v_expense from public.expenses where id = p_expense_id;
  if v_expense is null then raise exception 'Expense not found'; end if;
  if v_expense.status = 'voided' then raise exception 'Expense already voided'; end if;
  if not public.has_permission('entry_expense', 'approve') then
    raise exception 'Not permitted to void expenses';
  end if;

  insert into public.ledger_entries (entry_date, account_id, debit, credit, reference_type, reference_id)
  select current_date, account_id, credit, debit, 'void', v_expense.id
  from public.ledger_entries where reference_type = 'expense' and reference_id = v_expense.id;

  update public.expenses
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
    where id = p_expense_id;
end; $$;
grant execute on function public.void_expense(uuid, text) to authenticated;

-- ============================================================================
-- 8. PAYMENTS  (receipts from customers / payments to suppliers)
-- Not in the original brief's schema, added because "receivables/payables"
-- without a way to record cash coming in/out only gives half the picture.
-- ============================================================================

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  payment_date date not null,
  party_id uuid not null references public.parties(id),
  direction text not null check (direction in ('receipt','payment')), -- receipt = from customer, payment = to supplier
  amount numeric not null,
  method text check (method in ('cash','bank_transfer','cheque','other')),
  cash_bank_account_id uuid not null references public.chart_of_accounts(id),
  linked_invoice_id uuid references public.invoices(id),
  notes text,
  status text not null default 'posted' check (status in ('posted','voided')),
  voided_at timestamptz,
  voided_by uuid references public.profiles(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create or replace function public.record_payment(
  p_payment_date date, p_party_id uuid, p_direction text, p_amount numeric,
  p_method text, p_cash_bank_account_id uuid, p_linked_invoice_id uuid, p_notes text
) returns uuid language plpgsql security definer as $$
declare
  v_payment_id uuid;
  v_party_account uuid;
  v_page text := case when p_direction = 'receipt' then 'entry_sale' else 'entry_purchase' end;
begin
  if not public.has_permission(v_page, 'create') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;

  select ledger_account_id into v_party_account from public.parties where id = p_party_id;

  insert into public.payments (payment_date, party_id, direction, amount, method,
                                cash_bank_account_id, linked_invoice_id, notes, created_by)
  values (p_payment_date, p_party_id, p_direction, p_amount, p_method,
          p_cash_bank_account_id, p_linked_invoice_id, p_notes, auth.uid())
  returning id into v_payment_id;

  -- Receipt: debit cash/bank, credit party (reduces what they owe us).
  -- Payment: debit party (reduces what we owe them), credit cash/bank.
  if p_direction = 'receipt' then
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, p_amount, 0, 'payment', v_payment_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, v_party_account, p_party_id, 0, p_amount, 'payment', v_payment_id);
  else
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, v_party_account, p_party_id, p_amount, 0, 'payment', v_payment_id);
    insert into public.ledger_entries (entry_date, account_id, party_id, debit, credit, reference_type, reference_id)
    values (p_payment_date, p_cash_bank_account_id, p_party_id, 0, p_amount, 'payment', v_payment_id);
  end if;

  return v_payment_id;
end; $$;
grant execute on function public.record_payment(date, uuid, text, numeric, text, uuid, uuid, text) to authenticated;

-- ============================================================================
-- 9. LEDGER  (append-only; only ever written by the functions above)
-- ============================================================================

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  entry_date date not null,
  account_id uuid not null references public.chart_of_accounts(id),
  party_id uuid references public.parties(id),
  debit numeric not null default 0,
  credit numeric not null default 0,
  reference_type text not null check (reference_type in ('invoice','expense','payment','opening_balance','void')),
  reference_id uuid,
  created_at timestamptz not null default now()
);

create index on public.ledger_entries (account_id, entry_date);
create index on public.ledger_entries (party_id, entry_date);

-- Convenience view for Trial Balance: net movement + balance per account.
create or replace view public.v_trial_balance as
select
  a.id as account_id, a.name, a.type,
  coalesce(sum(l.debit), 0) as total_debit,
  coalesce(sum(l.credit), 0) as total_credit,
  coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) as balance
from public.chart_of_accounts a
left join public.ledger_entries l on l.account_id = a.id
group by a.id, a.name, a.type;

-- ============================================================================
-- 10. DASHBOARD SUMMARY  (computed server-side, not pulled row-by-row)
-- ============================================================================

create or replace function public.dashboard_summary(p_from date, p_to date, p_brand text default null)
returns table (sales numeric, purchase numeric, expenses numeric, profit numeric)
language sql security definer stable as $$
  select
    coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'sale' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0) as sales,
    coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'purchase' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0) as purchase,
    coalesce((select sum(amount) from public.expenses
              where status = 'posted' and expense_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand or brand_key is null)), 0) as expenses,
    coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'sale' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0)
    - coalesce((select sum(total_amount) from public.invoices
              where invoice_type = 'purchase' and status = 'posted'
                and invoice_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand)), 0)
    - coalesce((select sum(amount) from public.expenses
              where status = 'posted' and expense_date between p_from and p_to
                and (p_brand is null or brand_key = p_brand or brand_key is null)), 0) as profit;
$$;
grant execute on function public.dashboard_summary(date, date, text) to authenticated;

-- ============================================================================
-- 11. HEARTBEAT  (used by the keep-alive GitHub Action, see .github/workflows)
-- ============================================================================

create table public.heartbeat (
  id int primary key default 1,
  pinged_at timestamptz not null default now()
);
insert into public.heartbeat (id) values (1);

-- ============================================================================
-- 12. ROW LEVEL SECURITY
-- Read access is granted per table, gated by page permission. All writes
-- happen through the SECURITY DEFINER functions above, so (deliberately)
-- there are no INSERT/UPDATE/DELETE policies for normal users below —
-- the functions already checked has_permission() before touching a row.
-- ============================================================================

alter table public.profiles enable row level security;
alter table public.page_permissions enable row level security;
alter table public.brand_settings enable row level security;
alter table public.chart_of_accounts enable row level security;
alter table public.parties enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.expenses enable row level security;
alter table public.payments enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.heartbeat enable row level security;

create policy "self or admin can read profiles" on public.profiles for select
  using (auth.uid() = id or public.has_permission('settings','view'));
create policy "admin can manage profiles" on public.profiles for all
  using (coalesce((select is_admin from public.profiles where id = auth.uid()), false));

create policy "self can read own permissions" on public.page_permissions for select
  using (user_id = auth.uid() or public.has_permission('settings','view'));
create policy "admin manages permissions" on public.page_permissions for all
  using (coalesce((select is_admin from public.profiles where id = auth.uid()), false));

create policy "brand settings readable by all authenticated" on public.brand_settings
  for select using (auth.role() = 'authenticated');
create policy "admin manages brand settings" on public.brand_settings for all
  using (coalesce((select is_admin from public.profiles where id = auth.uid()), false));

create policy "chart of accounts readable by all authenticated" on public.chart_of_accounts
  for select using (auth.role() = 'authenticated');
create policy "admin manages chart of accounts" on public.chart_of_accounts for all
  using (coalesce((select is_admin from public.profiles where id = auth.uid()), false));

-- Parties: names/contacts aren't sensitive financial data, so any signed-in
-- user can view them (needed for the party picker during entry). Writes
-- only via create_party().
create policy "parties readable by all authenticated" on public.parties
  for select using (auth.role() = 'authenticated');

create policy "sale invoices viewable with entry_sale view" on public.invoices for select
  using (invoice_type = 'sale' and public.has_permission('entry_sale','view'));
create policy "purchase invoices viewable with entry_purchase view" on public.invoices for select
  using (invoice_type = 'purchase' and public.has_permission('entry_purchase','view'));
create policy "reports view sees all invoices" on public.invoices for select
  using (public.has_permission('reports','view') or public.has_permission('dashboard','view'));

create policy "invoice items follow parent invoice visibility" on public.invoice_items for select
  using (exists (
    select 1 from public.invoices i where i.id = invoice_id and (
      (i.invoice_type = 'sale' and public.has_permission('entry_sale','view')) or
      (i.invoice_type = 'purchase' and public.has_permission('entry_purchase','view')) or
      public.has_permission('reports','view') or public.has_permission('dashboard','view')
    )
  ));

create policy "expenses viewable with entry_expense or reports view" on public.expenses for select
  using (public.has_permission('entry_expense','view') or public.has_permission('reports','view'));

create policy "payments viewable with entry view or reports" on public.payments for select
  using (public.has_permission('entry_sale','view') or public.has_permission('entry_purchase','view')
         or public.has_permission('reports','view'));

create policy "ledger viewable with reports or dashboard view" on public.ledger_entries for select
  using (public.has_permission('reports','view') or public.has_permission('dashboard','view')
         or public.has_permission('party_master','view'));

create policy "heartbeat readable by service" on public.heartbeat for select using (true);
create policy "heartbeat writable by service" on public.heartbeat for update using (true);

-- ============================================================================
-- 13. FIRST ADMIN
-- After you sign up your first user through Supabase Auth, run:
--   update public.profiles set is_admin = true where username = 'your_username';
-- and grant yourself full page_permissions rows, e.g.:
--   insert into public.page_permissions (user_id, page_key, can_view, can_create, can_edit, can_approve)
--   select id, page_key, true, true, true, true
--   from public.profiles, unnest(array['dashboard','entry_sale','entry_purchase','entry_expense','reports','party_master','settings']) as page_key
--   where username = 'your_username';
-- (Admins bypass has_permission() anyway, so this is mostly for consistency.)
-- ============================================================================
