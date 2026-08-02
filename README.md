# SKF PolyTex / SKF PolyBags — ERP (React + Vite + Supabase)

Same stack and conventions as the Faraz Sports / SKFnosis ERP: one React app
(`src/App.jsx`), Vite build, Tailwind, `@supabase/supabase-js`, deployable to
Vercel. This replaces the earlier Flutter version — same database schema,
new frontend.

## ✅ This one has actually been built and verified

Unlike the Flutter attempt, this sandbox *can* reach the npm registry, so:
```
npm install   → 207 packages installed clean
npm run build → ✓ 1908 modules transformed, built in ~13s
```
That's real confirmation there are no syntax errors, no broken imports, and
every dependency resolves. It hasn't been *run* against a live Supabase
project yet (I don't have your project's URL/keys), so the actual data
flows — RLS, RPC calls, exports — still need a real run-through on your end.

## 1. Create the Supabase project

Go to supabase.com/dashboard → your **SKF NOSIS** org → **New project**.
Name it `skf-polytex-polybags` (or similar), pick a region, set a DB
password. Once it's ready, send me the project ref (or just say "it's
created") and I'll apply the schema for you directly — same SQL as the
Flutter version, it's plain Postgres/Supabase, nothing Flutter-specific was
in it. Otherwise, do it yourself:

1. Open **SQL Editor**, paste the full contents of
   `supabase/migrations/20260802000000_init_schema.sql`, run it once.
2. **Authentication → Users → Add user** — create your login (email +
   password).
3. In SQL Editor:
   ```sql
   select username from public.profiles;
   update public.profiles set is_admin = true where username = 'your_username';
   ```

## 2. Configure the app

```bash
cp .env.example .env
```
Fill in `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` from
**Settings → API**. `.env` is gitignored.

## 3. Run it locally

```bash
npm install
npm run dev
```
Opens on `http://localhost:5173`. Log in with your **username** (not the
full email — the login screen resolves it server-side), the password from
step 1.

## 4. Deploy to Vercel

```bash
npm i -g vercel   # if you don't have it
vercel
```
Or connect the GitHub repo in the Vercel dashboard and set the two `VITE_*`
env vars there under **Settings → Environment Variables**. Build command
`npm run build`, output directory `dist` (Vercel auto-detects this for
Vite).

## What's built

Same feature set as the Flutter version, same schema, same permission
model — just a browser UI instead of a native app:

- **Login** by username, one shared session for the whole app
- **Dashboard** — date range (defaults 1st-of-month→today), brand filter,
  Sales/Purchase/Expenses/Profit cards
- **Sale & Purchase invoice entry** — brand tabs, searchable party picker
  with inline "add new party," dynamic line items with brand-correct units
- **Expense entry** — category, cash/bank account, optional brand tag
- **Party Master** — search, add, per-party statement with running balance
- **Reports** — Sale, Purchase, Expense, General Ledger, Trial Balance,
  one reusable table component, each exportable to PDF (jsPDF) or Excel
  (SheetJS/xlsx)
- **Permissions** — admin screen, View/Create/Edit/Approve per page per
  user

Every write (`create_invoice`, `create_expense`, `record_payment`,
`void_invoice`, `void_expense`, `create_party`) still goes through the same
atomic, permission-checking Postgres functions from the schema — the
frontend swap didn't touch that layer at all.

## What's not built yet

Same gaps as before: brand logo upload (the field's there, just needs the
image URLs), a UI button for voiding invoices/expenses (the RPCs exist,
just not wired to a button in Reports yet), and a dedicated Payments
(receipts/against invoices) screen (`record_payment()` is ready, no screen
yet). `recharts` is installed but unused — it's there if you want a trend
chart on the dashboard later, matching the Faraz ERP's use of it.

## Project layout

```
src/
  supabaseClient.js   Supabase client bootstrap (reads VITE_* env vars)
  main.jsx             React root
  index.css             Tailwind + font imports
  App.jsx                everything else: data layer, UI primitives,
                          every screen — ~1,680 lines, one file,
                          matching the Faraz ERP convention
supabase/migrations/    same schema as the Flutter version
```
