import React, { useState, useEffect, useMemo, useCallback, useRef, createContext, useContext } from 'react';
import {
  LayoutDashboard, ShoppingCart, Receipt, ClipboardList, BarChart3, Users, Settings,
  LogOut, Search, Plus, X, Calendar, ChevronRight, FileDown, FileSpreadsheet,
  ArrowUpRight, ArrowDownRight, ShieldCheck, Menu,
} from 'lucide-react';
import jsPDF from 'jspdf';
import autoTable from 'jspdf-autotable';
import * as XLSX from 'xlsx';
import { supabase } from './supabaseClient.js';

/* ============================================================================
 * SKF PolyTex / SKF PolyBags — Trading & Accounting App (web)
 * React + Vite + Tailwind + Supabase, same stack/conventions as the
 * Faraz Sports / SKFnosis ERP. One App.jsx, deployable to Vercel.
 * ============================================================================
 */

// ---------------------------------------------------------------------------
// Theme — SKF Blue (carried over from skfpolytex.xyz) as the one accent color.
// ---------------------------------------------------------------------------
const THEME = {
  blue: '#2F5EFF',
  ink: '#12141C',
  surface: '#F7F8FA',
  line: '#E3E6EC',
  success: '#1E9E6A',
  danger: '#D64545',
  amber: '#C98A1E',
  navBg: '#FFFFFF',
  navTextMuted: '#8A8F9C',
};

const PAGES = [
  { key: 'dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { key: 'entry_sale', label: 'Sale Invoice', icon: ShoppingCart },
  { key: 'entry_purchase', label: 'Purchase Invoice', icon: ClipboardList },
  { key: 'entry_expense', label: 'Expense', icon: Receipt },
  { key: 'reports', label: 'Reports', icon: BarChart3 },
  { key: 'party_master', label: 'Party Master', icon: Users },
  { key: 'settings', label: 'Settings', icon: Settings },
];

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------
function formatPkr(amount) {
  const n = Math.round(Math.abs(Number(amount) || 0));
  const withCommas = n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const sign = Number(amount) < 0 ? '-' : '';
  return `Rs ${sign}${withCommas}`;
}

function formatDate(d) {
  if (!d) return '';
  const dt = typeof d === 'string' ? new Date(d) : d;
  return dt.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function toDateInput(d) {
  const dt = typeof d === 'string' ? new Date(d) : d;
  return dt.toISOString().split('T')[0];
}

function startOfMonth() {
  const d = new Date();
  return new Date(d.getFullYear(), d.getMonth(), 1);
}

function cx(...parts) {
  return parts.filter(Boolean).join(' ');
}

// Unit choices per category, per the brief: fabric -> meters/kg, poly bags -> pieces/kg.
function unitOptionsFor(category) {
  return category === 'fabric' ? ['meters', 'kg'] : ['pieces', 'kg'];
}

// ============================================================================
// DATA ACCESS LAYER
// All writes go through the SECURITY DEFINER Postgres functions from the
// migration (create_invoice, create_expense, record_payment, void_invoice,
// void_expense, create_party) — never raw table inserts. See the schema's
// design note for why. Reads use plain selects gated by RLS.
// ============================================================================

async function signInWithUsername(username, password) {
  const { data: email, error: rpcError } = await supabase.rpc('email_for_username', {
    p_username: username,
  });
  if (rpcError) throw rpcError;
  if (!email) throw new Error(`No active account found for "${username}".`);
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

async function fetchProfile(userId) {
  const { data, error } = await supabase.from('profiles').select().eq('id', userId).maybeSingle();
  if (error) throw error;
  return data;
}

async function fetchPermissions(userId, isAdmin) {
  const allPages = PAGES.map((p) => p.key);
  if (isAdmin) {
    const grid = {};
    allPages.forEach((k) => { grid[k] = { can_view: true, can_create: true, can_edit: true, can_approve: true }; });
    return grid;
  }
  const { data, error } = await supabase.from('page_permissions').select().eq('user_id', userId);
  if (error) throw error;
  const grid = {};
  (data || []).forEach((row) => { grid[row.page_key] = row; });
  return grid;
}

async function fetchBrands() {
  const { data, error } = await supabase.from('brand_settings').select().order('brand_key');
  if (error) throw error;
  return data;
}

async function fetchChartOfAccounts() {
  const { data, error } = await supabase.from('chart_of_accounts').select().order('name');
  if (error) throw error;
  return data;
}

async function fetchParties({ search = '', category = null, type = null } = {}) {
  let q = supabase.from('parties').select();
  if (search) q = q.ilike('name', `%${search}%`);
  if (category) q = q.contains('category', [category]);
  if (type) q = q.eq('type', type);
  const { data, error } = await q.order('name').limit(50);
  if (error) throw error;
  return data;
}

async function createParty({ name, type, category, contact, address, openingBalance = 0 }) {
  const { data, error } = await supabase.rpc('create_party', {
    p_name: name,
    p_type: type,
    p_category: category,
    p_contact: contact || null,
    p_address: address || null,
    p_opening_balance: openingBalance,
  });
  if (error) throw error;
  return data;
}

async function fetchDashboardSummary({ from, to, brandKey }) {
  const { data, error } = await supabase.rpc('dashboard_summary', {
    p_from: from, p_to: to, p_brand: brandKey || null,
  });
  if (error) throw error;
  return data?.[0] || { sales: 0, purchase: 0, expenses: 0, profit: 0 };
}

async function createInvoice({ invoiceType, brandKey, category, partyId, invoiceDate, items }) {
  const { data, error } = await supabase.rpc('create_invoice', {
    p_invoice_type: invoiceType,
    p_brand_key: brandKey,
    p_category: category,
    p_party_id: partyId,
    p_invoice_date: invoiceDate,
    p_items: items.map((i) => ({
      quantity: Number(i.quantity) || 0,
      unit: i.unit,
      rate: Number(i.rate) || 0,
      description: i.description || '',
    })),
  });
  if (error) throw error;
  return data;
}

async function voidInvoice(invoiceId, reason) {
  const { error } = await supabase.rpc('void_invoice', { p_invoice_id: invoiceId, p_reason: reason });
  if (error) throw error;
}

async function createExpense({ expenseDate, expenseAccountId, cashBankAccountId, brandKey, description, amount }) {
  const { data, error } = await supabase.rpc('create_expense', {
    p_expense_date: expenseDate,
    p_expense_account_id: expenseAccountId,
    p_cash_bank_account_id: cashBankAccountId,
    p_brand_key: brandKey || null,
    p_description: description,
    p_amount: Number(amount),
  });
  if (error) throw error;
  return data;
}

async function voidExpense(expenseId, reason) {
  const { error } = await supabase.rpc('void_expense', { p_expense_id: expenseId, p_reason: reason });
  if (error) throw error;
}

async function recordPayment({ paymentDate, partyId, direction, amount, method, cashBankAccountId, linkedInvoiceId, notes }) {
  const { data, error } = await supabase.rpc('record_payment', {
    p_payment_date: paymentDate,
    p_party_id: partyId,
    p_direction: direction,
    p_amount: Number(amount),
    p_method: method,
    p_cash_bank_account_id: cashBankAccountId,
    p_linked_invoice_id: linkedInvoiceId || null,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

async function fetchInvoices({ invoiceType, from, to, brandKey, partyId }) {
  let q = supabase.from('invoices').select('*, parties(name)').eq('invoice_type', invoiceType)
    .gte('invoice_date', from).lte('invoice_date', to);
  if (brandKey) q = q.eq('brand_key', brandKey);
  if (partyId) q = q.eq('party_id', partyId);
  const { data, error } = await q.order('invoice_date');
  if (error) throw error;
  return data;
}

async function fetchExpenses({ from, to, brandKey }) {
  let q = supabase.from('expenses')
    .select('*, chart_of_accounts!expenses_expense_account_id_fkey(name)')
    .gte('expense_date', from).lte('expense_date', to);
  if (brandKey) q = q.eq('brand_key', brandKey);
  const { data, error } = await q.order('expense_date');
  if (error) throw error;
  return data;
}

async function fetchGeneralLedger({ from, to, partyId }) {
  let q = supabase.from('ledger_entries').select('*, chart_of_accounts(name), parties(name)')
    .gte('entry_date', from).lte('entry_date', to);
  if (partyId) q = q.eq('party_id', partyId);
  const { data, error } = await q.order('entry_date');
  if (error) throw error;
  return data;
}

async function fetchTrialBalance() {
  const { data, error } = await supabase.from('v_trial_balance').select().order('type');
  if (error) throw error;
  return data;
}

async function fetchPartyStatement(partyId) {
  const { data, error } = await supabase.from('ledger_entries')
    .select('*, chart_of_accounts(name), parties(name)').eq('party_id', partyId).order('entry_date');
  if (error) throw error;
  return data;
}

async function fetchAllProfiles() {
  const { data, error } = await supabase.from('profiles').select().order('full_name');
  if (error) throw error;
  return data;
}

async function savePagePermissions(userId, grid) {
  const rows = PAGES.map((p) => ({
    user_id: userId,
    page_key: p.key,
    can_view: !!grid[p.key]?.can_view,
    can_create: !!grid[p.key]?.can_create,
    can_edit: !!grid[p.key]?.can_edit,
    can_approve: !!grid[p.key]?.can_approve,
  }));
  const { error } = await supabase.from('page_permissions').upsert(rows, { onConflict: 'user_id,page_key' });
  if (error) throw error;
}

// ============================================================================
// UI PRIMITIVES
// ============================================================================

function Spinner({ size = 20 }) {
  return (
    <div
      className="animate-spin rounded-full border-2 border-gray-200"
      style={{ width: size, height: size, borderTopColor: THEME.blue }}
    />
  );
}

function Card({ children, className = '', ...props }) {
  return (
    <div
      className={cx('bg-white rounded-xl border', className)}
      style={{ borderColor: THEME.line }}
      {...props}
    >
      {children}
    </div>
  );
}

function Button({ children, variant = 'primary', className = '', icon: Icon, loading, ...props }) {
  const base = 'inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-sm font-medium transition disabled:opacity-50 disabled:cursor-not-allowed';
  const variants = {
    primary: 'text-white hover:opacity-90',
    outline: 'border bg-white hover:bg-gray-50',
    ghost: 'hover:bg-gray-100',
    danger: 'text-white hover:opacity-90',
  };
  const style =
    variant === 'primary' ? { backgroundColor: THEME.blue }
    : variant === 'danger' ? { backgroundColor: THEME.danger }
    : variant === 'outline' ? { borderColor: THEME.line }
    : {};
  return (
    <button className={cx(base, variants[variant], className)} style={style} {...props}>
      {loading ? <Spinner size={16} /> : Icon ? <Icon size={16} /> : null}
      {children}
    </button>
  );
}

function Input({ label, className = '', ...props }) {
  return (
    <label className="block">
      {label && <span className="block text-sm font-medium text-gray-700 mb-1">{label}</span>}
      <input
        className={cx(
          'w-full rounded-lg border px-3 py-2.5 text-sm outline-none focus:ring-2 focus:ring-offset-0',
          className
        )}
        style={{ borderColor: THEME.line, '--tw-ring-color': THEME.blue }}
        {...props}
      />
    </label>
  );
}

function Select({ label, children, className = '', ...props }) {
  return (
    <label className="block">
      {label && <span className="block text-sm font-medium text-gray-700 mb-1">{label}</span>}
      <select
        className={cx('w-full rounded-lg border px-3 py-2.5 text-sm outline-none bg-white', className)}
        style={{ borderColor: THEME.line }}
        {...props}
      >
        {children}
      </select>
    </label>
  );
}

function Badge({ children, tone = 'neutral' }) {
  const tones = {
    neutral: { bg: '#F1F2F5', fg: THEME.ink },
    success: { bg: '#E7F6EF', fg: THEME.success },
    danger: { bg: '#FBEAEA', fg: THEME.danger },
    amber: { bg: '#FBF1E1', fg: THEME.amber },
  };
  const t = tones[tone] || tones.neutral;
  return (
    <span
      className="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
      style={{ backgroundColor: t.bg, color: t.fg }}
    >
      {children}
    </span>
  );
}

function EmptyState({ children }) {
  return <div className="text-center py-16 text-gray-500 text-sm">{children}</div>;
}

function Modal({ open, onClose, title, children, width = 420 }) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="bg-white rounded-xl shadow-xl w-full" style={{ maxWidth: width }}>
        <div className="flex items-center justify-between px-5 py-4 border-b" style={{ borderColor: THEME.line }}>
          <h3 className="font-display font-semibold text-lg">{title}</h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-700">
            <X size={20} />
          </button>
        </div>
        <div className="p-5">{children}</div>
      </div>
    </div>
  );
}

function useToast() {
  const [toast, setToast] = useState(null);
  const show = useCallback((message, tone = 'neutral') => {
    setToast({ message, tone });
    setTimeout(() => setToast(null), 3500);
  }, []);
  const ToastHost = () =>
    toast ? (
      <div className="fixed bottom-5 right-5 z-50">
        <div
          className="rounded-lg px-4 py-3 text-sm text-white shadow-lg"
          style={{ backgroundColor: toast.tone === 'danger' ? THEME.danger : THEME.ink }}
        >
          {toast.message}
        </div>
      </div>
    ) : null;
  return { show, ToastHost };
}

// ============================================================================
// PARTY PICKER — searchable combobox with inline "add new party"
// ============================================================================

function PartyPicker({ type, category, value, onChange, resetKey }) {
  const [query, setQuery] = useState(value?.name || '');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const boxRef = useRef(null);

  useEffect(() => {
    setQuery(value?.name || '');
  }, [resetKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    let alive = true;
    setLoading(true);
    fetchParties({ search: query, category, type })
      .then((rows) => { if (alive) setResults(rows); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [query, category, type]);

  useEffect(() => {
    function onDocClick(e) {
      if (boxRef.current && !boxRef.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, []);

  return (
    <div className="relative" ref={boxRef}>
      <Input
        label={type === 'customer' ? 'Customer' : 'Supplier'}
        placeholder={`Search ${type}s…`}
        value={query}
        onFocus={() => setOpen(true)}
        onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
      />
      {open && (
        <div className="absolute z-40 mt-1 w-full bg-white rounded-lg border shadow-lg max-h-64 overflow-auto" style={{ borderColor: THEME.line }}>
          {loading && <div className="p-3 text-sm text-gray-500">Searching…</div>}
          {!loading && results.map((p) => (
            <button
              key={p.id}
              type="button"
              className="w-full text-left px-3 py-2 hover:bg-gray-50 text-sm"
              onClick={() => { onChange(p); setQuery(p.name); setOpen(false); }}
            >
              <div className="font-medium">{p.name}</div>
              {p.contact && <div className="text-xs text-gray-500">{p.contact}</div>}
            </button>
          ))}
          {!loading && query.trim() && (
            <button
              type="button"
              className="w-full text-left px-3 py-2 hover:bg-gray-50 text-sm flex items-center gap-2"
              style={{ color: THEME.blue }}
              onClick={() => { setOpen(false); setShowAdd(true); }}
            >
              <Plus size={14} /> Add "{query.trim()}" as new {type}
            </button>
          )}
        </div>
      )}
      <AddPartyModal
        open={showAdd}
        onClose={() => setShowAdd(false)}
        type={type}
        category={category}
        prefillName={query}
        onCreated={(p) => { onChange(p); setQuery(p.name); setShowAdd(false); }}
      />
    </div>
  );
}

function AddPartyModal({ open, onClose, type, category, prefillName, onCreated }) {
  const [name, setName] = useState(prefillName || '');
  const [contact, setContact] = useState('');
  const [address, setAddress] = useState('');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => { setName(prefillName || ''); }, [prefillName, open]);

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      const id = await createParty({ name: name.trim(), type, category: [category], contact, address });
      onCreated({ id, name: name.trim(), type, category: [category], contact, address });
    } catch (e) {
      show(`Could not add party: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`New ${type === 'customer' ? 'Customer' : 'Supplier'}`}>
      <div className="space-y-3">
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        <Input label="Phone / contact (optional)" value={contact} onChange={(e) => setContact(e.target.value)} />
        <Input label="Address (optional)" value={address} onChange={(e) => setAddress(e.target.value)} />
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} loading={saving}>Add</Button>
        </div>
      </div>
      <ToastHost />
    </Modal>
  );
}

// ============================================================================
// BRAND TABS
// ============================================================================

function BrandTabs({ brands, value, onChange, allowAll = false }) {
  return (
    <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
      {allowAll && (
        <button
          type="button"
          onClick={() => onChange(null)}
          className="px-3 py-1.5 rounded-md text-sm font-medium transition"
          style={!value ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
        >
          All brands
        </button>
      )}
      {brands.map((b) => (
        <button
          key={b.brand_key}
          type="button"
          onClick={() => onChange(b)}
          className="px-3 py-1.5 rounded-md text-sm font-medium transition"
          style={value?.brand_key === b.brand_key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
        >
          {b.display_name}
        </button>
      ))}
    </div>
  );
}

// ============================================================================
// EXPORT — one PDF/Excel exporter reused by every report screen.
// ============================================================================

function exportPdf({ title, brandLabel, columns, rows, totalsRow }) {
  const doc = new jsPDF();
  doc.setFontSize(14);
  doc.text(brandLabel || 'SKF PolyTex / SKF PolyBags', 14, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(title, 14, 23);
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });
  autoTable(doc, {
    startY: 30,
    head: [columns],
    body: rows,
    foot: totalsRow ? [totalsRow] : undefined,
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    footStyles: { fillColor: [247, 248, 250], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 8.5, cellPadding: 3 },
  });
  doc.save(`${slug(title)}.pdf`);
}

function exportExcel({ title, columns, rows }) {
  const ws = XLSX.utils.aoa_to_sheet([columns, ...rows]);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, 'Report');
  XLSX.writeFile(wb, `${slug(title)}.xlsx`);
}

function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
}

function ReportFilterBar({ from, to, onFromChange, onToChange, children }) {
  return (
    <div className="flex flex-wrap items-end gap-3 mb-4">
      <Input type="date" label="From" value={from} onChange={(e) => onFromChange(e.target.value)} />
      <Input type="date" label="To" value={to} onChange={(e) => onToChange(e.target.value)} />
      {children}
    </div>
  );
}

function ReportTable({ title, brandLabel, columns, rows, totalsRow }) {
  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <span className="text-sm text-gray-500">{rows.length} row{rows.length === 1 ? '' : 's'}</span>
        <div className="flex gap-2">
          <Button
            variant="outline"
            icon={FileDown}
            disabled={rows.length === 0}
            onClick={() => exportPdf({ title, brandLabel, columns, rows, totalsRow })}
          >
            PDF
          </Button>
          <Button
            variant="outline"
            icon={FileSpreadsheet}
            disabled={rows.length === 0}
            onClick={() => exportExcel({ title, columns, rows })}
          >
            Excel
          </Button>
        </div>
      </div>
      {rows.length === 0 ? (
        <EmptyState>No records in this range.</EmptyState>
      ) : (
        <Card className="overflow-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ backgroundColor: THEME.surface }}>
                {columns.map((c) => (
                  <th key={c} className="text-left font-medium px-4 py-2.5 whitespace-nowrap">{c}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i} className="border-t" style={{ borderColor: THEME.line }}>
                  {r.map((c, j) => (
                    <td key={j} className="px-4 py-2.5 whitespace-nowrap">{c}</td>
                  ))}
                </tr>
              ))}
              {totalsRow && (
                <tr className="border-t font-semibold" style={{ borderColor: THEME.line, backgroundColor: THEME.surface }}>
                  {totalsRow.map((c, j) => (
                    <td key={j} className="px-4 py-2.5 whitespace-nowrap">{c}</td>
                  ))}
                </tr>
              )}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  );
}

// ============================================================================
// AUTH — session, profile, and permission grid in one context.
// ============================================================================

const AuthContext = createContext(null);
function useAuth() {
  return useContext(AuthContext);
}

function AuthProvider({ children }) {
  const [session, setSession] = useState(undefined); // undefined = not checked yet
  const [profile, setProfile] = useState(null);
  const [permissions, setPermissions] = useState({});
  const [loadingProfile, setLoadingProfile] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, sess) => setSession(sess));
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!session) {
      setProfile(null);
      setPermissions({});
      return;
    }
    let alive = true;
    setLoadingProfile(true);
    fetchProfile(session.user.id)
      .then(async (p) => {
        if (!alive) return;
        setProfile(p);
        if (p) {
          const grid = await fetchPermissions(p.id, p.is_admin);
          if (alive) setPermissions(grid);
        }
      })
      .finally(() => { if (alive) setLoadingProfile(false); });
    return () => { alive = false; };
  }, [session]);

  const visiblePages = useMemo(
    () => PAGES.filter((p) => permissions[p.key]?.can_view).map((p) => p.key),
    [permissions]
  );

  const value = {
    session,
    profile,
    permissions,
    visiblePages,
    loadingProfile,
    signOut: () => supabase.auth.signOut(),
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

// ============================================================================
// LOGIN SCREEN
// ============================================================================

function LoginScreen() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  async function submit(e) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await signInWithUsername(username.trim(), password);
    } catch (err) {
      setError(err.message || 'Could not sign in.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center p-6">
      <form onSubmit={submit} className="w-full max-w-sm">
        <div className="flex flex-col items-center mb-8 text-center">
          <div className="w-12 h-12 rounded-xl flex items-center justify-center mb-3" style={{ backgroundColor: THEME.blue }}>
            <ShieldCheck className="text-white" size={24} />
          </div>
          <h1 className="font-display font-bold text-xl">SKF PolyTex &middot; SKF PolyBags</h1>
          <p className="text-sm text-gray-500 mt-1">Sign in to the ERP</p>
        </div>
        <div className="space-y-3">
          <Input label="Username" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus required />
          <Input label="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          {error && <p className="text-sm" style={{ color: THEME.danger }}>{error}</p>}
          <Button type="submit" className="w-full mt-2" loading={loading}>Sign in</Button>
        </div>
      </form>
    </div>
  );
}

// ============================================================================
// APP SHELL — sidebar nav built from the signed-in user's visible pages.
// ============================================================================

function AppShell() {
  const { profile, visiblePages, signOut } = useAuth();
  const [current, setCurrent] = useState(null);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  useEffect(() => {
    if (!current && visiblePages.length > 0) setCurrent(visiblePages[0]);
    if (current && !visiblePages.includes(current) && visiblePages.length > 0) setCurrent(visiblePages[0]);
  }, [visiblePages]); // eslint-disable-line react-hooks/exhaustive-deps

  const pages = PAGES.filter((p) => visiblePages.includes(p.key));
  const activePage = PAGES.find((p) => p.key === current);

  if (visiblePages.length === 0) {
    return (
      <div className="min-h-screen flex flex-col">
        <TopBar profile={profile} onSignOut={signOut} pageLabel="" />
        <div className="flex-1 flex items-center justify-center text-center p-6 text-gray-500 text-sm">
          Your account has no pages enabled yet.<br />Ask an admin to grant access under Settings.
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex">
      <aside className="hidden md:flex md:flex-col w-60 border-r bg-white" style={{ borderColor: THEME.line }}>
        <SidebarContent pages={pages} current={current} onSelect={setCurrent} />
      </aside>

      {mobileNavOpen && (
        <div className="fixed inset-0 z-40 md:hidden">
          <div className="absolute inset-0 bg-black/40" onClick={() => setMobileNavOpen(false)} />
          <aside className="absolute left-0 top-0 bottom-0 w-64 bg-white">
            <SidebarContent pages={pages} current={current} onSelect={(k) => { setCurrent(k); setMobileNavOpen(false); }} />
          </aside>
        </div>
      )}

      <div className="flex-1 flex flex-col min-w-0">
        <TopBar
          profile={profile}
          onSignOut={signOut}
          pageLabel={activePage?.label}
          onMenuClick={() => setMobileNavOpen(true)}
        />
        <main className="flex-1 p-4 md:p-6 overflow-auto">
          <PageRouter page={current} />
        </main>
      </div>
    </div>
  );
}

function SidebarContent({ pages, current, onSelect }) {
  return (
    <>
      <div className="px-5 py-5 border-b" style={{ borderColor: THEME.line }}>
        <div className="font-display font-bold">SKF ERP</div>
        <div className="text-xs" style={{ color: THEME.navTextMuted }}>PolyTex &middot; PolyBags</div>
      </div>
      <nav className="flex-1 p-3 space-y-1">
        {pages.map((p) => {
          const Icon = p.icon;
          const active = current === p.key;
          return (
            <button
              key={p.key}
              onClick={() => onSelect(p.key)}
              className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition"
              style={active ? { backgroundColor: '#EEF2FF', color: THEME.blue } : { color: THEME.ink }}
            >
              <Icon size={18} />
              {p.label}
            </button>
          );
        })}
      </nav>
    </>
  );
}

function TopBar({ profile, onSignOut, pageLabel, onMenuClick }) {
  return (
    <header className="h-16 border-b bg-white flex items-center justify-between px-4 md:px-6" style={{ borderColor: THEME.line }}>
      <div className="flex items-center gap-3">
        {onMenuClick && (
          <button className="md:hidden text-gray-500" onClick={onMenuClick}>
            <Menu size={22} />
          </button>
        )}
        <span className="font-display font-semibold">SKF ERP</span>
        {pageLabel && <span className="text-gray-400 hidden sm:inline">/ {pageLabel}</span>}
      </div>
      <div className="flex items-center gap-3">
        {profile && <span className="text-sm text-gray-600 hidden sm:inline">{profile.full_name}</span>}
        <button onClick={onSignOut} className="text-gray-400 hover:text-gray-700" title="Sign out">
          <LogOut size={18} />
        </button>
      </div>
    </header>
  );
}

function PageRouter({ page }) {
  switch (page) {
    case 'dashboard': return <DashboardScreen />;
    case 'entry_sale': return <InvoiceEntryScreen invoiceType="sale" />;
    case 'entry_purchase': return <InvoiceEntryScreen invoiceType="purchase" />;
    case 'entry_expense': return <ExpenseScreen />;
    case 'reports': return <ReportsScreen />;
    case 'party_master': return <PartyMasterScreen />;
    case 'settings': return <SettingsScreen />;
    default: return null;
  }
}

// ============================================================================
// DASHBOARD
// ============================================================================

function DashboardScreen() {
  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [brand, setBrand] = useState(null);
  const [brands, setBrands] = useState([]);
  const [summary, setSummary] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => { fetchBrands().then(setBrands); }, []);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    fetchDashboardSummary({ from, to, brandKey: brand?.brand_key })
      .then((s) => { if (alive) setSummary(s); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [from, to, brand]);

  const cards = summary
    ? [
        { label: 'Sales', value: summary.sales, color: THEME.success, icon: ArrowUpRight },
        { label: 'Purchase', value: summary.purchase, color: THEME.danger, icon: ArrowDownRight },
        { label: 'Expenses', value: summary.expenses, color: THEME.amber, icon: ArrowDownRight },
        { label: 'Profit', value: summary.profit, color: summary.profit >= 0 ? THEME.success : THEME.danger, icon: ArrowUpRight, emphasize: true },
      ]
    : [];

  return (
    <div>
      <div className="flex flex-wrap items-end gap-4 mb-6">
        <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />
        <BrandTabs brands={brands} value={brand} onChange={setBrand} allowAll />
      </div>

      {loading ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : (
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          {cards.map((c) => (
            <Card key={c.label} className="p-5">
              <div className="flex items-center justify-between mb-2">
                <span className="text-sm font-medium text-gray-500">{c.label}</span>
                <c.icon size={16} style={{ color: c.color }} />
              </div>
              <div className={cx('font-bold', c.emphasize ? 'text-2xl' : 'text-xl')} style={{ color: c.color }}>
                {formatPkr(c.value)}
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

// ============================================================================
// SALE / PURCHASE INVOICE ENTRY (shared component)
// ============================================================================

function emptyLine(unit) {
  return { quantity: '', unit, rate: '', description: '' };
}

function InvoiceEntryScreen({ invoiceType }) {
  const [brands, setBrands] = useState([]);
  const [brand, setBrand] = useState(null);
  const [party, setParty] = useState(null);
  const [partyResetKey, setPartyResetKey] = useState(0);
  const [date, setDate] = useState(toDateInput(new Date()));
  const [lines, setLines] = useState([]);
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  const partyType = invoiceType === 'sale' ? 'customer' : 'supplier';
  const title = invoiceType === 'sale' ? 'Sale Invoice' : 'Purchase Invoice';

  useEffect(() => {
    fetchBrands().then((rows) => {
      setBrands(rows);
      if (rows.length && !brand) setBrand(rows[0]);
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  function switchBrand(b) {
    setBrand(b);
    setLines([]);
    setParty(null);
    setPartyResetKey((k) => k + 1);
  }

  function addLine() {
    setLines((ls) => [...ls, emptyLine(unitOptionsFor(brand.category)[0])]);
  }
  function updateLine(i, patch) {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  }
  function removeLine(i) {
    setLines((ls) => ls.filter((_, idx) => idx !== i));
  }

  const total = lines.reduce((sum, l) => sum + (Number(l.quantity) || 0) * (Number(l.rate) || 0), 0);

  async function save() {
    if (!brand || !party || lines.length === 0) {
      show('Pick a brand, a party, and add at least one line item.', 'danger');
      return;
    }
    setSaving(true);
    try {
      const id = await createInvoice({
        invoiceType, brandKey: brand.brand_key, category: brand.category,
        partyId: party.id, invoiceDate: date, items: lines,
      });
      show(`Saved. Invoice ${id} created.`);
      setLines([]);
      setParty(null);
      setPartyResetKey((k) => k + 1);
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  if (!brand) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const units = unitOptionsFor(brand.category);

  return (
    <div className="max-w-4xl">
      <h2 className="font-display font-semibold text-lg mb-4">{title}</h2>
      <div className="flex flex-wrap items-end gap-4 mb-5">
        <BrandTabs brands={brands} value={brand} onChange={switchBrand} />
        <Input type="date" label="Date" value={date} onChange={(e) => setDate(e.target.value)} />
      </div>

      <div className="mb-5 max-w-md">
        <PartyPicker type={partyType} category={brand.category} value={party} onChange={setParty} resetKey={partyResetKey} />
      </div>

      <div className="flex items-center justify-between mb-2">
        <h3 className="font-medium text-sm text-gray-700">Line items</h3>
        <Button variant="ghost" icon={Plus} onClick={addLine}>Add line</Button>
      </div>

      {lines.length === 0 ? (
        <Card className="p-6 text-sm text-gray-500">No line items yet — click "Add line" to start.</Card>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {lines.map((l, i) => (
            <div key={i} className="p-3 flex flex-wrap items-end gap-3">
              <div className="flex-1 min-w-[160px]">
                <Input label="Description" value={l.description} onChange={(e) => updateLine(i, { description: e.target.value })} />
              </div>
              <div className="w-24">
                <Input label="Qty" type="number" value={l.quantity} onChange={(e) => updateLine(i, { quantity: e.target.value })} />
              </div>
              <div className="w-28">
                <Select label="Unit" value={l.unit} onChange={(e) => updateLine(i, { unit: e.target.value })}>
                  {units.map((u) => <option key={u} value={u}>{u}</option>)}
                </Select>
              </div>
              <div className="w-28">
                <Input label="Rate" type="number" value={l.rate} onChange={(e) => updateLine(i, { rate: e.target.value })} />
              </div>
              <div className="w-28 text-right text-sm font-medium pb-2.5">
                {formatPkr((Number(l.quantity) || 0) * (Number(l.rate) || 0))}
              </div>
              <button onClick={() => removeLine(i)} className="text-gray-400 hover:text-red-500 pb-2.5">
                <X size={18} />
              </button>
            </div>
          ))}
        </Card>
      )}

      <div className="flex items-center justify-end gap-2 mt-5 mb-6">
        <span className="text-gray-500">Total:</span>
        <span className="text-xl font-bold" style={{ color: THEME.blue }}>{formatPkr(total)}</span>
      </div>

      <Button onClick={save} loading={saving}>Save {title}</Button>
      <ToastHost />
    </div>
  );
}

// ============================================================================
// EXPENSE ENTRY
// ============================================================================

function ExpenseScreen() {
  const [accounts, setAccounts] = useState([]);
  const [brands, setBrands] = useState([]);
  const [date, setDate] = useState(toDateInput(new Date()));
  const [expenseAccountId, setExpenseAccountId] = useState('');
  const [cashBankAccountId, setCashBankAccountId] = useState('');
  const [brand, setBrand] = useState(null);
  const [description, setDescription] = useState('');
  const [amount, setAmount] = useState('');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    fetchChartOfAccounts().then(setAccounts);
    fetchBrands().then(setBrands);
  }, []);

  const expenseAccounts = accounts.filter((a) => a.type === 'expense');
  const cashBankAccounts = accounts.filter((a) => a.type === 'cash_bank');

  async function save() {
    const amt = Number(amount);
    if (!expenseAccountId || !cashBankAccountId || !amt || amt <= 0) {
      show('Fill in category, account, and a valid amount.', 'danger');
      return;
    }
    setSaving(true);
    try {
      await createExpense({
        expenseDate: date, expenseAccountId, cashBankAccountId,
        brandKey: brand?.brand_key, description, amount: amt,
      });
      show('Expense saved.');
      setDescription('');
      setAmount('');
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="max-w-lg">
      <h2 className="font-display font-semibold text-lg mb-4">Expense</h2>
      <div className="space-y-4">
        <Input type="date" label="Date" value={date} onChange={(e) => setDate(e.target.value)} />
        <Select label="Expense category" value={expenseAccountId} onChange={(e) => setExpenseAccountId(e.target.value)}>
          <option value="">Select…</option>
          {expenseAccounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
        </Select>
        <Select label="Paid from" value={cashBankAccountId} onChange={(e) => setCashBankAccountId(e.target.value)}>
          <option value="">Select…</option>
          {cashBankAccounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
        </Select>
        <div>
          <BrandTabs brands={brands} value={brand} onChange={setBrand} allowAll />
          <p className="text-xs text-gray-500 mt-1.5">"All brands" for general/shared expenses.</p>
        </div>
        <Input label="Description" value={description} onChange={(e) => setDescription(e.target.value)} />
        <Input label="Amount (PKR)" type="number" value={amount} onChange={(e) => setAmount(e.target.value)} />
        <Button onClick={save} loading={saving}>Save Expense</Button>
      </div>
      <ToastHost />
    </div>
  );
}

// ============================================================================
// PARTY MASTER + STATEMENT
// ============================================================================

function PartyMasterScreen() {
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState(null);
  const [parties, setParties] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showAdd, setShowAdd] = useState(false);
  const [selected, setSelected] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    fetchParties({ search }).then((rows) => { if (alive) setParties(rows); }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [search, refreshKey]);

  if (selected) {
    return <PartyStatementView party={selected} onBack={() => setSelected(null)} />;
  }

  const filtered = typeFilter ? parties.filter((p) => p.type === typeFilter) : parties;

  return (
    <div>
      <div className="flex flex-wrap items-end gap-3 mb-5">
        <div className="flex-1 min-w-[220px]">
          <Input label="Search parties" placeholder="Type a name…" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
          {[{ k: null, l: 'All' }, { k: 'customer', l: 'Customers' }, { k: 'supplier', l: 'Suppliers' }].map((opt) => (
            <button
              key={opt.l}
              onClick={() => setTypeFilter(opt.k)}
              className="px-3 py-1.5 rounded-md text-sm font-medium"
              style={typeFilter === opt.k ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {opt.l}
            </button>
          ))}
        </div>
        <Button icon={Plus} onClick={() => setShowAdd(true)}>New party</Button>
      </div>

      {loading ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : filtered.length === 0 ? (
        <EmptyState>No parties found.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {filtered.map((p) => (
            <button
              key={p.id}
              onClick={() => setSelected(p)}
              className="w-full flex items-center gap-3 px-4 py-3 hover:bg-gray-50 text-left"
            >
              <div
                className="w-9 h-9 rounded-full flex items-center justify-center text-sm font-semibold text-white flex-shrink-0"
                style={{ backgroundColor: THEME.blue }}
              >
                {p.name?.[0]?.toUpperCase() || '?'}
              </div>
              <div className="flex-1 min-w-0">
                <div className="font-medium truncate">{p.name}</div>
                <div className="text-xs text-gray-500 truncate">
                  {p.type === 'customer' ? 'Customer' : 'Supplier'} &middot; {(p.category || []).join(', ')}
                  {p.contact ? ` · ${p.contact}` : ''}
                </div>
              </div>
              <ChevronRight size={18} className="text-gray-300 flex-shrink-0" />
            </button>
          ))}
        </Card>
      )}

      <AddPartyFullModal open={showAdd} onClose={() => setShowAdd(false)} onCreated={() => { setShowAdd(false); setRefreshKey((k) => k + 1); }} />
    </div>
  );
}

function AddPartyFullModal({ open, onClose, onCreated }) {
  const [name, setName] = useState('');
  const [type, setType] = useState('customer');
  const [categories, setCategories] = useState(['fabric']);
  const [contact, setContact] = useState('');
  const [address, setAddress] = useState('');
  const [opening, setOpening] = useState('0');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  function toggleCategory(c) {
    setCategories((cs) => (cs.includes(c) ? cs.filter((x) => x !== c) : [...cs, c]));
  }

  async function submit() {
    if (!name.trim() || categories.length === 0) {
      show('Enter a name and pick at least one category.', 'danger');
      return;
    }
    setSaving(true);
    try {
      await createParty({ name: name.trim(), type, category: categories, contact, address, openingBalance: Number(opening) || 0 });
      setName(''); setContact(''); setAddress(''); setOpening('0');
      onCreated();
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="New party" width={440}>
      <div className="space-y-3">
        <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
          {['customer', 'supplier'].map((t) => (
            <button
              key={t}
              onClick={() => setType(t)}
              className="px-3 py-1.5 rounded-md text-sm font-medium capitalize"
              style={type === t ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {t}
            </button>
          ))}
        </div>
        <div className="flex gap-2">
          {[{ k: 'fabric', l: 'Fabric' }, { k: 'polybags', l: 'Poly Bags' }].map((c) => (
            <button
              key={c.k}
              onClick={() => toggleCategory(c.k)}
              className="px-3 py-1.5 rounded-full text-sm border"
              style={categories.includes(c.k) ? { backgroundColor: '#EEF2FF', color: THEME.blue, borderColor: THEME.blue } : { borderColor: THEME.line }}
            >
              {c.l}
            </button>
          ))}
        </div>
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
        <Input label="Contact" value={contact} onChange={(e) => setContact(e.target.value)} />
        <Input label="Address" value={address} onChange={(e) => setAddress(e.target.value)} />
        <Input
          label="Opening balance (PKR)"
          type="number"
          value={opening}
          onChange={(e) => setOpening(e.target.value)}
        />
        <p className="text-xs text-gray-500 -mt-2">Positive = they owe us. Leave 0 if none.</p>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} loading={saving}>Save</Button>
        </div>
      </div>
      <ToastHost />
    </Modal>
  );
}

function PartyStatementView({ party, onBack }) {
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    fetchPartyStatement(party.id).then((rows) => { if (alive) setEntries(rows); }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [party.id]);

  let running = 0;
  const rows = entries.map((e) => {
    running += Number(e.debit) - Number(e.credit);
    return [
      formatDate(e.entry_date),
      referenceLabel(e.reference_type),
      e.debit > 0 ? formatPkr(e.debit) : '',
      e.credit > 0 ? formatPkr(e.credit) : '',
      formatPkr(running),
    ];
  });

  return (
    <div>
      <button onClick={onBack} className="text-sm text-gray-500 mb-4 hover:text-gray-800">&larr; Back to parties</button>
      <h2 className="font-display font-semibold text-lg mb-4">{party.name}</h2>

      {loading ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : (
        <>
          <Card className="p-4 mb-5" style={{ backgroundColor: running >= 0 ? '#E7F6EF' : '#FBEAEA' }}>
            <div className="flex items-center gap-2">
              {running >= 0 ? <ArrowDownRight size={18} style={{ color: THEME.success }} /> : <ArrowUpRight size={18} style={{ color: THEME.danger }} />}
              <span className="font-medium">
                {running >= 0 ? `${party.name} owes ${formatPkr(running)}` : `We owe ${party.name} ${formatPkr(-running)}`}
              </span>
            </div>
          </Card>
          <ReportTable title={`${party.name} — Statement`} columns={['Date', 'Reference', 'Debit', 'Credit', 'Balance']} rows={rows} />
        </>
      )}
    </div>
  );
}

function referenceLabel(type) {
  switch (type) {
    case 'invoice': return 'Invoice';
    case 'payment': return 'Payment';
    case 'opening_balance': return 'Opening balance';
    case 'void': return 'Void / reversal';
    default: return type;
  }
}

// ============================================================================
// REPORTS — Sale, Purchase, Expense, General Ledger, Trial Balance
// ============================================================================

const REPORT_TYPES = [
  { key: 'sale', label: 'Sale Report' },
  { key: 'purchase', label: 'Purchase Report' },
  { key: 'expense', label: 'Expense Report' },
  { key: 'ledger', label: 'General Ledger' },
  { key: 'trial_balance', label: 'Trial Balance' },
];

function ReportsScreen() {
  const [type, setType] = useState('sale');
  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [brand, setBrand] = useState(null);
  const [brands, setBrands] = useState([]);

  useEffect(() => { fetchBrands().then(setBrands); }, []);

  return (
    <div>
      <div className="flex flex-wrap gap-2 mb-5">
        {REPORT_TYPES.map((t) => (
          <button
            key={t.key}
            onClick={() => setType(t.key)}
            className="px-3 py-1.5 rounded-full text-sm font-medium border"
            style={type === t.key ? { backgroundColor: THEME.blue, color: 'white', borderColor: THEME.blue } : { borderColor: THEME.line }}
          >
            {t.label}
          </button>
        ))}
      </div>

      {type !== 'trial_balance' && (
        <div className="flex flex-wrap items-end gap-4 mb-5">
          <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />
          {type !== 'expense' && <BrandTabs brands={brands} value={brand} onChange={setBrand} allowAll />}
        </div>
      )}

      {type === 'sale' && <InvoiceReport invoiceType="sale" from={from} to={to} brand={brand} />}
      {type === 'purchase' && <InvoiceReport invoiceType="purchase" from={from} to={to} brand={brand} />}
      {type === 'expense' && <ExpenseReport from={from} to={to} />}
      {type === 'ledger' && <LedgerReport from={from} to={to} brand={brand} />}
      {type === 'trial_balance' && <TrialBalanceReport />}
    </div>
  );
}

function InvoiceReport({ invoiceType, from, to, brand }) {
  const [rows, setRows] = useState(null);
  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchInvoices({ invoiceType, from, to, brandKey: brand?.brand_key }).then((r) => { if (alive) setRows(r); });
    return () => { alive = false; };
  }, [invoiceType, from, to, brand]);

  if (rows === null) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const total = rows.reduce((s, r) => s + Number(r.total_amount), 0);
  const table = rows.map((r) => [
    r.invoice_no, formatDate(r.invoice_date), r.parties?.name || '',
    r.brand_key === 'skf_polytex' ? 'PolyTex' : 'PolyBags',
    formatPkr(r.total_amount), r.status,
  ]);

  return (
    <ReportTable
      title={invoiceType === 'sale' ? 'Sale Report' : 'Purchase Report'}
      brandLabel={brand?.display_name}
      columns={['Invoice #', 'Date', 'Party', 'Brand', 'Amount', 'Status']}
      rows={table}
      totalsRow={['', '', '', 'Total', formatPkr(total), '']}
    />
  );
}

function ExpenseReport({ from, to }) {
  const [rows, setRows] = useState(null);
  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchExpenses({ from, to }).then((r) => { if (alive) setRows(r); });
    return () => { alive = false; };
  }, [from, to]);

  if (rows === null) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const total = rows.reduce((s, r) => s + Number(r.amount), 0);
  const table = rows.map((r) => [
    formatDate(r.expense_date), r.chart_of_accounts?.name || '', r.description || '', formatPkr(r.amount), r.status,
  ]);

  return (
    <ReportTable
      title="Expense Report"
      columns={['Date', 'Category', 'Description', 'Amount', 'Status']}
      rows={table}
      totalsRow={['', '', 'Total', formatPkr(total), '']}
    />
  );
}

function LedgerReport({ from, to, brand }) {
  const [rows, setRows] = useState(null);
  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchGeneralLedger({ from, to }).then((r) => { if (alive) setRows(r); });
    return () => { alive = false; };
  }, [from, to]);

  if (rows === null) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const table = rows.map((r) => [
    formatDate(r.entry_date), r.chart_of_accounts?.name || '', r.parties?.name || '',
    r.debit > 0 ? formatPkr(r.debit) : '', r.credit > 0 ? formatPkr(r.credit) : '',
  ]);

  return (
    <ReportTable title="General Ledger" brandLabel={brand?.display_name} columns={['Date', 'Account', 'Party', 'Debit', 'Credit']} rows={table} />
  );
}

function TrialBalanceReport() {
  const [rows, setRows] = useState(null);
  useEffect(() => { fetchTrialBalance().then(setRows); }, []);

  if (rows === null) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const debit = rows.reduce((s, r) => s + Number(r.total_debit), 0);
  const credit = rows.reduce((s, r) => s + Number(r.total_credit), 0);
  const table = rows.map((r) => [r.name, r.type, formatPkr(r.total_debit), formatPkr(r.total_credit), formatPkr(r.balance)]);

  return (
    <ReportTable
      title="Trial Balance"
      columns={['Account', 'Type', 'Debit', 'Credit', 'Balance']}
      rows={table}
      totalsRow={['Total', '', formatPkr(debit), formatPkr(credit), formatPkr(debit - credit)]}
    />
  );
}

// ============================================================================
// SETTINGS + PERMISSIONS (admin only)
// ============================================================================

function SettingsScreen() {
  const { profile } = useAuth();
  const [showPermissions, setShowPermissions] = useState(false);

  if (showPermissions) return <PermissionsScreen onBack={() => setShowPermissions(false)} />;

  return (
    <div className="max-w-xl space-y-4">
      <Card className="p-4 flex items-center gap-3">
        <div
          className="w-10 h-10 rounded-full flex items-center justify-center text-white font-semibold flex-shrink-0"
          style={{ backgroundColor: THEME.blue }}
        >
          {profile?.full_name?.[0]?.toUpperCase() || '?'}
        </div>
        <div>
          <div className="font-medium">{profile?.full_name}</div>
          <div className="text-xs text-gray-500">@{profile?.username} &middot; {profile?.is_admin ? 'Admin' : 'Standard user'}</div>
        </div>
      </Card>

      {profile?.is_admin && (
        <button
          onClick={() => setShowPermissions(true)}
          className="w-full text-left"
        >
          <Card className="p-4 flex items-center justify-between hover:bg-gray-50">
            <div className="flex items-center gap-3">
              <ShieldCheck size={20} style={{ color: THEME.blue }} />
              <div>
                <div className="font-medium">User permissions</div>
                <div className="text-xs text-gray-500">Grant View / Create / Edit / Approve per page, per user</div>
              </div>
            </div>
            <ChevronRight size={18} className="text-gray-300" />
          </Card>
        </button>
      )}
    </div>
  );
}

function PermissionsScreen({ onBack }) {
  const [profiles, setProfiles] = useState([]);
  const [selectedId, setSelectedId] = useState('');
  const [grid, setGrid] = useState({});
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => { fetchAllProfiles().then(setProfiles); }, []);

  const selected = profiles.find((p) => p.id === selectedId);

  useEffect(() => {
    if (!selectedId) return;
    let alive = true;
    setLoading(true);
    supabase.from('page_permissions').select().eq('user_id', selectedId).then(({ data }) => {
      if (!alive) return;
      const g = {};
      PAGES.forEach((p) => { g[p.key] = { can_view: false, can_create: false, can_edit: false, can_approve: false }; });
      (data || []).forEach((row) => { g[row.page_key] = row; });
      setGrid(g);
      setLoading(false);
    });
    return () => { alive = false; };
  }, [selectedId]);

  function toggle(pageKey, field) {
    setGrid((g) => ({ ...g, [pageKey]: { ...g[pageKey], [field]: !g[pageKey]?.[field] } }));
  }

  async function save() {
    setSaving(true);
    try {
      await savePagePermissions(selectedId, grid);
      show(`Permissions saved for ${selected.full_name}.`);
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="max-w-3xl">
      <button onClick={onBack} className="text-sm text-gray-500 mb-4 hover:text-gray-800">&larr; Back to settings</button>
      <h2 className="font-display font-semibold text-lg mb-4">User permissions</h2>

      <div className="max-w-sm mb-4">
        <Select label="User" value={selectedId} onChange={(e) => setSelectedId(e.target.value)}>
          <option value="">Select a user…</option>
          {profiles.map((p) => <option key={p.id} value={p.id}>{p.full_name} (@{p.username})</option>)}
        </Select>
      </div>

      {selected?.is_admin && (
        <p className="text-sm italic text-gray-500 mb-3">This user is an Admin — they bypass page permissions entirely.</p>
      )}

      {selectedId && !loading && (
        <>
          <Card className="overflow-auto mb-4">
            <table className="w-full text-sm">
              <thead>
                <tr style={{ backgroundColor: THEME.surface }}>
                  <th className="text-left px-4 py-2.5">Page</th>
                  <th className="px-4 py-2.5">View</th>
                  <th className="px-4 py-2.5">Create</th>
                  <th className="px-4 py-2.5">Edit</th>
                  <th className="px-4 py-2.5">Approve (void)</th>
                </tr>
              </thead>
              <tbody>
                {PAGES.map((p) => (
                  <tr key={p.key} className="border-t" style={{ borderColor: THEME.line }}>
                    <td className="px-4 py-2.5">{p.label}</td>
                    {['can_view', 'can_create', 'can_edit', 'can_approve'].map((f) => (
                      <td key={f} className="px-4 py-2.5 text-center">
                        <input
                          type="checkbox"
                          checked={!!grid[p.key]?.[f]}
                          onChange={() => toggle(p.key, f)}
                          className="w-4 h-4"
                          style={{ accentColor: THEME.blue }}
                        />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>
          <Button onClick={save} loading={saving}>Save permissions</Button>
        </>
      )}
      {loading && <div className="py-10 flex justify-center"><Spinner /></div>}
      <ToastHost />
    </div>
  );
}

// ============================================================================
// ROOT
// ============================================================================

function AppInner() {
  const { session } = useAuth();
  if (session === undefined) {
    return <div className="min-h-screen flex items-center justify-center"><Spinner size={28} /></div>;
  }
  return session ? <AppShell /> : <LoginScreen />;
}

export default function App() {
  return (
    <AuthProvider>
      <AppInner />
    </AuthProvider>
  );
}
