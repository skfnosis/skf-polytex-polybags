import React, { useState, useEffect, useMemo, useCallback, useRef, createContext, useContext } from 'react';
import {
  LayoutDashboard, ShoppingCart, Receipt, ClipboardList, BarChart3, Users, Settings,
  LogOut, Search, Plus, X, Calendar, ChevronRight, FileDown, FileSpreadsheet,
  ArrowUpRight, ArrowDownRight, ShieldCheck, Menu, AlertTriangle, Wallet, Landmark,
} from 'lucide-react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';
import jsPDF from 'jspdf';
import autoTable from 'jspdf-autotable';
import * as XLSX from 'xlsx';
import { supabase } from './supabaseClient.js';
import logoSkfPolytex from './assets/logo-skf-polytex.png';
import logoSkfPolybags from './assets/logo-skf-polybags.png';

const BRAND_LOGOS = { skf_polytex: logoSkfPolytex, skf_polybags: logoSkfPolybags };

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
  cashGreen: '#0F6B41',
  emerald: '#10B981',
  navBg: '#FFFFFF',
  navTextMuted: '#8A8F9C',
};

const PAGES = [
  { key: 'dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { key: 'entry_sale', label: 'Sales', icon: ShoppingCart },
  { key: 'entry_purchase', label: 'Purchase', icon: ClipboardList },
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

// Purchase/Sales module units: just KG and PCS, per the brief.
function purchaseUnitOptionsFor() {
  return ['KG', 'PCS'];
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

async function fetchItems({ search = '', category = null } = {}) {
  let q = supabase.from('items').select().eq('active', true);
  if (search) q = q.ilike('name', `%${search}%`);
  if (category) q = q.eq('category', category);
  const { data, error } = await q.order('name').limit(50);
  if (error) throw error;
  return data;
}

async function createItem({ name, category, defaultUnit }) {
  const { data, error } = await supabase.rpc('create_item', {
    p_name: name,
    p_category: category,
    p_default_unit: defaultUnit,
  });
  if (error) throw error;
  return data;
}

async function fetchOpenPurchaseOrders(partyId) {
  const { data, error } = await supabase.from('invoices').select('*, parties(name)')
    .eq('invoice_type', 'purchase_order').eq('status', 'posted').eq('party_id', partyId)
    .order('invoice_date', { ascending: false }).limit(20);
  if (error) throw error;
  return data;
}

async function fetchOpenSaleOrders(partyId) {
  const { data, error } = await supabase.from('invoices').select('*, parties(name)')
    .eq('invoice_type', 'sale_order').eq('status', 'posted').eq('party_id', partyId)
    .order('invoice_date', { ascending: false }).limit(20);
  if (error) throw error;
  return data;
}

async function fetchStockBalance() {
  const { data, error } = await supabase.from('v_stock_balance').select('item_id, qty_on_hand');
  if (error) throw error;
  return data || [];
}

async function fetchInvoiceWithItems(invoiceId) {
  const { data: invoice, error } = await supabase.from('invoices').select('*, parties(name)').eq('id', invoiceId).single();
  if (error) throw error;
  const { data: items, error: itemsError } = await supabase.from('invoice_items')
    .select('*, items(name)').eq('invoice_id', invoiceId);
  if (itemsError) throw itemsError;
  return { invoice, items };
}

async function fetchAppSettings() {
  const { data, error } = await supabase.from('app_settings').select().eq('id', 1).maybeSingle();
  if (error) throw error;
  return data || { low_cash_threshold: 0, high_payables_threshold: 0 };
}

async function updateAppSettings({ lowCashThreshold, highPayablesThreshold }) {
  const { error } = await supabase.from('app_settings')
    .update({ low_cash_threshold: lowCashThreshold, high_payables_threshold: highPayablesThreshold, updated_at: new Date().toISOString() })
    .eq('id', 1);
  if (error) throw error;
}

async function fetchAccountLedger(accountId, { from, to } = {}) {
  let q = supabase.from('ledger_entries').select('*, parties(name)').eq('account_id', accountId);
  if (from) q = q.gte('entry_date', from);
  if (to) q = q.lte('entry_date', to);
  const { data, error } = await q.order('entry_date').order('created_at');
  if (error) throw error;
  let running = 0;
  return (data || []).map((r) => {
    running += Number(r.debit) - Number(r.credit);
    return { ...r, running_balance: running };
  });
}

async function fetchCashBankBalances() {
  const { data: accounts, error } = await supabase.from('chart_of_accounts').select().eq('type', 'cash_bank');
  if (error) throw error;
  const { data: balances, error: balError } = await supabase.from('v_trial_balance').select();
  if (balError) throw balError;
  const balanceByAccount = {};
  (balances || []).forEach((b) => { balanceByAccount[b.account_id] = b.balance; });
  return accounts.map((a) => ({ ...a, balance: balanceByAccount[a.id] || 0 }));
}

async function fetchCashFlow({ from, to }) {
  const { data, error } = await supabase.rpc('dashboard_cashflow', { p_from: from, p_to: to });
  if (error) throw error;
  return data?.[0] || { cash_in: 0, cash_out: 0 };
}

async function fetchSalesOverview({ from, to }) {
  const { data, error } = await supabase.rpc('dashboard_sales_overview', { p_from: from, p_to: to });
  if (error) throw error;
  return data || [];
}

async function fetchTopCustomers({ from, to }) {
  const { data, error } = await supabase.rpc('dashboard_top_customers', { p_from: from, p_to: to });
  if (error) throw error;
  return data || [];
}

async function fetchMonthlyProfit({ from, to }) {
  const { data, error } = await supabase.rpc('dashboard_monthly_profit', { p_from: from, p_to: to });
  if (error) throw error;
  return data || [];
}

async function fetchReceivablesOverdue() {
  const { data, error } = await supabase.rpc('dashboard_receivables_overdue');
  if (error) throw error;
  return data?.[0] || { total_receivables: 0, overdue_receivables: 0 };
}

async function fetchPartyBalances({ type, positiveOnly = false } = {}) {
  let q = supabase.from('v_party_balances').select().eq('type', type);
  const { data, error } = await q.order('balance', { ascending: false });
  if (error) throw error;
  return positiveOnly ? (data || []).filter((r) => r.balance > 0) : (data || []);
}

async function fetchPaymentsSummary({ from, to }) {
  const { data, error } = await supabase.from('payments').select('amount, direction')
    .eq('status', 'posted').gte('payment_date', from).lte('payment_date', to);
  if (error) throw error;
  const received = (data || []).filter((p) => p.direction === 'receipt').reduce((s, p) => s + Number(p.amount), 0);
  const made = (data || []).filter((p) => p.direction === 'payment').reduce((s, p) => s + Number(p.amount), 0);
  return { received, made };
}

async function fetchDashboardSummary({ from, to, brandKey }) {
  const { data, error } = await supabase.rpc('dashboard_summary', {
    p_from: from, p_to: to, p_brand: brandKey || null,
  });
  if (error) throw error;
  return data?.[0] || { sales: 0, purchase: 0, expenses: 0, profit: 0 };
}

async function createInvoice({
  invoiceType, brandKey, category, partyId, invoiceDate, items,
  supplierInvoiceNo, linkedOrderId, transport, loading, discount, tax, customerPoNo,
}) {
  const { data, error } = await supabase.rpc('create_invoice', {
    p_invoice_type: invoiceType,
    p_brand_key: brandKey,
    p_category: category,
    p_party_id: partyId,
    p_invoice_date: invoiceDate,
    p_items: items.map((i) => ({
      item_id: i.itemId || null,
      quantity: Number(i.quantity) || 0,
      unit: i.unit,
      rate: Number(i.rate) || 0,
      description: i.description || '',
    })),
    p_supplier_invoice_no: supplierInvoiceNo || null,
    p_linked_order_id: linkedOrderId || null,
    p_transport: Number(transport) || 0,
    p_loading: Number(loading) || 0,
    p_discount: Number(discount) || 0,
    p_tax: Number(tax) || 0,
    p_customer_po_no: customerPoNo || null,
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

async function fetchInvoices({ invoiceType, from, to, brandKey, partyId, invoiceNo, linkedOrderId }) {
  let q = supabase.from('invoices').select('*, parties(name)').eq('invoice_type', invoiceType)
    .gte('invoice_date', from).lte('invoice_date', to);
  if (brandKey) q = q.eq('brand_key', brandKey);
  if (partyId) q = q.eq('party_id', partyId);
  if (invoiceNo) q = q.ilike('invoice_no', `%${invoiceNo}%`);
  if (linkedOrderId) q = q.eq('linked_order_id', linkedOrderId);
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

const Input = React.forwardRef(function Input({ label, className = '', ...props }, ref) {
  return (
    <label className="block">
      {label && <span className="block text-sm font-medium text-gray-700 mb-1">{label}</span>}
      <input
        ref={ref}
        className={cx(
          'w-full rounded-lg border px-3 py-2.5 text-sm outline-none focus:ring-2 focus:ring-offset-0',
          className
        )}
        style={{ borderColor: THEME.line, '--tw-ring-color': THEME.blue }}
        {...props}
      />
    </label>
  );
});

const Select = React.forwardRef(function Select({ label, children, className = '', ...props }, ref) {
  return (
    <label className="block">
      {label && <span className="block text-sm font-medium text-gray-700 mb-1">{label}</span>}
      <select
        ref={ref}
        className={cx('w-full rounded-lg border px-3 py-2.5 text-sm outline-none bg-white', className)}
        style={{ borderColor: THEME.line }}
        {...props}
      >
        {children}
      </select>
    </label>
  );
});

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

function PartyPicker({ type, category, value, onChange, resetKey, inputRef, onEnterNext, openAddSignal, label }) {
  const [query, setQuery] = useState(value?.name || '');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const [highlight, setHighlight] = useState(0);
  const boxRef = useRef(null);

  useEffect(() => {
    setQuery(value?.name || '');
  }, [resetKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    let alive = true;
    setLoading(true);
    fetchParties({ search: query, category, type })
      .then((rows) => { if (alive) { setResults(rows); setHighlight(0); } })
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

  useEffect(() => {
    if (openAddSignal) setShowAdd(true);
  }, [openAddSignal]);

  function pick(p) {
    onChange(p);
    setQuery(p.name);
    setOpen(false);
    onEnterNext?.();
  }

  function handleKeyDown(e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setHighlight((h) => Math.min(h + 1, results.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setHighlight((h) => Math.max(h - 1, 0)); }
    else if (e.key === 'Enter' && onEnterNext) {
      e.preventDefault();
      if (open && results[highlight]) pick(results[highlight]);
      else if (value) onEnterNext();
    } else if (e.key === 'F2') {
      e.preventDefault();
      setOpen(false);
      setShowAdd(true);
    }
  }

  return (
    <div className="relative" ref={boxRef}>
      <Input
        ref={inputRef}
        label={label || (type === 'customer' ? 'Customer' : 'Supplier')}
        placeholder={`Search ${type}s… (F2 to add new)`}
        value={query}
        onFocus={() => setOpen(true)}
        onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
        onKeyDown={handleKeyDown}
      />
      {open && (
        <div className="absolute z-40 mt-1 w-full bg-white rounded-lg border shadow-lg max-h-64 overflow-auto" style={{ borderColor: THEME.line }}>
          {loading && <div className="p-3 text-sm text-gray-500">Searching…</div>}
          {!loading && results.map((p, i) => (
            <button
              key={p.id}
              type="button"
              className={cx('w-full text-left px-3 py-2 text-sm', i === highlight ? 'bg-gray-100' : 'hover:bg-gray-50')}
              onMouseEnter={() => setHighlight(i)}
              onClick={() => pick(p)}
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
        onCreated={(p) => { pick(p); setShowAdd(false); }}
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
// ITEM PICKER — same pattern as PartyPicker, for the dynamic item/quality master.
// ============================================================================

function ItemPicker({ category, value, onChange, resetKey, inputRef, onEnterNext, openAddSignal }) {
  const [query, setQuery] = useState(value?.name || '');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const [highlight, setHighlight] = useState(0);
  const boxRef = useRef(null);

  useEffect(() => {
    setQuery(value?.name || '');
  }, [resetKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    let alive = true;
    setLoading(true);
    fetchItems({ search: query, category })
      .then((rows) => { if (alive) { setResults(rows); setHighlight(0); } })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [query, category]);

  useEffect(() => {
    function onDocClick(e) {
      if (boxRef.current && !boxRef.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, []);

  useEffect(() => {
    if (openAddSignal) setShowAdd(true);
  }, [openAddSignal]);

  function pick(it) {
    onChange(it);
    setQuery(it.name);
    setOpen(false);
    onEnterNext?.();
  }

  function handleKeyDown(e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setHighlight((h) => Math.min(h + 1, results.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setHighlight((h) => Math.max(h - 1, 0)); }
    else if (e.key === 'Enter' && onEnterNext) {
      e.preventDefault();
      if (open && results[highlight]) pick(results[highlight]);
      else if (value) onEnterNext();
    } else if (e.key === 'F3') {
      e.preventDefault();
      setOpen(false);
      setShowAdd(true);
    }
  }

  return (
    <div className="relative" ref={boxRef}>
      <Input
        ref={inputRef}
        label="Item / Quality"
        placeholder="Search items… (F3 to add new)"
        value={query}
        onFocus={() => setOpen(true)}
        onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
        onKeyDown={handleKeyDown}
      />
      {open && (
        <div className="absolute z-40 mt-1 w-full bg-white rounded-lg border shadow-lg max-h-64 overflow-auto" style={{ borderColor: THEME.line }}>
          {loading && <div className="p-3 text-sm text-gray-500">Searching…</div>}
          {!loading && results.map((it, i) => (
            <button
              key={it.id}
              type="button"
              className={cx('w-full text-left px-3 py-2 text-sm', i === highlight ? 'bg-gray-100' : 'hover:bg-gray-50')}
              onMouseEnter={() => setHighlight(i)}
              onClick={() => pick(it)}
            >
              <div className="font-medium">{it.name}</div>
              <div className="text-xs text-gray-500">
                {it.default_unit}{it.last_purchase_rate ? ` · last rate ${formatPkr(it.last_purchase_rate)}` : ''}
              </div>
            </button>
          ))}
          {!loading && query.trim() && (
            <button
              type="button"
              className="w-full text-left px-3 py-2 hover:bg-gray-50 text-sm flex items-center gap-2"
              style={{ color: THEME.blue }}
              onClick={() => { setOpen(false); setShowAdd(true); }}
            >
              <Plus size={14} /> Add "{query.trim()}" as new item
            </button>
          )}
        </div>
      )}
      <AddItemModal
        open={showAdd}
        onClose={() => setShowAdd(false)}
        category={category}
        prefillName={query}
        onCreated={(it) => { pick(it); setShowAdd(false); }}
      />
    </div>
  );
}

function AddItemModal({ open, onClose, category, prefillName, onCreated }) {
  const [name, setName] = useState(prefillName || '');
  const [unit, setUnit] = useState(purchaseUnitOptionsFor(category)[0]);
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => { setName(prefillName || ''); }, [prefillName, open]);
  useEffect(() => { setUnit(purchaseUnitOptionsFor(category)[0]); }, [category, open]);

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      const id = await createItem({ name: name.trim(), category, defaultUnit: unit });
      onCreated({ id, name: name.trim(), category, default_unit: unit });
    } catch (e) {
      show(`Could not add item: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="New item / quality">
      <div className="space-y-3">
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        <Select label="Default unit" value={unit} onChange={(e) => setUnit(e.target.value)}>
          {purchaseUnitOptionsFor(category).map((u) => <option key={u} value={u}>{u}</option>)}
        </Select>
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
          className="px-3 py-1.5 rounded-md text-sm font-medium transition inline-flex items-center gap-1.5"
          style={value?.brand_key === b.brand_key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
        >
          {BRAND_LOGOS[b.brand_key] && (
            <img src={BRAND_LOGOS[b.brand_key]} alt="" className="w-4 h-4 object-contain" />
          )}
          {b.display_name}
        </button>
      ))}
    </div>
  );
}

// ============================================================================
// EXPORT — one PDF/Excel exporter reused by every report screen.
// ============================================================================

async function loadImageAsDataUrl(src) {
  const res = await fetch(src);
  const blob = await res.blob();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

async function exportPdf({ title, brandLabel, brandLogo, columns, rows, totalsRow }) {
  const doc = new jsPDF();
  let textX = 14;
  if (brandLogo) {
    try {
      const dataUrl = await loadImageAsDataUrl(brandLogo);
      doc.addImage(dataUrl, 'PNG', 14, 8, 16, 16);
      textX = 34;
    } catch {
      // fall back to text-only header if the logo can't be loaded
    }
  }
  doc.setFontSize(14);
  doc.text(brandLabel || 'SKF PolyTex / SKF PolyBags', textX, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(title, textX, 23);
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });
  autoTable(doc, {
    startY: brandLogo ? 32 : 30,
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

function ReportTable({ title, brandLabel, brandLogo, columns, rows, totalsRow }) {
  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <span className="text-sm text-gray-500">{rows.length} row{rows.length === 1 ? '' : 's'}</span>
        <div className="flex gap-2">
          <Button
            variant="outline"
            icon={FileDown}
            disabled={rows.length === 0}
            onClick={() => exportPdf({ title, brandLabel, brandLogo, columns, rows, totalsRow })}
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
  // False the instant a session appears, true only once the permissions fetch for
  // THAT session has actually finished (success or failure) — AppInner blocks on
  // this so it never judges "no pages enabled" from the empty initial state.
  const [permissionsReady, setPermissionsReady] = useState(false);
  const [authError, setAuthError] = useState(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, sess) => setSession(sess));
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!session) {
      setProfile(null);
      setPermissions({});
      setAuthError(null);
      setPermissionsReady(true); // signed out: nothing to wait for, LoginScreen renders
      return;
    }
    let alive = true;
    setPermissionsReady(false);
    setAuthError(null);
    fetchProfile(session.user.id)
      .then(async (p) => {
        if (!alive) return;
        setProfile(p);
        if (p) {
          const grid = await fetchPermissions(p.id, p.is_admin);
          if (alive) setPermissions(grid);
        } else {
          setAuthError('No profile row exists for this account (profiles table). Contact an admin.');
        }
      })
      .catch((e) => {
        console.error('Failed to load profile/permissions:', e);
        if (alive) setAuthError(e.message || String(e));
      })
      .finally(() => { if (alive) setPermissionsReady(true); });
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
    permissionsReady,
    authError,
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
          <div className="flex items-center gap-3 mb-3">
            <img src={logoSkfPolytex} alt="SKF PolyTex" className="h-14 w-14 object-contain" />
            <img src={logoSkfPolybags} alt="SKF PolyBags" className="h-14 w-14 object-contain" />
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

const NAV_GROUPS = [
  { label: 'Dashboard', keys: ['dashboard'] },
  { label: 'Entry', keys: ['entry_sale', 'entry_purchase', 'entry_expense'] },
  { label: 'Reports', keys: ['reports'] },
  { label: 'Party Master', keys: ['party_master'] },
  { label: 'Admin', keys: ['settings'] },
];

function AppShell() {
  const { profile, visiblePages, signOut, authError } = useAuth();
  const [current, setCurrent] = useState(null);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  useEffect(() => {
    if (!current && visiblePages.length > 0) setCurrent(visiblePages[0]);
    if (current && !visiblePages.includes(current) && visiblePages.length > 0) setCurrent(visiblePages[0]);
  }, [visiblePages]); // eslint-disable-line react-hooks/exhaustive-deps

  const visibleGroups = NAV_GROUPS
    .map((g) => ({ ...g, keys: g.keys.filter((k) => visiblePages.includes(k)) }))
    .filter((g) => g.keys.length > 0);

  if (visiblePages.length === 0) {
    return (
      <div className="min-h-screen flex flex-col">
        <TopNav profile={profile} onSignOut={signOut} groups={[]} current={current} onSelect={setCurrent} />
        <div className="flex-1 flex items-center justify-center text-center p-6 text-gray-500 text-sm">
          {authError ? (
            <div>
              <p className="font-medium mb-2" style={{ color: THEME.danger }}>Could not load your account.</p>
              <p className="text-xs bg-gray-100 rounded-lg px-3 py-2 inline-block max-w-md break-words">{authError}</p>
            </div>
          ) : (
            <p>Your account has no pages enabled yet.<br />Ask an admin to grant access under Admin.</p>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex flex-col">
      <TopNav
        profile={profile} onSignOut={signOut} groups={visibleGroups}
        current={current} onSelect={setCurrent}
        mobileNavOpen={mobileNavOpen} onMenuClick={() => setMobileNavOpen((v) => !v)}
      />
      <main className="flex-1 p-4 md:p-6 overflow-auto">
        <PageRouter page={current} />
      </main>
    </div>
  );
}

function TopNav({ profile, onSignOut, groups, current, onSelect, mobileNavOpen, onMenuClick }) {
  return (
    <header className="border-b bg-white sticky top-0 z-30" style={{ borderColor: THEME.line }}>
      <div className="h-16 flex items-center justify-between px-4 md:px-6">
        <div className="flex items-center gap-6">
          <div>
            <div className="font-display font-bold leading-tight">SKF ERP</div>
            <div className="text-xs" style={{ color: THEME.navTextMuted }}>PolyTex &middot; PolyBags</div>
          </div>
          <nav className="hidden md:flex items-center gap-1">
            {groups.map((g) => (
              <NavGroupButton key={g.label} group={g} current={current} onSelect={onSelect} />
            ))}
          </nav>
        </div>
        <div className="flex items-center gap-3">
          {profile && <span className="text-sm text-gray-600 hidden sm:inline">{profile.full_name}</span>}
          <button onClick={onSignOut} className="text-gray-400 hover:text-gray-700" title="Sign out">
            <LogOut size={18} />
          </button>
          {groups.length > 0 && (
            <button className="md:hidden text-gray-500" onClick={onMenuClick}>
              <Menu size={22} />
            </button>
          )}
        </div>
      </div>

      {mobileNavOpen && groups.length > 0 && (
        <nav className="md:hidden border-t px-3 py-3 space-y-1" style={{ borderColor: THEME.line }}>
          {groups.flatMap((g) => g.keys.map((k) => {
            const page = PAGES.find((p) => p.key === k);
            const Icon = page.icon;
            const active = current === k;
            return (
              <button
                key={k}
                onClick={() => onSelect(k)}
                className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition"
                style={active ? { backgroundColor: '#EEF2FF', color: THEME.blue } : { color: THEME.ink }}
              >
                <Icon size={18} />
                {g.keys.length > 1 ? `${g.label} — ${page.label}` : page.label}
              </button>
            );
          }))}
        </nav>
      )}
    </header>
  );
}

function NavGroupButton({ group, current, onSelect }) {
  const [open, setOpen] = useState(false);
  const boxRef = useRef(null);
  const pages = group.keys.map((k) => PAGES.find((p) => p.key === k));
  const active = group.keys.includes(current);

  useEffect(() => {
    function onDocClick(e) {
      if (boxRef.current && !boxRef.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, []);

  if (pages.length === 1) {
    return (
      <button
        onClick={() => onSelect(pages[0].key)}
        className="px-3 py-2 rounded-lg text-sm font-medium transition"
        style={active ? { backgroundColor: '#EEF2FF', color: THEME.blue } : { color: THEME.ink }}
      >
        {group.label}
      </button>
    );
  }

  return (
    <div className="relative" ref={boxRef}>
      <button
        onClick={() => setOpen((v) => !v)}
        className="px-3 py-2 rounded-lg text-sm font-medium transition flex items-center gap-1"
        style={active ? { backgroundColor: '#EEF2FF', color: THEME.blue } : { color: THEME.ink }}
      >
        {group.label}
        <ChevronRight size={14} className={cx('transition-transform', open && 'rotate-90')} />
      </button>
      {open && (
        <div className="absolute z-40 mt-1 w-48 bg-white rounded-lg border shadow-lg py-1" style={{ borderColor: THEME.line }}>
          {pages.map((p) => {
            const Icon = p.icon;
            const isActive = current === p.key;
            return (
              <button
                key={p.key}
                onClick={() => { onSelect(p.key); setOpen(false); }}
                className={cx('w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-gray-50', isActive && 'font-medium')}
                style={isActive ? { color: THEME.blue } : { color: THEME.ink }}
              >
                <Icon size={16} />
                {p.label}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function PageRouter({ page }) {
  switch (page) {
    case 'dashboard': return <DashboardScreen />;
    case 'entry_sale': return <SalesModule />;
    case 'entry_purchase': return <PurchaseModule />;
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

// ============================================================================
// DASHBOARD — see the module doc comment in PurchaseModule's section for the
// project's general design conventions. This screen answers, at a glance:
// where is my cash, how much am I making per brand, who hasn't paid me, and
// is money moving fast enough. Every section below maps 1:1 to a numbered
// section in the brief. Sections that depend on data the schema doesn't
// track precisely (overdue aging, stock value) are called out inline.
// ============================================================================

function SectionHeading({ children }) {
  return <h3 className="font-display font-semibold text-sm text-gray-500 uppercase tracking-wide mt-8 mb-3 first:mt-0">{children}</h3>;
}

function StatCard({ title, icon: Icon, color, value, sub, onClick, emphasize, highlight }) {
  const Wrapper = onClick ? 'button' : 'div';
  return (
    <Wrapper onClick={onClick} className={cx('text-left w-full block', onClick && 'cursor-pointer')}>
      <Card
        className={cx('p-4 h-full', onClick && 'hover:shadow-md transition')}
        style={highlight ? { borderColor: THEME.danger, backgroundColor: '#FBEAEA' } : undefined}
      >
        <div className="flex items-center justify-between mb-2">
          <span className="text-sm font-medium text-gray-500">{title}</span>
          {Icon && <Icon size={16} style={{ color }} />}
        </div>
        <div className={cx('font-bold', emphasize ? 'text-2xl' : 'text-xl')} style={{ color }}>
          {value}
        </div>
        {sub && <div className="text-xs text-gray-500 mt-1.5 leading-relaxed">{sub}</div>}
      </Card>
    </Wrapper>
  );
}

function AccountListModal({ open, onClose, title, rows, renderRow }) {
  return (
    <Modal open={open} onClose={onClose} title={title} width={480}>
      {rows === null ? (
        <div className="py-10 flex justify-center"><Spinner /></div>
      ) : rows.length === 0 ? (
        <EmptyState>Nothing to show.</EmptyState>
      ) : (
        <div className="divide-y" style={{ borderColor: THEME.line }}>
          {rows.map(renderRow)}
        </div>
      )}
    </Modal>
  );
}

function AccountLedgerModal({ account, from, to, onClose }) {
  const [rows, setRows] = useState(null);

  useEffect(() => {
    if (!account) { setRows(null); return; }
    let alive = true;
    setRows(null);
    fetchAccountLedger(account.id, { from, to }).then((r) => { if (alive) setRows(r); });
    return () => { alive = false; };
  }, [account, from, to]);

  return (
    <Modal open={!!account} onClose={onClose} title={account ? `${account.name} — Ledger` : ''} width={640}>
      {rows === null ? (
        <div className="py-10 flex justify-center"><Spinner /></div>
      ) : rows.length === 0 ? (
        <EmptyState>No transactions in this range.</EmptyState>
      ) : (
        <Card className="overflow-auto" style={{ borderColor: THEME.line }}>
          <table className="w-full text-sm">
            <thead>
              <tr style={{ backgroundColor: THEME.surface }}>
                <th className="text-left px-3 py-2">Date</th>
                <th className="text-left px-3 py-2">Party</th>
                <th className="text-left px-3 py-2">Debit</th>
                <th className="text-left px-3 py-2">Credit</th>
                <th className="text-left px-3 py-2">Balance</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-t" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{formatDate(r.entry_date)}</td>
                  <td className="px-3 py-2">{r.parties?.name || '—'}</td>
                  <td className="px-3 py-2">{r.debit > 0 ? formatPkr(r.debit) : ''}</td>
                  <td className="px-3 py-2">{r.credit > 0 ? formatPkr(r.credit) : ''}</td>
                  <td className="px-3 py-2 font-medium">{formatPkr(r.running_balance)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </Modal>
  );
}

const MONTHLY_PROFIT_TOGGLES = [
  { key: 'total', label: 'Total Profit' },
  { key: 'sales', label: 'Total Sales' },
  { key: 'skf_polytex', label: 'Fabric (PolyTex)' },
  { key: 'skf_polybags', label: 'Poly Bags' },
];

function DashboardScreen() {
  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [brand, setBrand] = useState(null);
  const [brands, setBrands] = useState([]);
  const [loading, setLoading] = useState(true);

  const [summary, setSummary] = useState(null);
  const [fabricProfit, setFabricProfit] = useState(null);
  const [polybagsProfit, setPolybagsProfit] = useState(null);
  const [cashBank, setCashBank] = useState([]);
  const [cashFlow, setCashFlow] = useState(null);
  const [todaySummary, setTodaySummary] = useState(null);
  const [todayCashIn, setTodayCashIn] = useState(0);
  const [salesOverview, setSalesOverview] = useState([]);
  const [paymentsSummary, setPaymentsSummary] = useState({ received: 0, made: 0 });
  const [receivables, setReceivables] = useState({ total_receivables: 0, overdue_receivables: 0 });
  const [payables, setPayables] = useState([]);
  const [customerBalances, setCustomerBalances] = useState([]);
  const [topDebtors, setTopDebtors] = useState([]);
  const [topCustomers, setTopCustomers] = useState([]);
  const [monthlyProfit, setMonthlyProfit] = useState([]);
  const [profitToggle, setProfitToggle] = useState('total');
  const [appSettings, setAppSettings] = useState({ low_cash_threshold: 0, high_payables_threshold: 0 });

  const [cashBankModalKind, setCashBankModalKind] = useState(null); // 'cash' | 'bank' | null
  const [ledgerAccount, setLedgerAccount] = useState(null); // { id, name } | null
  const [receivablesModalOpen, setReceivablesModalOpen] = useState(false);
  const [payablesModalOpen, setPayablesModalOpen] = useState(false);

  useEffect(() => { fetchBrands().then(setBrands); }, []);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    const today = toDateInput(new Date());
    const graphFrom = toDateInput(new Date(new Date().getFullYear(), new Date().getMonth() - 5, 1));
    Promise.all([
      fetchDashboardSummary({ from, to, brandKey: brand?.brand_key }),
      fetchDashboardSummary({ from, to, brandKey: 'skf_polytex' }),
      fetchDashboardSummary({ from, to, brandKey: 'skf_polybags' }),
      fetchCashBankBalances(),
      fetchCashFlow({ from, to }),
      fetchDashboardSummary({ from: today, to: today }),
      fetchCashFlow({ from: today, to: today }),
      fetchSalesOverview({ from, to }),
      fetchPaymentsSummary({ from, to }),
      fetchReceivablesOverdue(),
      fetchPartyBalances({ type: 'supplier' }),
      fetchPartyBalances({ type: 'customer', positiveOnly: true }),
      fetchTopCustomers({ from, to }),
      fetchMonthlyProfit({ from: graphFrom, to: today }),
      fetchAppSettings(),
    ]).then(([s, fp, pp, cb, cf, ts, tcf, so, ps, rec, pay, debtors, customers, mp, settings]) => {
      if (!alive) return;
      setSummary(s); setFabricProfit(fp); setPolybagsProfit(pp);
      setCashBank(cb); setCashFlow(cf); setTodaySummary(ts); setTodayCashIn(tcf.cash_in);
      setSalesOverview(so); setPaymentsSummary(ps); setReceivables(rec);
      setPayables(pay.filter((p) => p.balance < 0));
      setCustomerBalances(debtors); setTopDebtors(debtors.slice(0, 5)); setTopCustomers(customers);
      setMonthlyProfit(mp); setAppSettings(settings);
    }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [from, to, brand]);

  if (loading && !summary) {
    return <div className="py-20 flex justify-center"><Spinner /></div>;
  }

  const cashTotal = cashBank.filter((a) => a.cash_bank_kind === 'cash').reduce((s, a) => s + Number(a.balance), 0);
  const bankTotal = cashBank.filter((a) => a.cash_bank_kind === 'bank').reduce((s, a) => s + Number(a.balance), 0);
  const payablesTotal = payables.reduce((s, p) => s - Number(p.balance), 0);
  const salesTotal = salesOverview.reduce((s, r) => s + Number(r.amount), 0);
  const pendingAmount = salesTotal - paymentsSummary.received;
  const fabricMarginPct = fabricProfit && fabricProfit.sales > 0
    ? ((fabricProfit.sales - fabricProfit.purchase) / fabricProfit.sales) * 100 : 0;
  const polybagsMarginPct = polybagsProfit && polybagsProfit.sales > 0
    ? ((polybagsProfit.sales - polybagsProfit.purchase) / polybagsProfit.sales) * 100 : 0;

  const monthLabels = [...new Set(monthlyProfit.map((r) => r.month))];
  const graphData = monthLabels.map((month) => {
    const rows = monthlyProfit.filter((r) => r.month === month);
    const totalProfit = rows.reduce((s, r) => s + (Number(r.sales) - Number(r.purchase) - Number(r.expenses)), 0);
    const totalSales = rows.reduce((s, r) => s + Number(r.sales), 0);
    const byBrand = {};
    rows.forEach((r) => { byBrand[r.brand_key] = Number(r.sales) - Number(r.purchase) - Number(r.expenses); });
    return {
      month: new Date(month).toLocaleDateString('en-GB', { month: 'short', year: '2-digit' }),
      total: totalProfit,
      sales: totalSales,
      skf_polytex: byBrand.skf_polytex || 0,
      skf_polybags: byBrand.skf_polybags || 0,
    };
  });

  function openCashBank(kind) {
    const accounts = cashBank.filter((a) => a.cash_bank_kind === kind);
    if (accounts.length === 1) setLedgerAccount({ id: accounts[0].id, name: accounts[0].name });
    else setCashBankModalKind(kind);
  }

  const alerts = [];
  if (receivables.overdue_receivables > 0) {
    alerts.push({ text: `${formatPkr(receivables.overdue_receivables)} in overdue receivables (30+ days).`, key: 'overdue' });
  }
  if (cashTotal + bankTotal < Number(appSettings.low_cash_threshold)) {
    alerts.push({ text: `Cash + Bank (${formatPkr(cashTotal + bankTotal)}) is below your low-cash threshold of ${formatPkr(appSettings.low_cash_threshold)}.`, key: 'lowcash' });
  }
  if (payablesTotal > Number(appSettings.high_payables_threshold) && appSettings.high_payables_threshold > 0) {
    alerts.push({ text: `Payables (${formatPkr(payablesTotal)}) are above your high-payables threshold of ${formatPkr(appSettings.high_payables_threshold)}.`, key: 'payables' });
  }

  return (
    <div>
      <div className="flex flex-wrap items-end gap-4 mb-2">
        <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />
        <BrandTabs brands={brands} value={brand} onChange={setBrand} allowAll />
      </div>

      {alerts.length > 0 && (
        <div className="mt-4 space-y-2">
          {alerts.map((a) => (
            <div key={a.key} className="flex items-center gap-2 rounded-lg px-4 py-2.5 text-sm" style={{ backgroundColor: '#FBEAEA', color: THEME.danger }}>
              <AlertTriangle size={16} className="flex-shrink-0" />
              {a.text}
            </div>
          ))}
        </div>
      )}

      <SectionHeading>Cash &amp; Bank</SectionHeading>
      <div className="grid grid-cols-2 gap-4">
        <StatCard title="Cash in Hand" icon={Wallet} color={THEME.cashGreen} value={formatPkr(cashTotal)}
          onClick={() => openCashBank('cash')} sub="Tap for ledger" />
        <StatCard title="Bank Balance" icon={Landmark} color={THEME.cashGreen} value={formatPkr(bankTotal)}
          onClick={() => openCashBank('bank')} sub="Tap for ledger" />
      </div>

      <SectionHeading>Sales Overview</SectionHeading>
      <div className="grid grid-cols-2 lg:grid-cols-3 gap-4">
        <StatCard title="Total Sale" icon={ShoppingCart} color={THEME.success} value={formatPkr(salesTotal)} emphasize />
        {['fabric', 'polybags'].map((cat) => {
          const row = salesOverview.find((r) => r.category === cat) || { quantity: 0, amount: 0 };
          return (
            <StatCard
              key={cat}
              title={cat === 'polybags' ? 'Poly Bag Sale' : 'Fabric Sale'}
              icon={ShoppingCart} color={THEME.success}
              value={formatPkr(row.amount)}
              sub={`${Number(row.quantity).toLocaleString()} ${cat === 'polybags' ? 'pcs' : 'kg'}`}
            />
          );
        })}
      </div>

      <SectionHeading>Payments</SectionHeading>
      <div className="grid grid-cols-2 gap-4">
        <StatCard title="Payments Received" icon={ArrowUpRight} color={THEME.success} value={formatPkr(paymentsSummary.received)} />
        <StatCard title="Payments Made" icon={ArrowDownRight} color={THEME.danger} value={formatPkr(paymentsSummary.made)} />
      </div>

      <SectionHeading>Expenses</SectionHeading>
      <StatCard title="Expenses" icon={Receipt} color={THEME.amber} value={formatPkr(summary?.expenses || 0)} />

      <SectionHeading>Payables</SectionHeading>
      <StatCard title="Total Payables" icon={Users} color={THEME.amber} value={formatPkr(payablesTotal)}
        onClick={() => setPayablesModalOpen(true)} sub="Tap for vendor-wise balances" />

      <SectionHeading>Receivables</SectionHeading>
      <div className="grid grid-cols-2 gap-4">
        <StatCard title="Total Receivables" icon={Users} color={THEME.blue} value={formatPkr(receivables.total_receivables)}
          onClick={() => setReceivablesModalOpen(true)} sub="Tap for customer-wise balances" />
        <StatCard title="Overdue Receivables" icon={AlertTriangle} color={THEME.danger} value={formatPkr(receivables.overdue_receivables)}
          highlight={receivables.overdue_receivables > 0} sub="30+ days unpaid (approximate)" />
      </div>

      <SectionHeading>Sales &amp; Profit Growth</SectionHeading>
      <Card className="p-4" style={{ borderColor: THEME.line }}>
        <div className="flex flex-wrap gap-2 mb-4">
          {MONTHLY_PROFIT_TOGGLES.map((t) => (
            <button
              key={t.key}
              onClick={() => setProfitToggle(t.key)}
              className="px-3 py-1.5 rounded-full text-xs font-medium border"
              style={profitToggle === t.key ? { backgroundColor: THEME.blue, color: 'white', borderColor: THEME.blue } : { borderColor: THEME.line }}
            >
              {t.label}
            </button>
          ))}
        </div>
        <div style={{ width: '100%', height: 260 }}>
          <ResponsiveContainer>
            <LineChart data={graphData}>
              <CartesianGrid strokeDasharray="3 3" stroke={THEME.line} />
              <XAxis dataKey="month" tick={{ fontSize: 12 }} />
              <YAxis tick={{ fontSize: 12 }} tickFormatter={(v) => formatPkr(v)} width={80} />
              <Tooltip formatter={(v) => formatPkr(v)} />
              <Legend />
              <Line type="monotone" dataKey={profitToggle} name={MONTHLY_PROFIT_TOGGLES.find((t) => t.key === profitToggle).label} stroke={THEME.emerald} strokeWidth={2} dot={{ r: 3 }} />
            </LineChart>
          </ResponsiveContainer>
        </div>
      </Card>

      <SectionHeading>Today&apos;s Snapshot</SectionHeading>
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard title="Today Sales" icon={ArrowUpRight} color={THEME.success} value={formatPkr(todaySummary?.sales || 0)} />
        <StatCard title="Today Profit" icon={ArrowUpRight} color={THEME.emerald} value={formatPkr(todaySummary?.profit || 0)} />
        <StatCard title="Today Expenses" icon={ArrowDownRight} color={THEME.amber} value={formatPkr(todaySummary?.expenses || 0)} />
        <StatCard title="Today Cash Received" icon={Wallet} color={THEME.cashGreen} value={formatPkr(todayCashIn)} />
      </div>

      <SectionHeading>Profit</SectionHeading>
      <div className="grid grid-cols-2 lg:grid-cols-3 gap-4">
        <StatCard
          title="Fabric Profit (PolyTex)" icon={ArrowUpRight} color={THEME.emerald}
          value={formatPkr((fabricProfit?.sales || 0) - (fabricProfit?.purchase || 0))}
          sub={`Gross margin ${fabricMarginPct.toFixed(1)}%`}
        />
        <StatCard
          title="Poly Bags Profit" icon={ArrowUpRight} color={THEME.emerald}
          value={formatPkr((polybagsProfit?.sales || 0) - (polybagsProfit?.purchase || 0))}
          sub={`Gross margin ${polybagsMarginPct.toFixed(1)}%`}
        />
        <StatCard
          title="Total Net Profit" icon={ArrowUpRight} color={summary?.profit >= 0 ? THEME.emerald : THEME.danger}
          value={formatPkr(summary?.profit || 0)} emphasize sub="After all expenses"
        />
      </div>

      <SectionHeading>Top Debtors</SectionHeading>
      {topDebtors.length === 0 ? (
        <EmptyState>No customers currently owe money.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {topDebtors.map((d) => (
            <div key={d.party_id} className="flex items-center justify-between px-4 py-3">
              <span className="text-sm font-medium">{d.name}</span>
              <span className="text-sm font-semibold" style={{ color: THEME.danger }}>{formatPkr(d.balance)}</span>
            </div>
          ))}
        </Card>
      )}

      <SectionHeading>Top Customers</SectionHeading>
      {topCustomers.length === 0 ? (
        <EmptyState>No sales in this range.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {topCustomers.map((c) => (
            <div key={c.party_id} className="flex items-center justify-between px-4 py-3">
              <span className="text-sm font-medium">{c.name}</span>
              <span className="text-sm font-semibold" style={{ color: THEME.success }}>{formatPkr(c.total_sales)}</span>
            </div>
          ))}
        </Card>
      )}

      <SectionHeading>Sales vs Recovery</SectionHeading>
      <div className="grid grid-cols-3 gap-4">
        <StatCard title="Total Sales" icon={ShoppingCart} color={THEME.success} value={formatPkr(salesTotal)} />
        <StatCard title="Total Received" icon={ArrowUpRight} color={THEME.success} value={formatPkr(paymentsSummary.received)} />
        <StatCard title="Pending Amount" icon={ArrowDownRight} color={THEME.danger} value={formatPkr(Math.max(pendingAmount, 0))} />
      </div>

      <AccountListModal
        open={!!cashBankModalKind}
        onClose={() => setCashBankModalKind(null)}
        title={cashBankModalKind === 'cash' ? 'Cash accounts' : 'Bank accounts'}
        rows={cashBank.filter((a) => a.cash_bank_kind === cashBankModalKind)}
        renderRow={(a) => (
          <button
            key={a.id}
            className="w-full flex items-center justify-between px-1 py-3 text-left hover:opacity-70"
            onClick={() => { setCashBankModalKind(null); setLedgerAccount({ id: a.id, name: a.name }); }}
          >
            <span className="text-sm">{a.name}</span>
            <span className="text-sm font-semibold" style={{ color: THEME.cashGreen }}>{formatPkr(a.balance)}</span>
          </button>
        )}
      />

      <AccountLedgerModal account={ledgerAccount} from={from} to={to} onClose={() => setLedgerAccount(null)} />

      <AccountListModal
        open={receivablesModalOpen}
        onClose={() => setReceivablesModalOpen(false)}
        title="Customer-wise receivables"
        rows={customerBalances}
        renderRow={(d) => (
          <div key={d.party_id} className="flex items-center justify-between px-1 py-3">
            <span className="text-sm">{d.name}</span>
            <span className="text-sm font-semibold" style={{ color: THEME.blue }}>{formatPkr(d.balance)}</span>
          </div>
        )}
      />

      <AccountListModal
        open={payablesModalOpen}
        onClose={() => setPayablesModalOpen(false)}
        title="Vendor-wise payables"
        rows={payables}
        renderRow={(p) => (
          <div key={p.party_id} className="flex items-center justify-between px-1 py-3">
            <span className="text-sm">{p.name}</span>
            <span className="text-sm font-semibold" style={{ color: THEME.amber }}>{formatPkr(-p.balance)}</span>
          </div>
        )}
      />

    </div>
  );
}

// ============================================================================
// PURCHASE MODULE — Purchase Order / Purchase Bill / Purchase Return, each
// with a New (fast keyboard entry) and Old (browse/void/print/export) mode.
//
// Keyboard flow in New mode: Date -> Vendor -> [Item -> Unit -> Qty -> Rate
// -> new line] repeating. F2 (while the vendor field is focused) adds a new
// vendor; F3 (while an item field is focused) adds a new item. Ctrl+S saves,
// Ctrl+P prints the current draft.
//
// "Old" mode never offers Edit/Delete on a posted document — the backend
// design (see migration notes) never mutates or deletes a posted invoice,
// only voids it with a reversing ledger/stock entry. Void replaces those
// two actions here, gated by the same 'approve' permission the rest of the
// app already uses for voiding.
// ============================================================================

const PURCHASE_TABS = [
  { key: 'purchase_order', label: 'Purchase Order' },
  { key: 'purchase', label: 'Purchase Bill' },
  { key: 'purchase_return', label: 'Purchase Return' },
];

function purchaseDocLabel(invoiceType) {
  return invoiceType === 'purchase_order' ? 'Purchase Order'
    : invoiceType === 'purchase_return' ? 'Purchase Return' : 'Purchase Bill';
}

function PurchaseModule() {
  const [tab, setTab] = useState('purchase');
  const [mode, setMode] = useState('new');

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-5">
        <div className="flex flex-wrap gap-2">
          {PURCHASE_TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => { setTab(t.key); setMode('new'); }}
              className="px-3 py-1.5 rounded-full text-sm font-medium border"
              style={tab === t.key ? { backgroundColor: THEME.blue, color: 'white', borderColor: THEME.blue } : { borderColor: THEME.line }}
            >
              {t.label}
            </button>
          ))}
        </div>
        <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
          {[{ k: 'new', l: 'New' }, { k: 'old', l: 'Old' }].map((o) => (
            <button
              key={o.k}
              onClick={() => setMode(o.k)}
              className="px-3 py-1.5 rounded-md text-sm font-medium"
              style={mode === o.k ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {o.l}
            </button>
          ))}
        </div>
      </div>

      {mode === 'new'
        ? <PurchaseEntryForm key={tab} invoiceType={tab} onSavedClose={() => setMode('old')} />
        : <PurchaseOldList key={tab} invoiceType={tab} />}
    </div>
  );
}

function emptyPurchaseLine() {
  return { itemId: null, itemName: '', unit: '', quantity: '', rate: '' };
}

function PurchaseEntryForm({ invoiceType, onSavedClose }) {
  const isBill = invoiceType === 'purchase';
  const title = purchaseDocLabel(invoiceType);

  const [brands, setBrands] = useState([]);
  const [brand, setBrand] = useState(null);
  const [vendor, setVendor] = useState(null);
  const [vendorResetKey, setVendorResetKey] = useState(0);
  const [date, setDate] = useState(toDateInput(new Date()));
  const [lines, setLines] = useState([emptyPurchaseLine()]);
  const [saving, setSaving] = useState(false);
  const [savedNo, setSavedNo] = useState(null);
  const { show, ToastHost } = useToast();

  const [supplierInvoiceNo, setSupplierInvoiceNo] = useState('');
  const [poOptions, setPoOptions] = useState([]);
  const [linkedOrder, setLinkedOrder] = useState(null);
  const [transport, setTransport] = useState('0');
  const [loadingCharge, setLoadingCharge] = useState('0');
  const [discount, setDiscount] = useState('0');
  const [tax, setTax] = useState('0');

  const dateRef = useRef(null);
  const vendorRef = useRef(null);
  const lineRefs = useRef({});
  function getLineRefs(i) {
    if (!lineRefs.current[i]) {
      lineRefs.current[i] = { item: React.createRef(), unit: React.createRef(), qty: React.createRef(), rate: React.createRef() };
    }
    return lineRefs.current[i];
  }

  useEffect(() => {
    fetchBrands().then((rows) => { setBrands(rows); if (rows.length && !brand) setBrand(rows[0]); });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { dateRef.current?.focus(); }, []);

  useEffect(() => {
    if (!isBill || !vendor) { setPoOptions([]); return; }
    let alive = true;
    fetchOpenPurchaseOrders(vendor.id).then((rows) => { if (alive) setPoOptions(rows); });
    return () => { alive = false; };
  }, [isBill, vendor]);

  function switchBrand(b) {
    setBrand(b);
    setLines([emptyPurchaseLine()]);
    setVendor(null);
    setVendorResetKey((k) => k + 1);
    setLinkedOrder(null);
    lineRefs.current = {};
  }

  function addLine(focus = true) {
    setLines((ls) => {
      const next = [...ls, emptyPurchaseLine()];
      if (focus) {
        const idx = next.length - 1;
        requestAnimationFrame(() => getLineRefs(idx).item.current?.focus());
      }
      return next;
    });
  }
  function updateLine(i, patch) {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  }
  function removeLine(i) {
    setLines((ls) => (ls.length === 1 ? ls : ls.filter((_, idx) => idx !== i)));
  }

  function pickItemForLine(i, item) {
    updateLine(i, {
      itemId: item.id,
      itemName: item.name,
      unit: item.default_unit || purchaseUnitOptionsFor(brand?.category)[0],
      rate: item.last_purchase_rate != null && !lines[i].rate ? String(item.last_purchase_rate) : lines[i].rate,
    });
  }

  async function applyLinkedOrder(order) {
    if (!order) { setLinkedOrder(null); return; }
    try {
      const { items } = await fetchInvoiceWithItems(order.id);
      setLinkedOrder(order);
      setLines(items.map((it) => ({
        itemId: it.item_id, itemName: it.items?.name || it.description || '',
        unit: it.unit, quantity: String(it.quantity), rate: String(it.rate),
      })));
    } catch (e) {
      show(`Could not load purchase order: ${e.message}`, 'danger');
    }
  }

  const subtotal = lines.reduce((s, l) => s + (Number(l.quantity) || 0) * (Number(l.rate) || 0), 0);
  const grandTotal = isBill
    ? subtotal + (Number(transport) || 0) + (Number(loadingCharge) || 0) + (Number(tax) || 0) - (Number(discount) || 0)
    : subtotal;

  function resetForm() {
    setLines([emptyPurchaseLine()]);
    setVendor(null);
    setVendorResetKey((k) => k + 1);
    setSupplierInvoiceNo('');
    setLinkedOrder(null);
    setTransport('0'); setLoadingCharge('0'); setDiscount('0'); setTax('0');
    lineRefs.current = {};
    requestAnimationFrame(() => dateRef.current?.focus());
  }

  async function save(closeAfter) {
    if (!brand || !vendor) { show('Pick a category and a vendor.', 'danger'); return; }
    const validLines = lines.filter((l) => l.itemId && Number(l.quantity) > 0 && Number(l.rate) >= 0);
    if (validLines.length === 0) { show('Add at least one line item.', 'danger'); return; }
    setSaving(true);
    try {
      const id = await createInvoice({
        invoiceType, brandKey: brand.brand_key, category: brand.category,
        partyId: vendor.id, invoiceDate: date,
        items: validLines.map((l) => ({ itemId: l.itemId, quantity: l.quantity, unit: l.unit, rate: l.rate, description: l.itemName })),
        supplierInvoiceNo: isBill ? supplierInvoiceNo : undefined,
        linkedOrderId: isBill ? linkedOrder?.id : undefined,
        transport: isBill ? transport : undefined,
        loading: isBill ? loadingCharge : undefined,
        discount: isBill ? discount : undefined,
        tax: isBill ? tax : undefined,
      });
      const { invoice } = await fetchInvoiceWithItems(id);
      show(`Saved. ${invoice.invoice_no} created.`);
      setSavedNo(invoice.invoice_no);
      resetForm();
      if (closeAfter) onSavedClose?.();
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  function buildDraft() {
    const pseudoInvoice = {
      invoice_no: savedNo || 'DRAFT', invoice_date: date, parties: { name: vendor?.name },
      invoice_type: invoiceType, supplier_invoice_no: supplierInvoiceNo,
      transport_charges: transport, loading_charges: loadingCharge, discount_amount: discount, tax_amount: tax,
      total_amount: grandTotal,
    };
    const pseudoItems = lines.filter((l) => l.itemId).map((l) => ({
      items: { name: l.itemName }, unit: l.unit, quantity: l.quantity, rate: l.rate,
      amount: (Number(l.quantity) || 0) * (Number(l.rate) || 0),
    }));
    return { pseudoInvoice, pseudoItems };
  }
  function draftPrint() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    printPdfDoc(buildPurchaseDocPdf(pseudoInvoice, pseudoItems));
  }
  function draftExportPdf() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    buildPurchaseDocPdf(pseudoInvoice, pseudoItems).save(`${pseudoInvoice.invoice_no}.pdf`);
  }

  useEffect(() => {
    function onKey(e) {
      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); save(false); }
      if (mod && e.key.toLowerCase() === 'p') { e.preventDefault(); draftPrint(); }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  if (!brand) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const units = purchaseUnitOptionsFor(brand.category);

  function lineFields(i, line) {
    return {
      item: (
        <ItemPicker
          category={brand.category}
          value={line.itemId ? { id: line.itemId, name: line.itemName } : null}
          onChange={(it) => pickItemForLine(i, it)}
          resetKey={`${i}-${line.itemId || 'empty'}`}
          inputRef={getLineRefs(i).item}
          onEnterNext={() => getLineRefs(i).unit.current?.focus()}
        />
      ),
      unit: (
        <Select
          ref={getLineRefs(i).unit}
          label="Unit"
          value={line.unit}
          onChange={(e) => updateLine(i, { unit: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).qty.current?.focus(); } }}
        >
          <option value="">—</option>
          {units.map((u) => <option key={u} value={u}>{u}</option>)}
        </Select>
      ),
      qty: (
        <Input
          ref={getLineRefs(i).qty}
          type="number" label="Qty" value={line.quantity}
          onChange={(e) => updateLine(i, { quantity: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).rate.current?.focus(); } }}
        />
      ),
      rate: (
        <Input
          ref={getLineRefs(i).rate}
          type="number" label="Rate" value={line.rate}
          onChange={(e) => updateLine(i, { rate: e.target.value })}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              if (i === lines.length - 1) addLine();
              else getLineRefs(i + 1).item.current?.focus();
            }
          }}
        />
      ),
      amount: formatPkr((Number(line.quantity) || 0) * (Number(line.rate) || 0)),
    };
  }

  return (
    <div className="max-w-5xl">
      <h2 className="font-display font-semibold text-lg mb-4">{title}</h2>

      <div className="flex flex-wrap items-end gap-4 mb-5">
        <BrandTabs brands={brands} value={brand} onChange={switchBrand} />
        <Input
          ref={dateRef} type="date" label="Date" value={date}
          onChange={(e) => setDate(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); vendorRef.current?.focus(); } }}
        />
      </div>

      <div className="mb-5 max-w-md">
        <PartyPicker
          type="supplier" value={vendor} onChange={setVendor}
          resetKey={vendorResetKey} inputRef={vendorRef} label="Vendor"
          onEnterNext={() => getLineRefs(0).item.current?.focus()}
        />
      </div>

      {isBill && (
        <Card className="p-4 mb-5 grid sm:grid-cols-2 gap-3" style={{ borderColor: THEME.line }}>
          <Input label="Supplier Invoice # (optional)" value={supplierInvoiceNo} onChange={(e) => setSupplierInvoiceNo(e.target.value)} />
          <Select
            label="Load from Purchase Order (optional)"
            value={linkedOrder?.id || ''}
            onChange={(e) => applyLinkedOrder(poOptions.find((o) => o.id === e.target.value) || null)}
          >
            <option value="">— none —</option>
            {poOptions.map((o) => (
              <option key={o.id} value={o.id}>{o.invoice_no} · {formatDate(o.invoice_date)} · {formatPkr(o.total_amount)}</option>
            ))}
          </Select>
          {!vendor && <p className="text-xs text-gray-500 sm:col-span-2">Pick a vendor first to see their open purchase orders.</p>}
          {linkedOrder && <p className="text-xs text-gray-500 sm:col-span-2">Loaded from {linkedOrder.invoice_no} — quantities below are editable for partial billing.</p>}
        </Card>
      )}

      <div className="flex items-center justify-between mb-2">
        <h3 className="font-medium text-sm text-gray-700">Line items</h3>
        <Button variant="ghost" icon={Plus} onClick={() => addLine()}>Add line</Button>
      </div>

      {/* Desktop / tablet: Excel-like grid */}
      <Card className="hidden md:block overflow-auto" style={{ borderColor: THEME.line }}>
        <table className="w-full text-sm">
          <thead>
            <tr style={{ backgroundColor: THEME.surface }}>
              <th className="text-left font-medium px-3 py-2.5 w-2/5">Item</th>
              <th className="text-left font-medium px-3 py-2.5">Unit</th>
              <th className="text-left font-medium px-3 py-2.5">Qty</th>
              <th className="text-left font-medium px-3 py-2.5">Rate</th>
              <th className="text-left font-medium px-3 py-2.5">Amount</th>
              <th className="px-2 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lines.map((line, i) => {
              const f = lineFields(i, line);
              return (
                <tr key={i} className="border-t align-top" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{f.item}</td>
                  <td className="px-3 py-2 w-28">{f.unit}</td>
                  <td className="px-3 py-2 w-24">{f.qty}</td>
                  <td className="px-3 py-2 w-28">{f.rate}</td>
                  <td className="px-3 py-2 w-28 pt-4 font-medium">{f.amount}</td>
                  <td className="px-2 py-2 pt-4">
                    <button onClick={() => removeLine(i)} className="text-gray-400 hover:text-red-500">
                      <X size={18} />
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Card>

      {/* Mobile: step-card entry */}
      <div className="md:hidden space-y-3">
        {lines.map((line, i) => {
          const f = lineFields(i, line);
          return (
            <Card key={i} className="p-3 space-y-3" style={{ borderColor: THEME.line }}>
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-gray-500">Line {i + 1}</span>
                <button onClick={() => removeLine(i)} className="text-gray-400 hover:text-red-500">
                  <X size={18} />
                </button>
              </div>
              {f.item}
              <div className="grid grid-cols-2 gap-3">{f.unit}{f.qty}</div>
              <div className="grid grid-cols-2 gap-3 items-end">
                {f.rate}
                <div>
                  <span className="block text-sm font-medium text-gray-700 mb-1">Amount</span>
                  <div className="px-3 py-2.5 text-sm font-medium">{f.amount}</div>
                </div>
              </div>
            </Card>
          );
        })}
      </div>

      {isBill && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-5 max-w-xl ml-auto">
          <Input label="Transport" type="number" value={transport} onChange={(e) => setTransport(e.target.value)} />
          <Input label="Loading/Unloading" type="number" value={loadingCharge} onChange={(e) => setLoadingCharge(e.target.value)} />
          <Input label="Discount" type="number" value={discount} onChange={(e) => setDiscount(e.target.value)} />
          <Input label="Tax" type="number" value={tax} onChange={(e) => setTax(e.target.value)} />
        </div>
      )}

      <div className="flex items-center justify-end gap-2 mt-5 mb-6">
        <span className="text-gray-500">{isBill ? 'Grand Total:' : 'Total:'}</span>
        <span className="text-xl font-bold" style={{ color: THEME.blue }}>{formatPkr(grandTotal)}</span>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button onClick={() => save(false)} loading={saving}>Save</Button>
        <Button variant="outline" onClick={() => save(true)} loading={saving}>Save &amp; Close</Button>
        <Button variant="outline" icon={FileDown} onClick={draftPrint}>Print</Button>
        <Button variant="outline" icon={FileDown} onClick={draftExportPdf}>Export PDF</Button>
        {savedNo && <Badge tone="success">Last saved: {savedNo}</Badge>}
      </div>
      <p className="text-xs text-gray-500 mt-2">
        Enter moves Date → Vendor → Item → Unit → Qty → Rate → next line. F2 on the vendor field adds a vendor, F3 on an item field adds an item. Ctrl+S saves, Ctrl+P prints the draft.
      </p>
      <ToastHost />
    </div>
  );
}

function buildPurchaseDocPdf(invoice, items) {
  const doc = new jsPDF();
  doc.setFontSize(14);
  doc.text('SKF PolyTex / SKF PolyBags', 14, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(`${purchaseDocLabel(invoice.invoice_type)} — ${invoice.invoice_no}`, 14, 23);
  doc.text(`Date: ${formatDate(invoice.invoice_date)}   Vendor: ${invoice.parties?.name || ''}`, 14, 29);
  let startY = 35;
  if (invoice.supplier_invoice_no) {
    doc.text(`Supplier Invoice #: ${invoice.supplier_invoice_no}`, 14, 35);
    startY = 41;
  }
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });

  const rows = items.map((it) => [it.items?.name || it.description || '', it.unit, String(it.quantity), formatPkr(it.rate), formatPkr(it.amount)]);
  const subtotal = items.reduce((s, it) => s + Number(it.amount || 0), 0);
  const foot = [['', '', '', 'Subtotal', formatPkr(subtotal)]];
  if (invoice.invoice_type === 'purchase') {
    foot.push(['', '', '', 'Transport + Loading + Tax − Discount',
      formatPkr(Number(invoice.transport_charges || 0) + Number(invoice.loading_charges || 0)
        + Number(invoice.tax_amount || 0) - Number(invoice.discount_amount || 0))]);
  }
  foot.push(['', '', '', 'Grand Total', formatPkr(invoice.total_amount)]);

  autoTable(doc, {
    startY,
    head: [['Item', 'Unit', 'Qty', 'Rate', 'Amount']],
    body: rows,
    foot,
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    footStyles: { fillColor: [247, 248, 250], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 9, cellPadding: 3 },
  });
  return doc;
}

function printPdfDoc(doc) {
  doc.autoPrint();
  window.open(doc.output('bloburl'), '_blank');
}

function VoidReasonModal({ target, onClose, onConfirm }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { setReason(''); }, [target]);

  async function confirm() {
    if (!reason.trim()) return;
    setBusy(true);
    try { await onConfirm(reason.trim()); } finally { setBusy(false); }
  }

  return (
    <Modal open={!!target} onClose={onClose} title={`Void ${target?.invoice_no || ''}`}>
      <div className="space-y-3">
        <p className="text-sm text-gray-500">
          This reverses the ledger{target?.invoice_type !== 'purchase_order' ? ' and stock' : ''} impact of this document with an audit-trail entry. It cannot be undone.
        </p>
        <Input label="Reason" value={reason} onChange={(e) => setReason(e.target.value)} autoFocus />
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button variant="danger" onClick={confirm} loading={busy}>Void document</Button>
        </div>
      </div>
    </Modal>
  );
}

function PurchaseViewModal({ doc, onClose }) {
  if (!doc) return null;
  const { invoice, items } = doc;
  return (
    <Modal open={!!doc} onClose={onClose} title={invoice.invoice_no} width={560}>
      <div className="space-y-3 text-sm">
        <div className="grid grid-cols-2 gap-2">
          <div><span className="text-gray-500">Date:</span> {formatDate(invoice.invoice_date)}</div>
          <div><span className="text-gray-500">Vendor:</span> {invoice.parties?.name}</div>
          <div><span className="text-gray-500">Status:</span> <Badge tone={invoice.status === 'voided' ? 'danger' : 'success'}>{invoice.status}</Badge></div>
          {invoice.supplier_invoice_no && <div><span className="text-gray-500">Supplier Inv #:</span> {invoice.supplier_invoice_no}</div>}
        </div>
        <Card className="overflow-auto" style={{ borderColor: THEME.line }}>
          <table className="w-full text-sm">
            <thead>
              <tr style={{ backgroundColor: THEME.surface }}>
                <th className="text-left px-3 py-2">Item</th>
                <th className="text-left px-3 py-2">Unit</th>
                <th className="text-left px-3 py-2">Qty</th>
                <th className="text-left px-3 py-2">Rate</th>
                <th className="text-left px-3 py-2">Amount</th>
              </tr>
            </thead>
            <tbody>
              {items.map((it) => (
                <tr key={it.id} className="border-t" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{it.items?.name || it.description}</td>
                  <td className="px-3 py-2">{it.unit}</td>
                  <td className="px-3 py-2">{it.quantity}</td>
                  <td className="px-3 py-2">{formatPkr(it.rate)}</td>
                  <td className="px-3 py-2">{formatPkr(it.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
        {invoice.invoice_type === 'purchase' && (
          <div className="text-xs text-gray-500">
            Transport: {formatPkr(invoice.transport_charges)} · Loading: {formatPkr(invoice.loading_charges)} ·
            Tax: {formatPkr(invoice.tax_amount)} · Discount: {formatPkr(invoice.discount_amount)}
          </div>
        )}
        <div className="text-right font-bold" style={{ color: THEME.blue }}>Total: {formatPkr(invoice.total_amount)}</div>
      </div>
    </Modal>
  );
}

function PurchaseOldList({ invoiceType }) {
  const { permissions } = useAuth();
  const canApprove = !!permissions.entry_purchase?.can_approve;

  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [vendor, setVendor] = useState(null);
  const [vendorResetKey, setVendorResetKey] = useState(0);
  const [invoiceNo, setInvoiceNo] = useState('');
  const [poNo, setPoNo] = useState('');
  const [rows, setRows] = useState(null);
  const [orderLookup, setOrderLookup] = useState({});
  const [viewDoc, setViewDoc] = useState(null);
  const [voidTarget, setVoidTarget] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchInvoices({ invoiceType, from, to, partyId: vendor?.id, invoiceNo }).then((r) => { if (alive) setRows(r); });
    if (invoiceType === 'purchase') {
      fetchInvoices({ invoiceType: 'purchase_order', from: '2000-01-01', to: '2999-12-31' }).then((orders) => {
        if (!alive) return;
        const map = {};
        orders.forEach((o) => { map[o.id] = o.invoice_no; });
        setOrderLookup(map);
      });
    }
    return () => { alive = false; };
  }, [invoiceType, from, to, vendor, invoiceNo, refreshKey]);

  const filtered = poNo
    ? (rows || []).filter((r) => (orderLookup[r.linked_order_id] || '').toLowerCase().includes(poNo.toLowerCase()))
    : rows;

  async function handleView(row) {
    try { setViewDoc(await fetchInvoiceWithItems(row.id)); }
    catch (e) { show(`Could not load document: ${e.message}`, 'danger'); }
  }
  async function handlePrint(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); printPdfDoc(buildPurchaseDocPdf(invoice, items)); }
    catch (e) { show(`Could not print: ${e.message}`, 'danger'); }
  }
  async function handleExportPdf(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); buildPurchaseDocPdf(invoice, items).save(`${invoice.invoice_no}.pdf`); }
    catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleExportExcel(row) {
    try {
      const { items } = await fetchInvoiceWithItems(row.id);
      exportExcel({
        title: row.invoice_no,
        columns: ['Item', 'Unit', 'Qty', 'Rate', 'Amount'],
        rows: items.map((it) => [it.items?.name || it.description || '', it.unit, it.quantity, it.rate, it.amount]),
      });
    } catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleVoidConfirm(reason) {
    try {
      await voidInvoice(voidTarget.id, reason);
      show(`${voidTarget.invoice_no} voided.`);
      setVoidTarget(null);
      setRefreshKey((k) => k + 1);
    } catch (e) {
      show(`Could not void: ${e.message}`, 'danger');
    }
  }

  return (
    <div>
      <div className="flex flex-wrap items-end gap-3 mb-5">
        <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />
        <div className="w-56">
          <PartyPicker type="supplier" value={vendor} onChange={setVendor} resetKey={vendorResetKey} label="Vendor" />
        </div>
        <div className="w-40">
          <Input label="Invoice #" value={invoiceNo} onChange={(e) => setInvoiceNo(e.target.value)} placeholder="Search…" />
        </div>
        {invoiceType === 'purchase' && (
          <div className="w-40">
            <Input label="PO #" value={poNo} onChange={(e) => setPoNo(e.target.value)} placeholder="Search…" />
          </div>
        )}
        {(vendor || invoiceNo || poNo) && (
          <Button variant="ghost" onClick={() => { setVendor(null); setVendorResetKey((k) => k + 1); setInvoiceNo(''); setPoNo(''); }}>
            Clear
          </Button>
        )}
      </div>

      {filtered === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : filtered.length === 0 ? (
        <EmptyState>No {purchaseDocLabel(invoiceType).toLowerCase()} records in this range.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {filtered.map((row) => (
            <div key={row.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
              <div className="flex-1 min-w-[180px]">
                <div className="font-medium flex items-center gap-2">
                  {row.invoice_no}
                  {row.status === 'voided' && <Badge tone="danger">Voided</Badge>}
                  {invoiceType === 'purchase' && orderLookup[row.linked_order_id] && (
                    <span className="text-xs text-gray-400">from {orderLookup[row.linked_order_id]}</span>
                  )}
                </div>
                <div className="text-xs text-gray-500">{formatDate(row.invoice_date)} · {row.parties?.name}</div>
              </div>
              <div className="font-semibold w-28 text-right" style={{ color: THEME.blue }}>{formatPkr(row.total_amount)}</div>
              <div className="flex items-center gap-1">
                <button onClick={() => handleView(row)} title="View" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <Search size={16} />
                </button>
                <button onClick={() => handlePrint(row)} title="Print" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportPdf(row)} title="Export PDF" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportExcel(row)} title="Export Excel" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileSpreadsheet size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => setVoidTarget(row)} title="Void" className="p-2 rounded-lg hover:bg-red-50 text-red-500">
                    <X size={16} />
                  </button>
                )}
              </div>
            </div>
          ))}
        </Card>
      )}

      <PurchaseViewModal doc={viewDoc} onClose={() => setViewDoc(null)} />
      <VoidReasonModal target={voidTarget} onClose={() => setVoidTarget(null)} onConfirm={handleVoidConfirm} />
      <ToastHost />
    </div>
  );
}

// ============================================================================
// SALES MODULE — Sale Order / Sale Bill / Sale Return. Mirrors the Purchase
// Module's structure exactly (see its doc comment for the general design
// conventions); the differences are: party type is 'customer', the Bill's
// reference field is the customer's own PO number (not a supplier invoice
// number we're recording), linking is against open Sale Orders, and the Bill
// shows a soft, non-blocking "only N in stock" warning per line — selling
// more than what's on hand is allowed (this is a fast trading tool, not an
// inventory gate), it just gets flagged.
// ============================================================================

const SALE_TABS = [
  { key: 'sale_order', label: 'Sale Order' },
  { key: 'sale', label: 'Sale Bill' },
  { key: 'sale_return', label: 'Sale Return' },
];

function saleDocLabel(invoiceType) {
  return invoiceType === 'sale_order' ? 'Sale Order'
    : invoiceType === 'sale_return' ? 'Sale Return' : 'Sale Bill';
}

function SalesModule() {
  const [tab, setTab] = useState('sale');
  const [mode, setMode] = useState('new');

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-5">
        <div className="flex flex-wrap gap-2">
          {SALE_TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => { setTab(t.key); setMode('new'); }}
              className="px-3 py-1.5 rounded-full text-sm font-medium border"
              style={tab === t.key ? { backgroundColor: THEME.blue, color: 'white', borderColor: THEME.blue } : { borderColor: THEME.line }}
            >
              {t.label}
            </button>
          ))}
        </div>
        <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
          {[{ k: 'new', l: 'New' }, { k: 'old', l: 'Old' }].map((o) => (
            <button
              key={o.k}
              onClick={() => setMode(o.k)}
              className="px-3 py-1.5 rounded-md text-sm font-medium"
              style={mode === o.k ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {o.l}
            </button>
          ))}
        </div>
      </div>

      {mode === 'new'
        ? <SaleEntryForm key={tab} invoiceType={tab} onSavedClose={() => setMode('old')} />
        : <SaleOldList key={tab} invoiceType={tab} />}
    </div>
  );
}

function emptySaleLine() {
  return { itemId: null, itemName: '', unit: '', quantity: '', rate: '' };
}

function SaleEntryForm({ invoiceType, onSavedClose }) {
  const isBill = invoiceType === 'sale';
  const title = saleDocLabel(invoiceType);

  const [brands, setBrands] = useState([]);
  const [brand, setBrand] = useState(null);
  const [customer, setCustomer] = useState(null);
  const [customerResetKey, setCustomerResetKey] = useState(0);
  const [date, setDate] = useState(toDateInput(new Date()));
  const [lines, setLines] = useState([emptySaleLine()]);
  const [saving, setSaving] = useState(false);
  const [savedNo, setSavedNo] = useState(null);
  const { show, ToastHost } = useToast();

  const [customerPoNo, setCustomerPoNo] = useState('');
  const [soOptions, setSoOptions] = useState([]);
  const [linkedOrder, setLinkedOrder] = useState(null);
  const [transport, setTransport] = useState('0');
  const [loadingCharge, setLoadingCharge] = useState('0');
  const [discount, setDiscount] = useState('0');
  const [tax, setTax] = useState('0');
  const [stockMap, setStockMap] = useState({});

  const dateRef = useRef(null);
  const customerRef = useRef(null);
  const lineRefs = useRef({});
  function getLineRefs(i) {
    if (!lineRefs.current[i]) {
      lineRefs.current[i] = { item: React.createRef(), unit: React.createRef(), qty: React.createRef(), rate: React.createRef() };
    }
    return lineRefs.current[i];
  }

  useEffect(() => {
    fetchBrands().then((rows) => { setBrands(rows); if (rows.length && !brand) setBrand(rows[0]); });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { dateRef.current?.focus(); }, []);

  useEffect(() => {
    if (!isBill) return;
    let alive = true;
    fetchStockBalance().then((rows) => {
      if (!alive) return;
      const map = {};
      rows.forEach((r) => { map[r.item_id] = r; });
      setStockMap(map);
    });
    return () => { alive = false; };
  }, [isBill]);

  useEffect(() => {
    if (!isBill || !customer) { setSoOptions([]); return; }
    let alive = true;
    fetchOpenSaleOrders(customer.id).then((rows) => { if (alive) setSoOptions(rows); });
    return () => { alive = false; };
  }, [isBill, customer]);

  function switchBrand(b) {
    setBrand(b);
    setLines([emptySaleLine()]);
    setCustomer(null);
    setCustomerResetKey((k) => k + 1);
    setLinkedOrder(null);
    lineRefs.current = {};
  }

  function addLine(focus = true) {
    setLines((ls) => {
      const next = [...ls, emptySaleLine()];
      if (focus) {
        const idx = next.length - 1;
        requestAnimationFrame(() => getLineRefs(idx).item.current?.focus());
      }
      return next;
    });
  }
  function updateLine(i, patch) {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  }
  function removeLine(i) {
    setLines((ls) => (ls.length === 1 ? ls : ls.filter((_, idx) => idx !== i)));
  }

  function pickItemForLine(i, item) {
    updateLine(i, {
      itemId: item.id,
      itemName: item.name,
      unit: item.default_unit || purchaseUnitOptionsFor(brand?.category)[0],
      rate: item.last_sale_rate != null && !lines[i].rate ? String(item.last_sale_rate) : lines[i].rate,
    });
  }

  async function applyLinkedOrder(order) {
    if (!order) { setLinkedOrder(null); return; }
    try {
      const { items } = await fetchInvoiceWithItems(order.id);
      setLinkedOrder(order);
      setLines(items.map((it) => ({
        itemId: it.item_id, itemName: it.items?.name || it.description || '',
        unit: it.unit, quantity: String(it.quantity), rate: String(it.rate),
      })));
    } catch (e) {
      show(`Could not load sale order: ${e.message}`, 'danger');
    }
  }

  const subtotal = lines.reduce((s, l) => s + (Number(l.quantity) || 0) * (Number(l.rate) || 0), 0);
  const grandTotal = isBill
    ? subtotal + (Number(transport) || 0) + (Number(loadingCharge) || 0) + (Number(tax) || 0) - (Number(discount) || 0)
    : subtotal;

  function resetForm() {
    setLines([emptySaleLine()]);
    setCustomer(null);
    setCustomerResetKey((k) => k + 1);
    setCustomerPoNo('');
    setLinkedOrder(null);
    setTransport('0'); setLoadingCharge('0'); setDiscount('0'); setTax('0');
    lineRefs.current = {};
    requestAnimationFrame(() => dateRef.current?.focus());
  }

  async function save(closeAfter) {
    if (!brand || !customer) { show('Pick a category and a customer.', 'danger'); return; }
    const validLines = lines.filter((l) => l.itemId && Number(l.quantity) > 0 && Number(l.rate) >= 0);
    if (validLines.length === 0) { show('Add at least one line item.', 'danger'); return; }
    setSaving(true);
    try {
      const id = await createInvoice({
        invoiceType, brandKey: brand.brand_key, category: brand.category,
        partyId: customer.id, invoiceDate: date,
        items: validLines.map((l) => ({ itemId: l.itemId, quantity: l.quantity, unit: l.unit, rate: l.rate, description: l.itemName })),
        customerPoNo: isBill ? customerPoNo : undefined,
        linkedOrderId: isBill ? linkedOrder?.id : undefined,
        transport: isBill ? transport : undefined,
        loading: isBill ? loadingCharge : undefined,
        discount: isBill ? discount : undefined,
        tax: isBill ? tax : undefined,
      });
      const { invoice } = await fetchInvoiceWithItems(id);
      show(`Saved. ${invoice.invoice_no} created.`);
      setSavedNo(invoice.invoice_no);
      resetForm();
      if (isBill) fetchStockBalance().then((rows) => {
        const map = {};
        rows.forEach((r) => { map[r.item_id] = r; });
        setStockMap(map);
      });
      if (closeAfter) onSavedClose?.();
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  function buildDraft() {
    const pseudoInvoice = {
      invoice_no: savedNo || 'DRAFT', invoice_date: date, parties: { name: customer?.name },
      invoice_type: invoiceType, customer_po_no: customerPoNo,
      transport_charges: transport, loading_charges: loadingCharge, discount_amount: discount, tax_amount: tax,
      total_amount: grandTotal,
    };
    const pseudoItems = lines.filter((l) => l.itemId).map((l) => ({
      items: { name: l.itemName }, unit: l.unit, quantity: l.quantity, rate: l.rate,
      amount: (Number(l.quantity) || 0) * (Number(l.rate) || 0),
    }));
    return { pseudoInvoice, pseudoItems };
  }
  function draftPrint() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    printPdfDoc(buildSaleDocPdf(pseudoInvoice, pseudoItems));
  }
  function draftExportPdf() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    buildSaleDocPdf(pseudoInvoice, pseudoItems).save(`${pseudoInvoice.invoice_no}.pdf`);
  }

  useEffect(() => {
    function onKey(e) {
      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); save(false); }
      if (mod && e.key.toLowerCase() === 'p') { e.preventDefault(); draftPrint(); }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  if (!brand) return <div className="py-20 flex justify-center"><Spinner /></div>;

  const units = purchaseUnitOptionsFor(brand.category);

  function lineFields(i, line) {
    const stockRow = stockMap[line.itemId];
    const available = stockRow ? Number(stockRow.qty_on_hand) : null;
    const short = isBill && line.itemId && available !== null && Number(line.quantity) > available;
    return {
      item: (
        <ItemPicker
          category={brand.category}
          value={line.itemId ? { id: line.itemId, name: line.itemName } : null}
          onChange={(it) => pickItemForLine(i, it)}
          resetKey={`${i}-${line.itemId || 'empty'}`}
          inputRef={getLineRefs(i).item}
          onEnterNext={() => getLineRefs(i).unit.current?.focus()}
        />
      ),
      unit: (
        <Select
          ref={getLineRefs(i).unit}
          label="Unit"
          value={line.unit}
          onChange={(e) => updateLine(i, { unit: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).qty.current?.focus(); } }}
        >
          <option value="">—</option>
          {units.map((u) => <option key={u} value={u}>{u}</option>)}
        </Select>
      ),
      qty: (
        <div>
          <Input
            ref={getLineRefs(i).qty}
            type="number" label="Qty" value={line.quantity}
            onChange={(e) => updateLine(i, { quantity: e.target.value })}
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).rate.current?.focus(); } }}
          />
          {short && (
            <p className="text-xs mt-1" style={{ color: THEME.danger }}>
              Only {available} {line.unit || ''} in stock
            </p>
          )}
        </div>
      ),
      rate: (
        <Input
          ref={getLineRefs(i).rate}
          type="number" label="Rate" value={line.rate}
          onChange={(e) => updateLine(i, { rate: e.target.value })}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              if (i === lines.length - 1) addLine();
              else getLineRefs(i + 1).item.current?.focus();
            }
          }}
        />
      ),
      amount: formatPkr((Number(line.quantity) || 0) * (Number(line.rate) || 0)),
    };
  }

  return (
    <div className="max-w-5xl">
      <h2 className="font-display font-semibold text-lg mb-4">{title}</h2>

      <div className="flex flex-wrap items-end gap-4 mb-5">
        <BrandTabs brands={brands} value={brand} onChange={switchBrand} />
        <Input
          ref={dateRef} type="date" label="Date" value={date}
          onChange={(e) => setDate(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); customerRef.current?.focus(); } }}
        />
      </div>

      <div className="mb-5 max-w-md">
        <PartyPicker
          type="customer" value={customer} onChange={setCustomer}
          resetKey={customerResetKey} inputRef={customerRef} label="Customer"
          onEnterNext={() => getLineRefs(0).item.current?.focus()}
        />
      </div>

      {isBill && (
        <Card className="p-4 mb-5 grid sm:grid-cols-2 gap-3" style={{ borderColor: THEME.line }}>
          <Input label="Customer PO # (optional)" value={customerPoNo} onChange={(e) => setCustomerPoNo(e.target.value)} />
          <Select
            label="Load from Sale Order (optional)"
            value={linkedOrder?.id || ''}
            onChange={(e) => applyLinkedOrder(soOptions.find((o) => o.id === e.target.value) || null)}
          >
            <option value="">— none —</option>
            {soOptions.map((o) => (
              <option key={o.id} value={o.id}>{o.invoice_no} · {formatDate(o.invoice_date)} · {formatPkr(o.total_amount)}</option>
            ))}
          </Select>
          {!customer && <p className="text-xs text-gray-500 sm:col-span-2">Pick a customer first to see their open sale orders.</p>}
          {linkedOrder && <p className="text-xs text-gray-500 sm:col-span-2">Loaded from {linkedOrder.invoice_no} — quantities below are editable for partial billing.</p>}
        </Card>
      )}

      <div className="flex items-center justify-between mb-2">
        <h3 className="font-medium text-sm text-gray-700">Line items</h3>
        <Button variant="ghost" icon={Plus} onClick={() => addLine()}>Add line</Button>
      </div>

      {/* Desktop / tablet: Excel-like grid */}
      <Card className="hidden md:block overflow-auto" style={{ borderColor: THEME.line }}>
        <table className="w-full text-sm">
          <thead>
            <tr style={{ backgroundColor: THEME.surface }}>
              <th className="text-left font-medium px-3 py-2.5 w-2/5">Item</th>
              <th className="text-left font-medium px-3 py-2.5">Unit</th>
              <th className="text-left font-medium px-3 py-2.5">Qty</th>
              <th className="text-left font-medium px-3 py-2.5">Rate</th>
              <th className="text-left font-medium px-3 py-2.5">Amount</th>
              <th className="px-2 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lines.map((line, i) => {
              const f = lineFields(i, line);
              return (
                <tr key={i} className="border-t align-top" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{f.item}</td>
                  <td className="px-3 py-2 w-28">{f.unit}</td>
                  <td className="px-3 py-2 w-24">{f.qty}</td>
                  <td className="px-3 py-2 w-28">{f.rate}</td>
                  <td className="px-3 py-2 w-28 pt-4 font-medium">{f.amount}</td>
                  <td className="px-2 py-2 pt-4">
                    <button onClick={() => removeLine(i)} className="text-gray-400 hover:text-red-500">
                      <X size={18} />
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Card>

      {/* Mobile: step-card entry */}
      <div className="md:hidden space-y-3">
        {lines.map((line, i) => {
          const f = lineFields(i, line);
          return (
            <Card key={i} className="p-3 space-y-3" style={{ borderColor: THEME.line }}>
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-gray-500">Line {i + 1}</span>
                <button onClick={() => removeLine(i)} className="text-gray-400 hover:text-red-500">
                  <X size={18} />
                </button>
              </div>
              {f.item}
              <div className="grid grid-cols-2 gap-3">{f.unit}{f.qty}</div>
              <div className="grid grid-cols-2 gap-3 items-end">
                {f.rate}
                <div>
                  <span className="block text-sm font-medium text-gray-700 mb-1">Amount</span>
                  <div className="px-3 py-2.5 text-sm font-medium">{f.amount}</div>
                </div>
              </div>
            </Card>
          );
        })}
      </div>

      {isBill && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-5 max-w-xl ml-auto">
          <Input label="Transport" type="number" value={transport} onChange={(e) => setTransport(e.target.value)} />
          <Input label="Loading/Unloading" type="number" value={loadingCharge} onChange={(e) => setLoadingCharge(e.target.value)} />
          <Input label="Discount" type="number" value={discount} onChange={(e) => setDiscount(e.target.value)} />
          <Input label="Tax" type="number" value={tax} onChange={(e) => setTax(e.target.value)} />
        </div>
      )}

      <div className="flex items-center justify-end gap-2 mt-5 mb-6">
        <span className="text-gray-500">{isBill ? 'Grand Total:' : 'Total:'}</span>
        <span className="text-xl font-bold" style={{ color: THEME.blue }}>{formatPkr(grandTotal)}</span>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button onClick={() => save(false)} loading={saving}>Save</Button>
        <Button variant="outline" onClick={() => save(true)} loading={saving}>Save &amp; Close</Button>
        <Button variant="outline" icon={FileDown} onClick={draftPrint}>Print</Button>
        <Button variant="outline" icon={FileDown} onClick={draftExportPdf}>Export PDF</Button>
        {savedNo && <Badge tone="success">Last saved: {savedNo}</Badge>}
      </div>
      <p className="text-xs text-gray-500 mt-2">
        Enter moves Date → Customer → Item → Unit → Qty → Rate → next line. F2 on the customer field adds a customer, F3 on an item field adds an item. Ctrl+S saves, Ctrl+P prints the draft.
      </p>
      <ToastHost />
    </div>
  );
}

function buildSaleDocPdf(invoice, items) {
  const doc = new jsPDF();
  doc.setFontSize(14);
  doc.text('SKF PolyTex / SKF PolyBags', 14, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(`${saleDocLabel(invoice.invoice_type)} — ${invoice.invoice_no}`, 14, 23);
  doc.text(`Date: ${formatDate(invoice.invoice_date)}   Customer: ${invoice.parties?.name || ''}`, 14, 29);
  let startY = 35;
  if (invoice.customer_po_no) {
    doc.text(`Customer PO #: ${invoice.customer_po_no}`, 14, 35);
    startY = 41;
  }
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });

  const rows = items.map((it) => [it.items?.name || it.description || '', it.unit, String(it.quantity), formatPkr(it.rate), formatPkr(it.amount)]);
  const subtotal = items.reduce((s, it) => s + Number(it.amount || 0), 0);
  const foot = [['', '', '', 'Subtotal', formatPkr(subtotal)]];
  if (invoice.invoice_type === 'sale') {
    foot.push(['', '', '', 'Transport + Loading + Tax − Discount',
      formatPkr(Number(invoice.transport_charges || 0) + Number(invoice.loading_charges || 0)
        + Number(invoice.tax_amount || 0) - Number(invoice.discount_amount || 0))]);
  }
  foot.push(['', '', '', 'Grand Total', formatPkr(invoice.total_amount)]);

  autoTable(doc, {
    startY,
    head: [['Item', 'Unit', 'Qty', 'Rate', 'Amount']],
    body: rows,
    foot,
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    footStyles: { fillColor: [247, 248, 250], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 9, cellPadding: 3 },
  });
  return doc;
}

function SaleViewModal({ doc, onClose }) {
  if (!doc) return null;
  const { invoice, items } = doc;
  return (
    <Modal open={!!doc} onClose={onClose} title={invoice.invoice_no} width={560}>
      <div className="space-y-3 text-sm">
        <div className="grid grid-cols-2 gap-2">
          <div><span className="text-gray-500">Date:</span> {formatDate(invoice.invoice_date)}</div>
          <div><span className="text-gray-500">Customer:</span> {invoice.parties?.name}</div>
          <div><span className="text-gray-500">Status:</span> <Badge tone={invoice.status === 'voided' ? 'danger' : 'success'}>{invoice.status}</Badge></div>
          {invoice.customer_po_no && <div><span className="text-gray-500">Customer PO #:</span> {invoice.customer_po_no}</div>}
        </div>
        <Card className="overflow-auto" style={{ borderColor: THEME.line }}>
          <table className="w-full text-sm">
            <thead>
              <tr style={{ backgroundColor: THEME.surface }}>
                <th className="text-left px-3 py-2">Item</th>
                <th className="text-left px-3 py-2">Unit</th>
                <th className="text-left px-3 py-2">Qty</th>
                <th className="text-left px-3 py-2">Rate</th>
                <th className="text-left px-3 py-2">Amount</th>
              </tr>
            </thead>
            <tbody>
              {items.map((it) => (
                <tr key={it.id} className="border-t" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{it.items?.name || it.description}</td>
                  <td className="px-3 py-2">{it.unit}</td>
                  <td className="px-3 py-2">{it.quantity}</td>
                  <td className="px-3 py-2">{formatPkr(it.rate)}</td>
                  <td className="px-3 py-2">{formatPkr(it.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
        {invoice.invoice_type === 'sale' && (
          <div className="text-xs text-gray-500">
            Transport: {formatPkr(invoice.transport_charges)} · Loading: {formatPkr(invoice.loading_charges)} ·
            Tax: {formatPkr(invoice.tax_amount)} · Discount: {formatPkr(invoice.discount_amount)}
          </div>
        )}
        <div className="text-right font-bold" style={{ color: THEME.blue }}>Total: {formatPkr(invoice.total_amount)}</div>
      </div>
    </Modal>
  );
}

function SaleOldList({ invoiceType }) {
  const { permissions } = useAuth();
  const canApprove = !!permissions.entry_sale?.can_approve;

  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [customer, setCustomer] = useState(null);
  const [customerResetKey, setCustomerResetKey] = useState(0);
  const [invoiceNo, setInvoiceNo] = useState('');
  const [soNo, setSoNo] = useState('');
  const [rows, setRows] = useState(null);
  const [orderLookup, setOrderLookup] = useState({});
  const [viewDoc, setViewDoc] = useState(null);
  const [voidTarget, setVoidTarget] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchInvoices({ invoiceType, from, to, partyId: customer?.id, invoiceNo }).then((r) => { if (alive) setRows(r); });
    if (invoiceType === 'sale') {
      fetchInvoices({ invoiceType: 'sale_order', from: '2000-01-01', to: '2999-12-31' }).then((orders) => {
        if (!alive) return;
        const map = {};
        orders.forEach((o) => { map[o.id] = o.invoice_no; });
        setOrderLookup(map);
      });
    }
    return () => { alive = false; };
  }, [invoiceType, from, to, customer, invoiceNo, refreshKey]);

  const filtered = soNo
    ? (rows || []).filter((r) => (orderLookup[r.linked_order_id] || '').toLowerCase().includes(soNo.toLowerCase()))
    : rows;

  async function handleView(row) {
    try { setViewDoc(await fetchInvoiceWithItems(row.id)); }
    catch (e) { show(`Could not load document: ${e.message}`, 'danger'); }
  }
  async function handlePrint(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); printPdfDoc(buildSaleDocPdf(invoice, items)); }
    catch (e) { show(`Could not print: ${e.message}`, 'danger'); }
  }
  async function handleExportPdf(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); buildSaleDocPdf(invoice, items).save(`${invoice.invoice_no}.pdf`); }
    catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleExportExcel(row) {
    try {
      const { items } = await fetchInvoiceWithItems(row.id);
      exportExcel({
        title: row.invoice_no,
        columns: ['Item', 'Unit', 'Qty', 'Rate', 'Amount'],
        rows: items.map((it) => [it.items?.name || it.description || '', it.unit, it.quantity, it.rate, it.amount]),
      });
    } catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleVoidConfirm(reason) {
    try {
      await voidInvoice(voidTarget.id, reason);
      show(`${voidTarget.invoice_no} voided.`);
      setVoidTarget(null);
      setRefreshKey((k) => k + 1);
    } catch (e) {
      show(`Could not void: ${e.message}`, 'danger');
    }
  }

  return (
    <div>
      <div className="flex flex-wrap items-end gap-3 mb-5">
        <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />
        <div className="w-56">
          <PartyPicker type="customer" value={customer} onChange={setCustomer} resetKey={customerResetKey} label="Customer" />
        </div>
        <div className="w-40">
          <Input label="Invoice #" value={invoiceNo} onChange={(e) => setInvoiceNo(e.target.value)} placeholder="Search…" />
        </div>
        {invoiceType === 'sale' && (
          <div className="w-40">
            <Input label="SO #" value={soNo} onChange={(e) => setSoNo(e.target.value)} placeholder="Search…" />
          </div>
        )}
        {(customer || invoiceNo || soNo) && (
          <Button variant="ghost" onClick={() => { setCustomer(null); setCustomerResetKey((k) => k + 1); setInvoiceNo(''); setSoNo(''); }}>
            Clear
          </Button>
        )}
      </div>

      {filtered === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : filtered.length === 0 ? (
        <EmptyState>No {saleDocLabel(invoiceType).toLowerCase()} records in this range.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {filtered.map((row) => (
            <div key={row.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
              <div className="flex-1 min-w-[180px]">
                <div className="font-medium flex items-center gap-2">
                  {row.invoice_no}
                  {row.status === 'voided' && <Badge tone="danger">Voided</Badge>}
                  {invoiceType === 'sale' && orderLookup[row.linked_order_id] && (
                    <span className="text-xs text-gray-400">from {orderLookup[row.linked_order_id]}</span>
                  )}
                </div>
                <div className="text-xs text-gray-500">{formatDate(row.invoice_date)} · {row.parties?.name}</div>
              </div>
              <div className="font-semibold w-28 text-right" style={{ color: THEME.blue }}>{formatPkr(row.total_amount)}</div>
              <div className="flex items-center gap-1">
                <button onClick={() => handleView(row)} title="View" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <Search size={16} />
                </button>
                <button onClick={() => handlePrint(row)} title="Print" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportPdf(row)} title="Export PDF" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportExcel(row)} title="Export Excel" className="p-2 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileSpreadsheet size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => setVoidTarget(row)} title="Void" className="p-2 rounded-lg hover:bg-red-50 text-red-500">
                    <X size={16} />
                  </button>
                )}
              </div>
            </div>
          ))}
        </Card>
      )}

      <SaleViewModal doc={viewDoc} onClose={() => setViewDoc(null)} />
      <VoidReasonModal target={voidTarget} onClose={() => setVoidTarget(null)} onConfirm={handleVoidConfirm} />
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
      brandLogo={brand?.brand_key ? BRAND_LOGOS[brand.brand_key] : null}
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
    <ReportTable
      title="General Ledger"
      brandLabel={brand?.display_name}
      brandLogo={brand?.brand_key ? BRAND_LOGOS[brand.brand_key] : null}
      columns={['Date', 'Account', 'Party', 'Debit', 'Credit']}
      rows={table}
    />
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

      {profile?.is_admin && <DashboardAlertSettings />}
    </div>
  );
}

function DashboardAlertSettings() {
  const [lowCash, setLowCash] = useState('0');
  const [highPayables, setHighPayables] = useState('0');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    fetchAppSettings().then((s) => {
      setLowCash(String(s.low_cash_threshold ?? 0));
      setHighPayables(String(s.high_payables_threshold ?? 0));
    }).finally(() => setLoading(false));
  }, []);

  async function save() {
    setSaving(true);
    try {
      await updateAppSettings({ lowCashThreshold: Number(lowCash) || 0, highPayablesThreshold: Number(highPayables) || 0 });
      show('Alert thresholds saved.');
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card className="p-4">
      <div className="flex items-center gap-3 mb-3">
        <AlertTriangle size={20} style={{ color: THEME.danger }} />
        <div>
          <div className="font-medium">Dashboard alerts</div>
          <div className="text-xs text-gray-500">Trigger points for Low Cash Warning and High Payables Alert</div>
        </div>
      </div>
      {loading ? (
        <div className="py-6 flex justify-center"><Spinner /></div>
      ) : (
        <div className="space-y-3">
          <Input label="Low cash threshold (PKR)" type="number" value={lowCash} onChange={(e) => setLowCash(e.target.value)} />
          <Input label="High payables threshold (PKR)" type="number" value={highPayables} onChange={(e) => setHighPayables(e.target.value)} />
          <Button onClick={save} loading={saving}>Save thresholds</Button>
        </div>
      )}
      <ToastHost />
    </Card>
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
  const { session, permissionsReady } = useAuth();
  if (session === undefined || (session && !permissionsReady)) {
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
