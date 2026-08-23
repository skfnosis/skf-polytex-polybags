import React, { useState, useEffect, useMemo, useCallback, useRef, createContext, useContext } from 'react';
import {
  LayoutDashboard, ShoppingCart, Receipt, ClipboardList, BarChart3, Users, Settings,
  LogOut, Search, Plus, X, Calendar, ChevronRight, FileDown, FileSpreadsheet,
  ArrowUpRight, ArrowDownRight, ShieldCheck, Menu, AlertTriangle, Wallet, Landmark,
  BookOpen, Home, Package, Eye, EyeOff, Pencil,
} from 'lucide-react';
import { supabase } from './supabaseClient.js';
import logoSkfPolytex from './assets/logo-skf-polytex.png';
import logoSkfPolybags from './assets/logo-skf-polybags.png';

const GrowthChart = React.lazy(() => import('./GrowthChart.jsx'));

// jsPDF/autoTable are only needed when a document is actually printed or
// exported — dynamically imported and cached here so the initial bundle
// (and every page load) doesn't have to carry them upfront.
let _pdfLibsPromise = null;
function loadPdfLibs() {
  if (!_pdfLibsPromise) {
    _pdfLibsPromise = Promise.all([import('jspdf'), import('jspdf-autotable')])
      .then(([jsPdfMod, autoTableMod]) => ({ jsPDF: jsPdfMod.default, autoTable: autoTableMod.default }));
  }
  return _pdfLibsPromise;
}

// "Save as Image" rasterizes the actual generated PDF report (same one
// Print/Export PDF use) via pdf.js — never a screenshot of the live ERP
// screen. Loaded lazily, same pattern as loadPdfLibs.
let _pdfjsPromise = null;
function loadPdfJs() {
  if (!_pdfjsPromise) {
    _pdfjsPromise = Promise.all([import('pdfjs-dist'), import('pdfjs-dist/build/pdf.worker.min.mjs?url')])
      .then(([pdfjsLib, workerUrlMod]) => {
        pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrlMod.default;
        return pdfjsLib;
      });
  }
  return _pdfjsPromise;
}

async function pdfDocToPngDataUrl(doc, scale = 2.5) {
  const pdfjsLib = await loadPdfJs();
  const pdf = await pdfjsLib.getDocument({ data: doc.output('arraybuffer') }).promise;
  const page = await pdf.getPage(1);
  const viewport = page.getViewport({ scale });
  const canvas = document.createElement('canvas');
  canvas.width = viewport.width;
  canvas.height = viewport.height;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  await page.render({ canvasContext: ctx, viewport }).promise;
  return canvas.toDataURL('image/png');
}

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
  { key: 'entry_voucher', label: 'Vouchers', icon: Wallet },
  { key: 'entry_jv', label: 'General Voucher', icon: BookOpen },
  { key: 'entry_sale', label: 'Sales', icon: ShoppingCart },
  { key: 'entry_purchase', label: 'Purchase', icon: ClipboardList },
  { key: 'item_master', label: 'Material Chart', icon: Package },
  { key: 'party_master', label: 'Chart of Accounts', icon: Users },
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

const MASKED_AMOUNT = 'Rs ••••••';
function maskPkr(amount, visible) {
  return visible ? formatPkr(amount) : MASKED_AMOUNT;
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

async function fetchChartOfAccounts({ search = '', types = null } = {}) {
  let q = supabase.from('chart_of_accounts').select();
  if (search) q = q.ilike('name', `%${search}%`);
  if (types) q = q.in('type', types);
  const { data, error } = await q.order('name').limit(search ? 50 : 1000);
  if (error) throw error;
  return data;
}

async function createAccount({ name, type, cashBankKind, parentAccountId, openingBalance = 0, openingBalanceType = 'debit' }) {
  const { data, error } = await supabase.rpc('create_account', {
    p_name: name,
    p_type: type,
    p_cash_bank_kind: type === 'cash_bank' ? cashBankKind : null,
    p_parent_account_id: parentAccountId || null,
    p_opening_balance: Number(openingBalance) || 0,
    p_opening_balance_type: openingBalanceType,
  });
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

async function createParty({ name, type, category, contact, address, openingBalance = 0, email, ntn, stn }) {
  const { data, error } = await supabase.rpc('create_party', {
    p_name: name,
    p_type: type,
    p_category: category,
    p_contact: contact || null,
    p_address: address || null,
    p_opening_balance: openingBalance,
    p_email: email || null,
    p_ntn: ntn || null,
    p_stn: stn || null,
  });
  if (error) throw error;
  return data;
}

async function updateParty({ id, name, contact, address, email, ntn, stn, category }) {
  const { error } = await supabase.rpc('update_party', {
    p_party_id: id,
    p_name: name,
    p_contact: contact || null,
    p_address: address || null,
    p_email: email || null,
    p_ntn: ntn || null,
    p_stn: stn || null,
    p_category: category || null,
  });
  if (error) throw error;
}

async function fetchUnpostedDocuments() {
  const { data, error } = await supabase.rpc('fetch_unposted_documents');
  if (error) throw error;
  return data || [];
}

async function fetchItems({ search = '', category = null } = {}) {
  let q = supabase.from('items').select().eq('active', true);
  if (search) q = q.ilike('name', `%${search}%`);
  if (category) q = q.eq('category', category);
  const { data, error } = await q.order('name').limit(50);
  if (error) throw error;
  return data;
}

// Default quality for a brand-new Polybag purchase/sale line — "LLD Polybag"
// per the standard entry flow. Falls back to no default if that item was
// ever renamed/removed, rather than guessing at another item.
async function fetchDefaultPolybagItem() {
  const rows = await fetchItems({ search: 'LLD Polybag', category: 'polybags' });
  const exact = rows.find((r) => r.name.toLowerCase() === 'lld polybag');
  return exact ? { id: exact.id, name: exact.name } : null;
}

async function createItem({ name, category, defaultUnit, fabricGroup, composition, itemType }) {
  const { data, error } = await supabase.rpc('create_item', {
    p_name: name,
    p_category: category,
    p_default_unit: defaultUnit,
    p_fabric_group: fabricGroup || null,
    p_composition: composition || null,
    p_item_type: itemType || 'product',
  });
  if (error) throw error;
  return data;
}

async function updateItem({ id, name, defaultUnit, fabricGroup, composition }) {
  const { error } = await supabase.rpc('update_item', {
    p_item_id: id,
    p_name: name,
    p_default_unit: defaultUnit,
    p_fabric_group: fabricGroup || null,
    p_composition: composition || null,
  });
  if (error) throw error;
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
  const [{ data: invoice, error }, { data: items, error: itemsError }] = await Promise.all([
    supabase.from('invoices').select('*, parties(name)').eq('id', invoiceId).single(),
    supabase.from('invoice_items').select('*, items(name, item_type), parties(name)').eq('invoice_id', invoiceId),
  ]);
  if (error) throw error;
  if (itemsError) throw itemsError;
  return { invoice, items };
}

// Purchase Bill lines reserved for a customer (via the line's "Sell to"
// picker) that haven't been pulled into a Sale Bill yet — the Sale Bill's
// suggestion panel reads these once a customer is selected.
async function fetchOpenPurchaseReservations(partyId) {
  if (!partyId) return [];
  const { data, error } = await supabase.from('v_open_purchase_reservations').select().eq('reserved_for_party_id', partyId).order('invoice_date');
  if (error) throw error;
  return data || [];
}

// Every purchase line already pulled into some Sale Bill, as a Set of
// purchase invoice_item ids — used to badge a reserved purchase line
// "Billed" once it's been used, so it can't be suggested (or picked) twice.
async function fetchFulfilledPurchaseItemIds() {
  const { data, error } = await supabase.from('invoice_items').select('fulfilled_from_item_id').not('fulfilled_from_item_id', 'is', null);
  if (error) throw error;
  return new Set((data || []).map((r) => r.fulfilled_from_item_id));
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
  let openingBalance = 0;
  if (from) {
    const { data: prior, error: priorError } = await supabase.from('ledger_entries')
      .select('debit, credit').eq('account_id', accountId).lt('entry_date', from);
    if (priorError) throw priorError;
    openingBalance = (prior || []).reduce((s, r) => s + Number(r.debit) - Number(r.credit), 0);
  }

  let q = supabase.from('ledger_entries').select('*, parties(name)').eq('account_id', accountId);
  if (from) q = q.gte('entry_date', from);
  if (to) q = q.lte('entry_date', to);
  const { data, error } = await q.order('entry_date').order('created_at');
  if (error) throw error;
  let running = openingBalance;
  const rows = (data || []).map((r) => {
    running += Number(r.debit) - Number(r.credit);
    return { ...r, running_balance: running };
  });
  return { rows, openingBalance };
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

async function fetchSalesOverview({ from, to }) {
  const { data, error } = await supabase.rpc('dashboard_sales_overview', { p_from: from, p_to: to });
  if (error) throw error;
  return data || [];
}

async function fetchMonthlyBreakdown({ from, to }) {
  const { data, error } = await supabase.rpc('dashboard_monthly_breakdown', { p_from: from, p_to: to });
  if (error) throw error;
  return data || [];
}

async function fetchReceivablesOverdue() {
  const { data, error } = await supabase.rpc('dashboard_receivables_overdue');
  if (error) throw error;
  return data?.[0] || { total_receivables: 0, overdue_receivables: 0 };
}

async function fetchExpensesAndDrawings({ from, to }) {
  const [{ data: accounts, error: e1 }, { data: entries, error: e2 }] = await Promise.all([
    supabase.from('chart_of_accounts').select('id, type').in('type', ['expense', 'drawings']),
    supabase.from('ledger_entries').select('account_id, debit, credit').gte('entry_date', from).lte('entry_date', to),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  const typeById = {};
  (accounts || []).forEach((a) => { typeById[a.id] = a.type; });
  let expenses = 0;
  let drawings = 0;
  (entries || []).forEach((e) => {
    const t = typeById[e.account_id];
    if (t === 'expense') expenses += Number(e.debit) - Number(e.credit);
    else if (t === 'drawings') drawings += Number(e.debit) - Number(e.credit);
  });
  return { expenses, drawings };
}

async function fetchPartyBalances({ type, positiveOnly = false } = {}) {
  let q = supabase.from('v_party_balances').select().eq('type', type);
  const { data, error } = await q.order('balance', { ascending: false });
  if (error) throw error;
  return positiveOnly ? (data || []).filter((r) => r.balance > 0) : (data || []);
}

// Receivable/payable-nature balances that live on a plain Chart of Accounts
// row rather than a party — e.g. "Loans Receivable", "Committee Receivable",
// "Loans Payables" opened via Admin > Chart of Accounts. Total
// Receivable/Payable above only ever reflects customer/vendor party
// balances, so these need their own tally to not go missing from the
// Dashboard entirely.
async function fetchNonPartyAccountBalances(type) {
  const { data: accounts, error: e1 } = await supabase.from('chart_of_accounts').select('id, name').eq('type', type);
  if (e1) throw e1;
  if (!accounts || accounts.length === 0) return [];
  const ids = accounts.map((a) => a.id);
  const { data: entries, error: e2 } = await supabase.from('ledger_entries').select('account_id, debit, credit').in('account_id', ids);
  if (e2) throw e2;
  const balById = {};
  (entries || []).forEach((e) => {
    balById[e.account_id] = (balById[e.account_id] || 0) + Number(e.debit) - Number(e.credit);
  });
  return accounts
    .map((a) => ({ id: a.id, name: a.name, balance: balById[a.id] || 0 }))
    .filter((a) => a.balance !== 0)
    .sort((a, b) => Math.abs(b.balance) - Math.abs(a.balance));
}

async function fetchPaymentsSummary({ from, to }) {
  const { data, error } = await supabase.from('payments').select('amount, direction')
    .eq('status', 'posted').gte('payment_date', from).lte('payment_date', to);
  if (error) throw error;
  const received = (data || []).filter((p) => p.direction === 'receipt').reduce((s, p) => s + Number(p.amount), 0);
  const made = (data || []).filter((p) => p.direction === 'payment').reduce((s, p) => s + Number(p.amount), 0);
  return { received, made };
}

async function createInvoice({
  invoiceType, brandKey, category, partyId, invoiceDate, items,
  supplierInvoiceNo, linkedOrderId, transport, loading, discount, tax, customerPoNo, narration,
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
      narration: i.narration || '',
      item_type: i.itemType || 'product',
      reserved_for_party_id: i.reservedForPartyId || null,
      fulfilled_from_item_id: i.fulfilledFromItemId || null,
      color: i.color || null,
      gsm: i.gsm || null,
    })),
    p_supplier_invoice_no: supplierInvoiceNo || null,
    p_linked_order_id: linkedOrderId || null,
    p_transport: Number(transport) || 0,
    p_loading: Number(loading) || 0,
    p_discount: Number(discount) || 0,
    p_tax: Number(tax) || 0,
    p_customer_po_no: customerPoNo || null,
    p_narration: narration || null,
  });
  if (error) throw error;
  return data;
}

async function updateInvoice(invoiceId, {
  partyId, invoiceDate, items,
  supplierInvoiceNo, linkedOrderId, transport, loading, discount, tax, customerPoNo,
}) {
  const { error } = await supabase.rpc('update_invoice', {
    p_invoice_id: invoiceId,
    p_party_id: partyId,
    p_invoice_date: invoiceDate,
    p_items: items.map((i) => ({
      item_id: i.itemId || null,
      quantity: Number(i.quantity) || 0,
      unit: i.unit,
      rate: Number(i.rate) || 0,
      description: i.description || '',
      narration: i.narration || '',
      item_type: i.itemType || 'product',
      reserved_for_party_id: i.reservedForPartyId || null,
      fulfilled_from_item_id: i.fulfilledFromItemId || null,
      color: i.color || null,
      gsm: i.gsm || null,
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
}

async function voidInvoice(invoiceId, reason) {
  const { error } = await supabase.rpc('void_invoice', { p_invoice_id: invoiceId, p_reason: reason });
  if (error) throw error;
}

async function recordPayment({ paymentDate, partyId, directAccountId, direction, amount, method, cashBankAccountId, linkedInvoiceId, notes }) {
  const { data, error } = await supabase.rpc('record_payment', {
    p_payment_date: paymentDate,
    p_party_id: partyId || null,
    p_direction: direction,
    p_amount: Number(amount),
    p_method: method,
    p_cash_bank_account_id: cashBankAccountId,
    p_linked_invoice_id: linkedInvoiceId || null,
    p_notes: notes || null,
    p_direct_account_id: directAccountId || null,
  });
  if (error) throw error;
  return data;
}

// payments has two FKs into chart_of_accounts (the cash/bank leg and the
// optional direct expense/drawings leg), so the embed must name which
// column each side follows — an unqualified chart_of_accounts(...) embed
// is ambiguous once there's more than one relationship to the same table.
const PAYMENT_SELECT = '*, parties(name), chart_of_accounts!cash_bank_account_id(name, cash_bank_kind), direct_account:chart_of_accounts!direct_account_id(name)';

function paymentRecipientLabel(payment) {
  return payment.parties?.name || payment.direct_account?.name || '';
}

async function fetchPayments({ direction, kind, from, to, partyId, voucherNo }) {
  let q = supabase.from('payments').select(PAYMENT_SELECT)
    .eq('direction', direction).gte('payment_date', from).lte('payment_date', to);
  if (partyId) q = q.eq('party_id', partyId);
  if (voucherNo) q = q.ilike('voucher_no', `%${voucherNo}%`);
  const { data, error } = await q.order('payment_date');
  if (error) throw error;
  return kind ? (data || []).filter((r) => r.chart_of_accounts?.cash_bank_kind === kind) : data;
}

async function fetchPaymentById(id) {
  const { data, error } = await supabase.from('payments').select(PAYMENT_SELECT).eq('id', id).single();
  if (error) throw error;
  return data;
}

async function voidPayment(paymentId, reason) {
  const { error } = await supabase.rpc('void_payment', { p_payment_id: paymentId, p_reason: reason });
  if (error) throw error;
}

async function createJournalVoucher({ voucherDate, narration, lines }) {
  const { data, error } = await supabase.rpc('create_journal_voucher', {
    p_voucher_date: voucherDate,
    p_narration: narration || null,
    p_lines: lines.map((l) => ({
      account_id: l.accountId,
      debit: Number(l.debit) || 0,
      credit: Number(l.credit) || 0,
      narration: l.narration || '',
    })),
  });
  if (error) throw error;
  return data;
}

async function voidJournalVoucher(voucherId, reason) {
  const { error } = await supabase.rpc('void_journal_voucher', { p_voucher_id: voucherId, p_reason: reason });
  if (error) throw error;
}

async function fetchJournalVouchers({ from, to, voucherNo }) {
  let q = supabase.from('journal_vouchers').select().gte('voucher_date', from).lte('voucher_date', to);
  if (voucherNo) q = q.ilike('voucher_no', `%${voucherNo}%`);
  const { data, error } = await q.order('voucher_date');
  if (error) throw error;
  return data;
}

async function fetchJournalVoucherWithLines(voucherId) {
  const [{ data: voucher, error }, { data: lines, error: linesError }] = await Promise.all([
    supabase.from('journal_vouchers').select().eq('id', voucherId).single(),
    supabase.from('journal_voucher_lines').select('*, chart_of_accounts(name)').eq('voucher_id', voucherId),
  ]);
  if (error) throw error;
  if (linesError) throw linesError;
  return { voucher, lines };
}

async function fetchOutstandingInvoices(partyId, invoiceType) {
  const { data, error } = await supabase.from('v_invoice_outstanding').select()
    .eq('party_id', partyId).eq('invoice_type', invoiceType).gt('outstanding', 0)
    .order('invoice_date', { ascending: false });
  if (error) throw error;
  return data || [];
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

async function fetchTrialBalance() {
  const { data, error } = await supabase.from('v_trial_balance').select().order('type');
  if (error) throw error;
  return data;
}

// Filters on the party's own ledger account, not party_id — create_invoice/
// record_payment/etc. denormalize party_id onto BOTH ledger rows of a
// transaction (the party's own account AND the offsetting trade/cash
// account), so filtering by party_id alone pulls in both legs of every
// posting. Those always net to zero, which silently zeroed out every
// party's Statement page (same root cause v_party_balances had — see that
// migration's notes — just a second, unpatched code path).
async function fetchPartyStatement(ledgerAccountId) {
  const { data, error } = await supabase.from('ledger_entries')
    .select('*, chart_of_accounts(name), parties(name)').eq('account_id', ledgerAccountId).order('entry_date');
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
      className={cx('bg-white rounded-xl border shadow-sm', className)}
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
      <div className="fixed bottom-20 right-5 left-5 md:left-auto md:bottom-5 z-50">
        <div
          className="rounded-lg px-4 py-3 text-sm text-white shadow-lg md:ml-auto md:w-fit"
          style={{ backgroundColor: toast.tone === 'danger' ? THEME.danger : THEME.ink }}
        >
          {toast.message}
        </div>
      </div>
    ) : null;
  return { show, ToastHost };
}

// ============================================================================
// UNSAVED CHANGES GUARD — shared by every editable entry form (Purchase,
// Sale, CRV/BRV/CPV/BPV, Journal Voucher). Two browser mechanisms, two very
// different levels of control:
//
// 1. beforeunload — fires on tab close / refresh / typed URL navigation.
//    Browsers show only their own generic "Leave site?" dialog here and
//    ignore any custom text — a hard security restriction, not something
//    this app can style or word. We just arm/disarm it.
// 2. In-app physical/mobile Back button — this app has no URL routing at
//    all (pages are plain React state), so there's nothing for Back to
//    normally do except exit the SPA. We trap it with a dummy
//    history.pushState entry: the resulting popstate is intercepted before
//    it takes effect, our own Stay/Leave modal is shown, and the trap is
//    re-armed so the page doesn't actually move until the user confirms.
//    Each intercepted press adds one level to unwind, which unwindGuard()
//    accounts for when the user finally chooses to leave.
// ============================================================================
function useUnsavedChangesGuard(isDirty) {
  const [showConfirm, setShowConfirm] = useState(false);
  const armedRef = useRef(false);
  const depthRef = useRef(0);

  useEffect(() => {
    function onBeforeUnload(e) {
      if (!isDirty) return;
      e.preventDefault();
      e.returnValue = '';
    }
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [isDirty]);

  useEffect(() => {
    if (!isDirty) { armedRef.current = false; depthRef.current = 0; return; }
    if (!armedRef.current) {
      window.history.pushState({ __unsavedGuard: true }, '');
      armedRef.current = true;
      depthRef.current = 1;
    }
    function onPopState() {
      if (!armedRef.current) return;
      setShowConfirm(true);
      window.history.pushState({ __unsavedGuard: true }, '');
      depthRef.current += 1;
    }
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, [isDirty]);

  function stay() {
    setShowConfirm(false);
  }
  function leave() {
    armedRef.current = false;
    setShowConfirm(false);
    window.history.go(-depthRef.current);
  }

  return { showUnsavedConfirm: showConfirm, stayOnPage: stay, leavePage: leave };
}

function UnsavedChangesModal({ open, onStay, onLeave }) {
  return (
    <Modal open={open} onClose={onStay} title="Unsaved Changes" width={380}>
      <p className="text-sm text-gray-600 mb-4">
        You have unsaved changes on this page. If you leave now, they will be lost.
      </p>
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onStay}>Stay on Page</Button>
        <Button variant="danger" onClick={onLeave}>Leave Page</Button>
      </div>
    </Modal>
  );
}

// ============================================================================
// DRAFT AUTOSAVE — every change to an in-progress Purchase/Sale bill is
// mirrored to localStorage (debounced), so a crash, accidental tab close, or
// interruption before the Save button is clicked never loses already-typed
// lines. This is deliberately client-side only, not a server-side draft
// invoice: a half-finished document would otherwise need its own "draft"
// status woven through invoice numbering, stock, and ledger posting just to
// stay unbalanced-safe, for a problem this solves without touching the
// accounting schema at all. Cleared the moment the bill actually saves.
// ============================================================================
function useDraftAutosave(storageKey, snapshot, isDirty) {
  const [restorable, setRestorable] = useState(null); // { savedAt, data } | null
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    try {
      const raw = localStorage.getItem(storageKey);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (parsed && parsed.data) setRestorable(parsed);
      }
    } catch {
      // corrupted/blocked storage — just skip restore, not fatal
    }
    setChecked(true);
  }, [storageKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!checked || restorable) return; // don't clobber an unresolved restore prompt
    const t = setTimeout(() => {
      try {
        if (isDirty) {
          localStorage.setItem(storageKey, JSON.stringify({ savedAt: Date.now(), data: snapshot }));
        } else {
          localStorage.removeItem(storageKey);
        }
      } catch {
        // storage full/blocked — draft autosave is best-effort, not critical
      }
    }, 500);
    return () => clearTimeout(t);
  }, [storageKey, snapshot, isDirty, checked, restorable]); // eslint-disable-line react-hooks/exhaustive-deps

  function clearDraft() {
    try { localStorage.removeItem(storageKey); } catch { /* best-effort */ }
    setRestorable(null);
  }
  function dismissRestore() {
    clearDraft();
  }

  return { restorable, clearDraft, dismissRestore };
}

function RestoreDraftModal({ open, savedAt, onRestore, onDiscard }) {
  return (
    <Modal open={open} onClose={onDiscard} title="Unsaved Draft Found" width={400}>
      <p className="text-sm text-gray-600 mb-4">
        You have an unsaved entry from {savedAt ? new Date(savedAt).toLocaleString() : 'earlier'} that never got saved. Restore it and pick up where you left off?
      </p>
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onDiscard}>Discard</Button>
        <Button onClick={onRestore}>Restore Draft</Button>
      </div>
    </Modal>
  );
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
  const [email, setEmail] = useState('');
  const [ntn, setNtn] = useState('');
  const [stn, setStn] = useState('');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => { setName(prefillName || ''); }, [prefillName, open]);

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      const id = await createParty({ name: name.trim(), type, category: [category], contact, address, email, ntn, stn });
      onCreated({ id, name: name.trim(), type, category: [category], contact, address, email, ntn, stn });
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
        <Input label="Mobile number (optional)" value={contact} onChange={(e) => setContact(e.target.value)} />
        <Input label="Email (optional)" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Input label="Address (optional)" value={address} onChange={(e) => setAddress(e.target.value)} />
        <div className="grid grid-cols-2 gap-3">
          <Input label="NTN (optional)" value={ntn} onChange={(e) => setNtn(e.target.value)} />
          <Input label="STN (optional)" value={stn} onChange={(e) => setStn(e.target.value)} />
        </div>
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
              <div className="font-medium flex items-center gap-1.5">
                {it.name}
                {it.item_type === 'service' && (
                  <span className="text-[10px] font-semibold px-1.5 py-0.5 rounded" style={{ backgroundColor: THEME.blue + '1a', color: THEME.blue }}>SERVICE</span>
                )}
              </div>
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

const FABRIC_GROUPS = [
  { key: 'in_house', label: 'In House' },
];

function AddItemModal({ open, onClose, category, prefillName, onCreated }) {
  const [name, setName] = useState(prefillName || '');
  const [unit, setUnit] = useState(purchaseUnitOptionsFor(category)[0]);
  const [fabricGroup, setFabricGroup] = useState(FABRIC_GROUPS[0].key);
  const [composition, setComposition] = useState('');
  const [itemType, setItemType] = useState('product');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();
  const isFabric = category === 'fabric';

  useEffect(() => { setName(prefillName || ''); }, [prefillName, open]);
  useEffect(() => { setUnit(purchaseUnitOptionsFor(category)[0]); }, [category, open]);
  useEffect(() => { setItemType('product'); }, [open]);

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      const id = await createItem({
        name: name.trim(), category, defaultUnit: unit,
        fabricGroup: isFabric ? fabricGroup : null,
        composition: isFabric ? composition : null,
        itemType,
      });
      onCreated({ id, name: name.trim(), category, default_unit: unit, fabric_group: isFabric ? fabricGroup : null, composition: isFabric ? composition : null, item_type: itemType });
    } catch (e) {
      show(`Could not add item: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={isFabric ? 'New fabric' : 'New item / quality'}>
      <div className="space-y-3">
        <div>
          <div className="text-sm font-medium mb-1.5" style={{ color: THEME.ink }}>Type</div>
          <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
            {[{ key: 'product', label: 'Product' }, { key: 'service', label: 'Service' }].map((t) => (
              <button
                key={t.key}
                type="button"
                onClick={() => setItemType(t.key)}
                className="px-3 py-1.5 rounded-md text-sm font-medium"
                style={itemType === t.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
              >
                {t.label}
              </button>
            ))}
          </div>
        </div>
        {isFabric && (
          <div>
            <div className="text-sm font-medium mb-1.5" style={{ color: THEME.ink }}>Group</div>
            <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
              {FABRIC_GROUPS.map((g) => (
                <button
                  key={g.key}
                  type="button"
                  onClick={() => setFabricGroup(g.key)}
                  className="px-3 py-1.5 rounded-md text-sm font-medium"
                  style={fabricGroup === g.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
                >
                  {g.label}
                </button>
              ))}
            </div>
          </div>
        )}
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        {isFabric && (
          <Input label="Composition (optional)" placeholder="e.g. 65% Cotton, 35% Polyester" value={composition} onChange={(e) => setComposition(e.target.value)} />
        )}
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
// ACCOUNT PICKER — searchable combobox over chart_of_accounts (used by
// Journal Voucher lines). No inline "add new" — accounts are managed on
// the Admin page, not created mid-entry the way parties/items are.
// ============================================================================

function AccountPicker({ value, onChange, resetKey, inputRef, onEnterNext, types = null, label = 'Account', placeholder = 'Search accounts…' }) {
  const [query, setQuery] = useState(value?.name || '');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [highlight, setHighlight] = useState(0);
  const boxRef = useRef(null);

  useEffect(() => {
    setQuery(value?.name || '');
  }, [resetKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    let alive = true;
    setLoading(true);
    fetchChartOfAccounts({ search: query, types })
      .then((rows) => { if (alive) { setResults(rows); setHighlight(0); } })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [query]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    function onDocClick(e) {
      if (boxRef.current && !boxRef.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, []);

  function pick(a) {
    onChange(a);
    setQuery(a.name);
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
    }
  }

  return (
    <div className="relative" ref={boxRef}>
      <Input
        ref={inputRef}
        label={label}
        placeholder={placeholder}
        value={query}
        onFocus={() => setOpen(true)}
        onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
        onKeyDown={handleKeyDown}
      />
      {open && (
        <div className="absolute z-40 mt-1 w-full bg-white rounded-lg border shadow-lg max-h-64 overflow-auto" style={{ borderColor: THEME.line }}>
          {loading && <div className="p-3 text-sm text-gray-500">Searching…</div>}
          {!loading && results.length === 0 && <div className="p-3 text-sm text-gray-500">No accounts found.</div>}
          {!loading && results.map((a, i) => (
            <button
              key={a.id}
              type="button"
              className={cx('w-full text-left px-3 py-2 text-sm', i === highlight ? 'bg-gray-100' : 'hover:bg-gray-50')}
              onMouseEnter={() => setHighlight(i)}
              onClick={() => pick(a)}
            >
              <div className="font-medium">{a.name}</div>
              <div className="text-xs text-gray-500 capitalize">{a.type.replace('_', ' ')}</div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// ============================================================================
// BRAND TABS
// ============================================================================

function BrandTabs({ brands, value, onChange, allowAll = false }) {
  return (
    <div className="flex md:inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
      {allowAll && (
        <button
          type="button"
          onClick={() => onChange(null)}
          className="flex-1 md:flex-none px-3 py-1.5 rounded-md text-sm font-medium transition"
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
          className="flex-1 md:flex-none px-3 py-1.5 rounded-md text-sm font-medium transition flex items-center justify-center gap-1.5"
          style={value?.brand_key === b.brand_key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
        >
          {BRAND_LOGOS[b.brand_key] && (
            <img src={BRAND_LOGOS[b.brand_key]} alt="" className="w-4 h-4 object-contain flex-shrink-0" />
          )}
          {b.display_name}
        </button>
      ))}
    </div>
  );
}

// Compact, full-width, equal-segment tab bar for mobile — guarantees every
// option stays on one line regardless of label length, unlike the desktop
// pill row (flex-wrap) which can wrap onto multiple lines on a narrow screen.
function SegmentedBar({ options, value, onChange }) {
  return (
    <div className="flex w-full rounded-lg border overflow-hidden" style={{ borderColor: THEME.line }}>
      {options.map((o) => (
        <button
          key={o.key}
          type="button"
          onClick={() => onChange(o.key)}
          className="flex-1 px-1.5 py-2 text-xs font-medium text-center truncate"
          style={value === o.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
        >
          {o.label}
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

// Centered branding footer on every generated PDF page — deliberately just
// the company name, no URL. Printing the raw app webpage (Ctrl+P on a live
// screen) is what stamps the browser's own header/footer with the deployment
// URL; every document in this app is generated via jsPDF instead specifically
// to avoid that, so this is the only footer that should ever appear.
const REPORT_FOOTER_TEXT = 'SKF PolyTex / SKF PolyBags · ERP';
function drawPdfFooter(doc) {
  const pageWidth = doc.internal.pageSize.getWidth();
  const pageHeight = doc.internal.pageSize.getHeight();
  doc.setFontSize(8);
  doc.setTextColor(150);
  doc.text(REPORT_FOOTER_TEXT, pageWidth / 2, pageHeight - 10, { align: 'center' });
}

// Builds a professional, fixed-size (A4) report document — used for both the
// "PDF" (save to disk) and "Print" (open + browser print dialog) buttons, so
// what you print is exactly what you'd download, never the raw dashboard
// webpage. That raw-webpage route is what produces the broken multi-page,
// browser-chrome-labeled ("https://...vercel.app") print output — going
// through jsPDF instead sidesteps it entirely, and lets us put our own
// branded footer on every page instead of the browser's.
async function buildReportPdf({ title, brandLabel, brandLogo, columns, rows, totalsRow }) {
  const { jsPDF, autoTable } = await loadPdfLibs();
  const doc = new jsPDF();
  let textX = 14;
  try {
    if (brandLogo) {
      const dataUrl = await loadImageAsDataUrl(brandLogo);
      doc.addImage(dataUrl, 'PNG', 14, 8, 16, 16);
      textX = 34;
    } else {
      const [logo1, logo2] = await Promise.all([
        loadImageAsDataUrl(logoSkfPolytex),
        loadImageAsDataUrl(logoSkfPolybags),
      ]);
      doc.addImage(logo1, 'PNG', 14, 8, 14, 14);
      doc.addImage(logo2, 'PNG', 29, 8, 14, 14);
      textX = 47;
    }
  } catch {
    // fall back to text-only header if a logo can't be loaded
  }
  doc.setFontSize(14);
  doc.text(brandLabel || 'SKF PolyTex / SKF PolyBags', textX, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(title, textX, 23);
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });
  autoTable(doc, {
    startY: 32,
    head: [columns],
    body: rows,
    foot: totalsRow ? [totalsRow] : undefined,
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    footStyles: { fillColor: [247, 248, 250], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 8.5, cellPadding: 3 },
    didDrawPage: () => drawPdfFooter(doc),
  });
  return doc;
}

async function exportPdf(args) {
  const doc = await buildReportPdf(args);
  doc.save(`${slug(args.title)}.pdf`);
}

async function printReportPdf(args) {
  const doc = await buildReportPdf(args);
  printPdfDoc(doc);
}

// xlsx is a large, non-tree-shakeable library only needed when someone
// actually clicks "Export Excel" — dynamically imported here instead of at
// the top of the file so it doesn't sit in the bundle every page load has
// to download before rendering.
async function exportExcel({ title, columns, rows }) {
  const XLSX = await import('xlsx');
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
            onClick={() => printReportPdf({ title, brandLabel, brandLogo, columns, rows, totalsRow })}
          >
            Print
          </Button>
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

  const LIME = '#C6F135';

  return (
    <div
      className="min-h-screen flex flex-col items-center justify-center p-6"
      style={{ background: 'radial-gradient(circle at 50% 0%, #1A1F16 0%, #0B0C0A 55%)' }}
    >
      <div className="w-full max-w-sm flex-1 flex flex-col justify-center py-8">
        <div className="text-center mb-6">
          <p dir="rtl" lang="ar" className="font-arabic leading-loose text-sm" style={{ color: '#C7CDC5' }}>
            اللَّهُمَّ صَلِّ عَلَى مُحَمَّدٍ وَعَلَى آلِ مُحَمَّدٍ كَمَا صَلَّيْتَ عَلَى إِبْرَاهِيمَ وَعَلَى آلِ إِبْرَاهِيمَ، إِنَّكَ حَمِيدٌ مَجِيدٌ،
            اللَّهُمَّ بَارِكَ عَلَى مُحَمَّدٍ وَعَلَى آلِ مُحَمَّدٍ كَمَا بَارَكْتَ عَلَى إِبْرَاهِيمَ وَعَلَى آلِ إِبْرَاهِيمَ، إِنَّكَ حَمِيدٌ مَجِيدٌ
          </p>
        </div>

        <div className="flex flex-col items-center mb-6 text-center">
          <div className="h-16 w-16 rounded-2xl bg-white flex items-center justify-center overflow-hidden mb-4">
            <img src={logoSkfPolytex} alt="SKF" className="h-12 w-12 object-contain" />
          </div>
          <h1 className="font-display font-bold text-xl text-white">SKF ERP</h1>
          <p className="text-sm mt-1" style={{ color: '#9AA39A' }}>Sign in to the ERP</p>
        </div>

        <form onSubmit={submit}>
          <Card className="p-6 space-y-4" style={{ borderTop: `3px solid ${LIME}` }}>
            <Input label="Username" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus required />
            <Input label="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} required />
            {error && <p className="text-sm" style={{ color: THEME.danger }}>{error}</p>}
            <button
              type="submit"
              disabled={loading}
              className="w-full mt-1 rounded-lg px-4 py-2.5 text-sm font-semibold transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
              style={{ backgroundColor: LIME, color: '#12141C' }}
            >
              {loading && <Spinner size={16} />}
              Sign in
            </button>
          </Card>
        </form>
      </div>

      <p className="text-xs pb-2" style={{ color: '#5B6158' }}>Software by SKFnosis &middot; Saad Islam Butt</p>
    </div>
  );
}

// ============================================================================
// APP SHELL — sidebar nav built from the signed-in user's visible pages.
// ============================================================================

const NAV_GROUPS = [
  { label: 'Dashboard', keys: ['dashboard'] },
  { label: 'Entry', keys: ['entry_voucher', 'entry_jv'] },
  { label: 'Sale', keys: ['entry_sale'] },
  { label: 'Purchase', keys: ['entry_purchase'] },
  { label: 'Material Chart', keys: ['item_master'] },
  { label: 'Chart of Accounts', keys: ['party_master'] },
  { label: 'Admin', keys: ['settings'] },
];

const LAST_PAGE_KEY = 'skf_last_page';
function loadLastPage() {
  try {
    const raw = localStorage.getItem(LAST_PAGE_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function AppShell() {
  const { profile, visiblePages, signOut, authError } = useAuth();
  // Reopens on whatever page/tab/mode you last had open — including an
  // in-progress "New" entry form, so a reload lands you right back where
  // the draft-restore prompt (if any) will show, instead of the Dashboard.
  const lastPage = loadLastPage();
  const [current, setCurrent] = useState(lastPage?.page || null);
  const [pageParam, setPageParam] = useState(lastPage?.param || null);
  // Distinguishes "opened the page normally" (land on the entries list, mode
  // stays null -> module defaults to 'old') from "tapped a quick-add
  // shortcut" (mode 'new' -> module jumps straight into the entry form).
  const [pageMode, setPageMode] = useState(lastPage?.mode || null);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  useEffect(() => {
    if (!current && visiblePages.length > 0) setCurrent(visiblePages[0]);
    if (current && !visiblePages.includes(current) && visiblePages.length > 0) setCurrent(visiblePages[0]);
  }, [visiblePages]); // eslint-disable-line react-hooks/exhaustive-deps

  function go(pageKey, param = null, mode = null) {
    setCurrent(pageKey);
    setPageParam(param);
    setPageMode(mode);
    setMobileNavOpen(false);
    try { localStorage.setItem(LAST_PAGE_KEY, JSON.stringify({ page: pageKey, param, mode })); } catch { /* best-effort */ }
  }

  const visibleGroups = NAV_GROUPS
    .map((g) => ({ ...g, keys: g.keys.filter((k) => visiblePages.includes(k)) }))
    .filter((g) => g.keys.length > 0);

  if (visiblePages.length === 0) {
    return (
      <div className="min-h-screen flex flex-col">
        <TopNav profile={profile} onSignOut={signOut} groups={[]} current={current} onSelect={go} />
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
        current={current} onSelect={go}
        mobileNavOpen={mobileNavOpen} onMenuClick={() => setMobileNavOpen((v) => !v)}
      />
      <main className="flex-1 p-4 md:p-6 overflow-auto pb-24 md:pb-6">
        <PageRouter page={current} param={pageParam} mode={pageMode} onNavigate={go} />
      </main>
      <MobileTabBar current={current} onNavigate={go} visiblePages={visiblePages} />
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

function PageRouter({ page, param, mode, onNavigate }) {
  switch (page) {
    case 'dashboard': return <DashboardScreen onNavigate={onNavigate} />;
    case 'entry_voucher': return <VoucherModule key={`${param}_${mode}`} initialTab={param} initialMode={mode} />;
    case 'entry_jv': return <JournalVoucherModule />;
    case 'entry_sale': return <SalesModule key={`${param}_${mode}`} initialTab={param} initialMode={mode} />;
    case 'entry_purchase': return <PurchaseModule key={`${param}_${mode}`} initialTab={param} initialMode={mode} />;
    case 'item_master': return <MaterialChartScreen />;
    case 'party_master': return <ChartOfAccountsScreen key={param} initialTab={param} />;
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

// Combined-balance card: one big total (all accounts of this kind summed),
// with each individual account listed underneath in smaller text when
// there's more than one — e.g. two bank accounts still show one Bank
// Balance card, not two. Single-account case just shows the big number.
function CashBankCard({ title, icon: Icon, total, accounts, onSelectAccount, visible = true }) {
  return (
    <Card className="p-4 h-full">
      <div className="flex items-center justify-between mb-2">
        <span className="text-sm font-medium text-gray-500">{title}</span>
        {Icon && <Icon size={16} style={{ color: THEME.cashGreen }} />}
      </div>
      <div className="font-bold text-2xl" style={{ color: THEME.cashGreen }}>{maskPkr(total, visible)}</div>
      {accounts.length > 1 && (
        <div className="mt-2 space-y-1">
          {accounts.map((a) => (
            <button
              key={a.id}
              onClick={() => onSelectAccount(a)}
              className="w-full flex items-center justify-between text-xs text-gray-500 hover:text-gray-800"
            >
              <span>{a.name}</span>
              <span>{maskPkr(a.balance, visible)}</span>
            </button>
          ))}
        </div>
      )}
      {accounts.length === 1 && (
        <button onClick={() => onSelectAccount(accounts[0])} className="text-xs text-gray-500 mt-1.5 hover:text-gray-800">
          Tap for ledger
        </button>
      )}
    </Card>
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

function AccountLedgerBody({ account, from, to }) {
  const [data, setData] = useState(null);
  const [showReport, setShowReport] = useState(false);

  useEffect(() => {
    if (!account) { setData(null); return; }
    let alive = true;
    setData(null);
    fetchAccountLedger(account.id, { from, to }).then((r) => { if (alive) setData(r); });
    return () => { alive = false; };
  }, [account, from, to]);

  if (!account) return null;
  if (data === null) return <div className="py-10 flex justify-center"><Spinner /></div>;

  const rows = data.rows;

  return (
    <div className="space-y-3">
      <div className="flex justify-end">
        <Button variant="outline" icon={FileDown} onClick={() => setShowReport(true)} disabled={rows.length === 0 && !data.openingBalance}>
          Report
        </Button>
      </div>
      {rows.length === 0 && !data.openingBalance ? (
        <EmptyState>No transactions in this range.</EmptyState>
      ) : (
        <Card className="overflow-auto" style={{ borderColor: THEME.line }}>
          <table className="w-full text-sm">
            <thead>
              <tr style={{ backgroundColor: THEME.surface }}>
                <th className="text-left px-3 py-2">Date</th>
                <th className="text-left px-3 py-2">Voucher No.</th>
                <th className="text-left px-3 py-2">Narration</th>
                <th className="text-left px-3 py-2">Debit</th>
                <th className="text-left px-3 py-2">Credit</th>
                <th className="text-left px-3 py-2">Balance</th>
              </tr>
            </thead>
            <tbody>
              {data.openingBalance !== 0 && (
                <tr className="border-t bg-gray-50" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2" colSpan={5}>Opening Balance</td>
                  <td className="px-3 py-2 font-medium">{formatPkr(data.openingBalance)}</td>
                </tr>
              )}
              {rows.map((r) => (
                <tr key={r.id} className="border-t" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{formatDate(r.entry_date)}</td>
                  <td className="px-3 py-2">{r.doc_no || ''}</td>
                  <td className="px-3 py-2 text-gray-500">{r.narration || ''}</td>
                  <td className="px-3 py-2">{r.debit > 0 ? formatPkr(r.debit) : ''}</td>
                  <td className="px-3 py-2">{r.credit > 0 ? formatPkr(r.credit) : ''}</td>
                  <td className="px-3 py-2 font-medium">{formatPkr(r.running_balance)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <SimpleReportModal
        open={showReport} onClose={() => setShowReport(false)}
        title={`General Ledger — ${account.name}`}
        buildPdfDoc={() => buildLedgerPdf({ account, rows, openingBalance: data.openingBalance, from, to })}
        excelData={{
          columns: ['Date', 'Voucher No.', 'Narration', 'Debit', 'Credit', 'Balance'],
          rows: [
            ...(data.openingBalance ? [['', '', 'Opening Balance', '', '', data.openingBalance]] : []),
            ...rows.map((r) => [formatDate(r.entry_date), r.doc_no || '', r.narration || '', Number(r.debit) || '', Number(r.credit) || '', r.running_balance]),
          ],
        }}
      />
    </div>
  );
}

function AccountLedgerModal({ account, from, to, onClose }) {
  return (
    <Modal open={!!account} onClose={onClose} title={account ? `${account.name} — Ledger` : ''} width={640}>
      <AccountLedgerBody account={account} from={from} to={to} />
    </Modal>
  );
}

// Professional General Ledger report — SKF logo, GENERAL LEDGER title, date
// range, account name, then Date/Voucher No./Narration/Debit/Credit/Balance
// with the opening balance carried in as the first row.
async function buildLedgerPdf({ account, rows, openingBalance, from, to }) {
  const { jsPDF, autoTable } = await loadPdfLibs();
  const doc = new jsPDF();
  let textX = 14;
  try {
    const [logo1, logo2] = await Promise.all([loadImageAsDataUrl(logoSkfPolytex), loadImageAsDataUrl(logoSkfPolybags)]);
    doc.addImage(logo1, 'PNG', 14, 8, 14, 14);
    doc.addImage(logo2, 'PNG', 29, 8, 14, 14);
    textX = 47;
  } catch {
    // fall back to text-only header if the logos can't be loaded
  }
  doc.setFontSize(14);
  doc.text('GENERAL LEDGER', textX, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(account?.name || '', textX, 23);
  const rangeLabel = from && to ? `${formatDate(from)} to ${formatDate(to)}` : 'All dates';
  doc.text(rangeLabel, textX, 29);
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });

  const body = [
    ...(openingBalance ? [['', '', 'Opening Balance', '', '', formatPkr(openingBalance)]] : []),
    ...rows.map((r) => [
      formatDate(r.entry_date), r.doc_no || '', r.narration || '',
      r.debit > 0 ? formatPkr(r.debit) : '', r.credit > 0 ? formatPkr(r.credit) : '', formatPkr(r.running_balance),
    ]),
  ];
  const closing = rows.length > 0 ? rows[rows.length - 1].running_balance : openingBalance;

  autoTable(doc, {
    startY: 35,
    head: [['Date', 'Voucher No.', 'Narration', 'Debit', 'Credit', 'Balance']],
    body,
    foot: [['', '', '', '', 'Closing Balance', formatPkr(closing)]],
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    footStyles: { fillColor: [247, 248, 250], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 8.5, cellPadding: 3 },
    didDrawPage: () => drawPdfFooter(doc),
  });
  return doc;
}

const MONTHLY_PROFIT_TOGGLES = [
  { key: 'total', label: 'Total Profit' },
  { key: 'sales', label: 'Total Sales' },
  { key: 'fabric_sales', label: 'Fabric Sales' },
  { key: 'polybag_sales', label: 'Poly Bag Sales' },
];

const ANALYSIS_RANGE_OPTIONS = [
  { key: 'this_month', label: 'This Month' },
  { key: '3m', label: 'Last 3 Months' },
  { key: '6m', label: 'Last 6 Months' },
  { key: 'custom', label: 'Custom' },
];

function analysisDateRange(range, customFrom, customTo) {
  const today = new Date();
  if (range === 'this_month') return { from: toDateInput(startOfMonth()), to: toDateInput(today) };
  if (range === '3m') return { from: toDateInput(new Date(today.getFullYear(), today.getMonth() - 2, 1)), to: toDateInput(today) };
  if (range === 'custom') return { from: customFrom, to: customTo };
  return { from: toDateInput(new Date(today.getFullYear(), today.getMonth() - 5, 1)), to: toDateInput(today) }; // 6m default
}

function DashboardScreen({ onNavigate }) {
  const { visiblePages } = useAuth();
  const [addSheetOpen, setAddSheetOpen] = useState(false);
  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [loading, setLoading] = useState(true);

  const [cashBank, setCashBank] = useState([]);
  const [salesOverview, setSalesOverview] = useState([]);
  const [paymentsSummary, setPaymentsSummary] = useState({ received: 0, made: 0 });
  const [receivables, setReceivables] = useState({ total_receivables: 0, overdue_receivables: 0 });
  const [payables, setPayables] = useState([]);
  const [customerBalances, setCustomerBalances] = useState([]);
  const [otherReceivables, setOtherReceivables] = useState([]); // non-party asset accounts, e.g. Loans/Committee Receivable
  const [otherPayables, setOtherPayables] = useState([]); // non-party liability accounts, e.g. Loans Payables
  const [expensesAndDrawings, setExpensesAndDrawings] = useState({ expenses: 0, drawings: 0 });
  const [monthlyBreakdown, setMonthlyBreakdown] = useState([]);
  const [breakdownLoading, setBreakdownLoading] = useState(true);
  const [profitToggle, setProfitToggle] = useState('total');
  const [appSettings, setAppSettings] = useState({ low_cash_threshold: 0, high_payables_threshold: 0 });

  // Historical analysis range — independent of the Cash/Sale/Receivable
  // filter bar above, since "how did the last 6 months trend" is a
  // different question from "what happened this period". Changing it only
  // re-fetches the one breakdown RPC, not the whole dashboard.
  const [analysisRange, setAnalysisRange] = useState('6m'); // this_month | 3m | 6m | custom
  const [analysisCustomFrom, setAnalysisCustomFrom] = useState(toDateInput(startOfMonth()));
  const [analysisCustomTo, setAnalysisCustomTo] = useState(toDateInput(new Date()));

  const [ledgerAccount, setLedgerAccount] = useState(null); // { id, name } | null
  const [receivablesModalOpen, setReceivablesModalOpen] = useState(false);
  const [payablesModalOpen, setPayablesModalOpen] = useState(false);
  const [otherReceivablesModalOpen, setOtherReceivablesModalOpen] = useState(false);
  const [otherPayablesModalOpen, setOtherPayablesModalOpen] = useState(false);
  // Hidden by default every time the dashboard opens — pure client-side
  // toggle (no refetch), never persisted, so a fresh open always re-masks.
  const [balancesVisible, setBalancesVisible] = useState(false);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    Promise.all([
      fetchCashBankBalances(),
      fetchSalesOverview({ from, to }),
      fetchPaymentsSummary({ from, to }),
      fetchReceivablesOverdue(),
      fetchPartyBalances({ type: 'supplier' }),
      fetchPartyBalances({ type: 'customer', positiveOnly: true }),
      fetchNonPartyAccountBalances('asset'),
      fetchNonPartyAccountBalances('liability'),
      fetchExpensesAndDrawings({ from, to }),
      fetchAppSettings(),
    ]).then(([cb, so, ps, rec, pay, debtors, otherRec, otherPay, ed, settings]) => {
      if (!alive) return;
      setCashBank(cb);
      setSalesOverview(so); setPaymentsSummary(ps); setReceivables(rec);
      setPayables(pay.filter((p) => p.balance < 0));
      setCustomerBalances(debtors);
      setOtherReceivables(otherRec.filter((a) => a.balance > 0));
      setOtherPayables(otherPay.filter((a) => a.balance < 0));
      setExpensesAndDrawings(ed);
      setAppSettings(settings);
    }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [from, to]);

  const { from: analysisFrom, to: analysisTo } = analysisDateRange(analysisRange, analysisCustomFrom, analysisCustomTo);

  useEffect(() => {
    let alive = true;
    setBreakdownLoading(true);
    fetchMonthlyBreakdown({ from: analysisFrom, to: analysisTo })
      .then((rows) => { if (alive) setMonthlyBreakdown(rows); })
      .finally(() => { if (alive) setBreakdownLoading(false); });
    return () => { alive = false; };
  }, [analysisFrom, analysisTo]);

  if (loading && cashBank.length === 0) {
    return <div className="py-20 flex justify-center"><Spinner /></div>;
  }

  const cashAccounts = cashBank.filter((a) => a.cash_bank_kind === 'cash');
  const bankAccounts = cashBank.filter((a) => a.cash_bank_kind === 'bank');
  const cashTotal = cashAccounts.reduce((s, a) => s + Number(a.balance), 0);
  const bankTotal = bankAccounts.reduce((s, a) => s + Number(a.balance), 0);
  const payablesTotal = payables.reduce((s, p) => s - Number(p.balance), 0);
  const otherReceivablesTotal = otherReceivables.reduce((s, a) => s + Number(a.balance), 0);
  const otherPayablesTotal = otherPayables.reduce((s, a) => s - Number(a.balance), 0);
  const salesTotal = salesOverview.reduce((s, r) => s + Number(r.amount), 0);

  const graphData = monthlyBreakdown.map((r) => ({
    month: new Date(r.month).toLocaleDateString('en-GB', { month: 'short', year: '2-digit' }),
    total: Number(r.profit),
    sales: Number(r.total_sales),
    fabric_sales: Number(r.fabric_sales),
    polybag_sales: Number(r.polybag_sales),
  }));

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
      {/* Mobile-only hero — Total Balance at a glance, eye toggle, and
          Receipt/Payment quick actions. Uses the same cashBank/balancesVisible
          state as the Cash & Bank cards below, not a separate fetch — mobile
          and desktop are one component now, so nothing shown here can ever
          drift out of sync with what desktop shows. */}
      <div className="md:hidden mb-5 rounded-3xl p-6" style={{ background: 'radial-gradient(circle at 30% 0%, #1A1F16 0%, #0B0C0A 70%)' }}>
        <div className="flex items-center justify-between">
          <div className="text-xs uppercase tracking-wide" style={{ color: '#9AA39A' }}>Total Balance</div>
          <button
            onClick={() => setBalancesVisible((v) => !v)}
            aria-label={balancesVisible ? 'Hide balances' : 'Show balances'}
            title={balancesVisible ? 'Hide balances' : 'Show balances'}
            className="text-white/70 hover:text-white p-1 -m-1"
          >
            {balancesVisible ? <Eye size={16} /> : <EyeOff size={16} />}
          </button>
        </div>
        <div className="text-3xl font-bold text-white mt-1">{maskPkr(cashTotal + bankTotal, balancesVisible)}</div>
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 mt-2 text-xs" style={{ color: '#9AA39A' }}>
          <span>Cash in Hand <span className="text-white font-medium">{maskPkr(cashTotal, balancesVisible)}</span></span>
          <span>Bank Balance <span className="text-white font-medium">{maskPkr(bankTotal, balancesVisible)}</span></span>
        </div>
        {onNavigate && (
          <div className="flex items-center justify-between mt-6 gap-3">
            <button
              onClick={() => onNavigate('entry_voucher', 'crv', 'new')}
              className="flex-1 flex items-center justify-center gap-2 rounded-full py-3 text-sm font-medium text-white"
              style={{ backgroundColor: 'rgba(255,255,255,0.1)' }}
            >
              <ArrowDownRight size={16} /> Receipt
            </button>
            <button
              onClick={() => setAddSheetOpen(true)}
              className="h-12 w-12 rounded-full flex items-center justify-center flex-shrink-0"
              style={{ backgroundColor: '#14170F', boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.18)' }}
            >
              <Plus size={22} className="text-white" />
            </button>
            <button
              onClick={() => onNavigate('entry_voucher', 'cpv', 'new')}
              className="flex-1 flex items-center justify-center gap-2 rounded-full py-3 text-sm font-medium text-white"
              style={{ backgroundColor: 'rgba(255,255,255,0.1)' }}
            >
              <ArrowUpRight size={16} /> Payment
            </button>
          </div>
        )}
      </div>

      {onNavigate && visiblePages.includes('party_master') && (
        <div className="md:hidden mb-5">
          <MobileListRow
            icon={BookOpen} iconBg="#EEF2FF" iconColor={THEME.blue}
            title="General Ledger" subtitle="Look up any party or account"
            onClick={() => onNavigate('party_master', 'ledger')}
            right={<ChevronRight size={18} className="text-gray-300" />}
          />
        </div>
      )}

      <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />

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

      {/* Row 1 — Cash & Bank */}
      <div className="flex items-center justify-between">
        <SectionHeading>Cash &amp; Bank</SectionHeading>
        <button
          onClick={() => setBalancesVisible((v) => !v)}
          aria-label={balancesVisible ? 'Hide balances' : 'Show balances'}
          title={balancesVisible ? 'Hide balances' : 'Show balances'}
          className="text-gray-400 hover:text-gray-700 p-1 -m-1"
        >
          {balancesVisible ? <Eye size={16} /> : <EyeOff size={16} />}
        </button>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <CashBankCard title="Cash in Hand" icon={Wallet} total={cashTotal} accounts={cashAccounts} visible={balancesVisible} onSelectAccount={(a) => setLedgerAccount({ id: a.id, name: a.name })} />
        <CashBankCard title="Bank Balance" icon={Landmark} total={bankTotal} accounts={bankAccounts} visible={balancesVisible} onSelectAccount={(a) => setLedgerAccount({ id: a.id, name: a.name })} />
      </div>

      {/* Row 2 — Sale */}
      <SectionHeading>Sale</SectionHeading>
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

      {/* Row 3 — Receivable & Payable */}
      <SectionHeading>Receivable &amp; Payable</SectionHeading>
      <div className="grid grid-cols-2 gap-4">
        <StatCard title="Total Receivable" icon={Users} color={THEME.blue} value={formatPkr(receivables.total_receivables)}
          onClick={() => setReceivablesModalOpen(true)} sub="Tap for customer-wise balances" />
        <StatCard title="Total Payable" icon={Users} color={THEME.amber} value={formatPkr(payablesTotal)}
          onClick={() => setPayablesModalOpen(true)} sub="Tap for vendor-wise balances" />
        {otherReceivables.length > 0 && (
          <StatCard title="Other Receivables" icon={Users} color={THEME.blue} value={formatPkr(otherReceivablesTotal)}
            onClick={() => setOtherReceivablesModalOpen(true)} sub="Loans, committee etc. — tap for details" />
        )}
        {otherPayables.length > 0 && (
          <StatCard title="Other Payables" icon={Users} color={THEME.amber} value={formatPkr(otherPayablesTotal)}
            onClick={() => setOtherPayablesModalOpen(true)} sub="Loans etc. — tap for details" />
        )}
      </div>

      {/* Row 4 — Payment */}
      <SectionHeading>Payment</SectionHeading>
      <div className="grid grid-cols-2 gap-4">
        <StatCard title="Payment Received" icon={ArrowUpRight} color={THEME.success} value={formatPkr(paymentsSummary.received)} />
        <StatCard title="Payment Made" icon={ArrowDownRight} color={THEME.danger} value={formatPkr(paymentsSummary.made)} />
      </div>

      {/* Row 5 — Expense & Drawings */}
      <SectionHeading>Expense &amp; Drawings</SectionHeading>
      <div className="grid grid-cols-2 gap-4">
        <StatCard title="Total Expenses" icon={Receipt} color={THEME.amber} value={formatPkr(expensesAndDrawings.expenses)} />
        <StatCard title="Drawings" icon={Receipt} color={THEME.amber} value={formatPkr(expensesAndDrawings.drawings)} />
      </div>

      {/* Row 6 — Historical financial analysis */}
      <SectionHeading>Historical Analysis</SectionHeading>
      <Card className="p-4" style={{ borderColor: THEME.line }}>
        <div className="flex flex-wrap items-end gap-3 mb-4">
          <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
            {ANALYSIS_RANGE_OPTIONS.map((o) => (
              <button
                key={o.key}
                type="button"
                onClick={() => setAnalysisRange(o.key)}
                className="px-3 py-1.5 rounded-md text-xs font-medium"
                style={analysisRange === o.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
              >
                {o.label}
              </button>
            ))}
          </div>
          {analysisRange === 'custom' && (
            <ReportFilterBar from={analysisCustomFrom} to={analysisCustomTo} onFromChange={setAnalysisCustomFrom} onToChange={setAnalysisCustomTo} />
          )}
        </div>

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
          {breakdownLoading && graphData.length === 0 ? (
            <div className="h-full flex items-center justify-center"><Spinner /></div>
          ) : (
            <React.Suspense fallback={<div className="h-full flex items-center justify-center"><Spinner /></div>}>
              <GrowthChart
                data={graphData}
                dataKey={profitToggle}
                name={MONTHLY_PROFIT_TOGGLES.find((t) => t.key === profitToggle).label}
                stroke={THEME.emerald}
                formatValue={formatPkr}
              />
            </React.Suspense>
          )}
        </div>

        <div className="mt-5 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs text-gray-500 border-b" style={{ borderColor: THEME.line }}>
                <th className="py-2 pr-3 font-medium">Month</th>
                <th className="py-2 pr-3 font-medium text-right">Fabric Sale</th>
                <th className="py-2 pr-3 font-medium text-right">Poly Bag Sale</th>
                <th className="py-2 pr-3 font-medium text-right">Total Sale</th>
                <th className="py-2 pr-3 font-medium text-right">Purchase</th>
                <th className="py-2 pr-3 font-medium text-right">Expenses</th>
                <th className="py-2 pl-3 font-medium text-right">Profit</th>
              </tr>
            </thead>
            <tbody>
              {monthlyBreakdown.map((r) => (
                <tr key={r.month} className="border-b last:border-0" style={{ borderColor: THEME.line }}>
                  <td className="py-2 pr-3 whitespace-nowrap">{new Date(r.month).toLocaleDateString('en-GB', { month: 'short', year: 'numeric' })}</td>
                  <td className="py-2 pr-3 text-right">{formatPkr(r.fabric_sales)}</td>
                  <td className="py-2 pr-3 text-right">{formatPkr(r.polybag_sales)}</td>
                  <td className="py-2 pr-3 text-right font-medium">{formatPkr(r.total_sales)}</td>
                  <td className="py-2 pr-3 text-right">{formatPkr(r.total_purchase)}</td>
                  <td className="py-2 pr-3 text-right">{formatPkr(r.expenses)}</td>
                  <td className="py-2 pl-3 text-right font-semibold" style={{ color: Number(r.profit) >= 0 ? THEME.success : THEME.danger }}>
                    {formatPkr(r.profit)}
                  </td>
                </tr>
              ))}
              {!breakdownLoading && monthlyBreakdown.length === 0 && (
                <tr><td colSpan={7} className="py-6 text-center text-gray-400">No data for this range.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>

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

      <AccountListModal
        open={otherReceivablesModalOpen}
        onClose={() => setOtherReceivablesModalOpen(false)}
        title="Other receivables"
        rows={otherReceivables}
        renderRow={(a) => (
          <div key={a.id} className="flex items-center justify-between px-1 py-3">
            <span className="text-sm">{a.name}</span>
            <span className="text-sm font-semibold" style={{ color: THEME.blue }}>{formatPkr(a.balance)}</span>
          </div>
        )}
      />

      <AccountListModal
        open={otherPayablesModalOpen}
        onClose={() => setOtherPayablesModalOpen(false)}
        title="Other payables"
        rows={otherPayables}
        renderRow={(a) => (
          <div key={a.id} className="flex items-center justify-between px-1 py-3">
            <span className="text-sm">{a.name}</span>
            <span className="text-sm font-semibold" style={{ color: THEME.amber }}>{formatPkr(-a.balance)}</span>
          </div>
        )}
      />

      {onNavigate && (
        <AddActionSheet open={addSheetOpen} onClose={() => setAddSheetOpen(false)} onNavigate={onNavigate} visiblePages={visiblePages} />
      )}
    </div>
  );
}

// ============================================================================
// MOBILE HOME — wallet-app-style home screen shown in place of the Dashboard
// on small screens only (md:hidden); desktop keeps the row-based Dashboard
// above. Paired with MobileTabBar for bottom navigation.
// ============================================================================

const QUICK_ADD_ACTIONS = [
  { label: 'Sale', page: 'entry_sale', param: 'sale', icon: ShoppingCart },
  { label: 'Sale Return', page: 'entry_sale', param: 'sale_return', icon: ShoppingCart },
  { label: 'Purchase', page: 'entry_purchase', param: 'purchase', icon: ClipboardList },
  { label: 'Purchase Return', page: 'entry_purchase', param: 'purchase_return', icon: ClipboardList },
];

function AddActionSheet({ open, onClose, onNavigate, visiblePages }) {
  if (!open) return null;
  const actions = QUICK_ADD_ACTIONS.filter((a) => visiblePages.includes(a.page));
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center" onClick={onClose}>
      <div className="absolute inset-0 bg-black/40" />
      <div className="relative w-full max-w-md bg-white rounded-t-2xl p-4 pb-8" onClick={(e) => e.stopPropagation()}>
        <div className="h-1 w-10 bg-gray-300 rounded-full mx-auto mb-4" />
        <div className="grid grid-cols-2 gap-3">
          {actions.map((a) => (
            <button
              key={a.label}
              onClick={() => { onNavigate(a.page, a.param, 'new'); onClose(); }}
              className="flex flex-col items-center gap-2 p-4 rounded-xl border hover:bg-gray-50"
              style={{ borderColor: THEME.line }}
            >
              <a.icon size={22} style={{ color: THEME.blue }} />
              <span className="text-sm font-medium">{a.label}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function MobileListRow({ icon: Icon, iconBg, iconColor, title, subtitle, right, onClick }) {
  const Comp = onClick ? 'button' : 'div';
  return (
    <Comp
      onClick={onClick}
      className={cx('w-full flex items-center gap-3 rounded-2xl bg-white p-3.5 shadow-sm', onClick && 'hover:bg-gray-50 text-left')}
    >
      <div className="h-10 w-10 rounded-full flex items-center justify-center flex-shrink-0" style={{ backgroundColor: iconBg }}>
        <Icon size={18} style={{ color: iconColor }} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="text-sm font-medium truncate">{title}</div>
        {subtitle && <div className="text-xs text-gray-500 truncate">{subtitle}</div>}
      </div>
      {right}
    </Comp>
  );
}

function MobileTabBar({ current, onNavigate, visiblePages }) {
  const [addOpen, setAddOpen] = useState(false);
  if (!visiblePages.includes('dashboard')) return null;
  return (
    <>
      <nav
        className="md:hidden fixed bottom-4 inset-x-6 z-30 bg-white rounded-full shadow-lg border flex items-center justify-around h-14 px-3"
        style={{ borderColor: THEME.line }}
      >
        <button
          onClick={() => onNavigate('dashboard')}
          className="h-10 w-10 rounded-full flex items-center justify-center"
          style={current === 'dashboard' ? { backgroundColor: '#EEF2FF', color: THEME.blue } : { color: THEME.navTextMuted }}
        >
          <Home size={20} />
        </button>
        <button
          onClick={() => setAddOpen(true)}
          className="h-11 w-11 rounded-full flex items-center justify-center"
          style={{ backgroundColor: THEME.blue }}
        >
          <Plus size={20} className="text-white" />
        </button>
        {visiblePages.includes('party_master') ? (
          <button
            onClick={() => onNavigate('party_master')}
            className="h-10 w-10 rounded-full flex items-center justify-center"
            style={current === 'party_master' ? { backgroundColor: '#EEF2FF', color: THEME.blue } : { color: THEME.navTextMuted }}
          >
            <Users size={20} />
          </button>
        ) : (
          <div className="h-10 w-10" />
        )}
      </nav>
      <AddActionSheet open={addOpen} onClose={() => setAddOpen(false)} onNavigate={onNavigate} visiblePages={visiblePages} />
    </>
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
// "Old" mode offers Edit (approvers only) alongside Void. Neither one
// mutates the ledger/stock trail directly — Edit reverses the previous
// posting with a compensating entry and reposts the edited version, the
// same pattern void_invoice already used for voiding (see update_invoice
// migration notes).
// ============================================================================

const PURCHASE_TABS = [
  { key: 'purchase_order', label: 'Purchase Order', mobileLabel: 'Order' },
  { key: 'purchase', label: 'Purchase Bill', mobileLabel: 'Bill' },
  { key: 'purchase_return', label: 'Purchase Return', mobileLabel: 'Return' },
];

function purchaseDocLabel(invoiceType) {
  return invoiceType === 'purchase_order' ? 'Purchase Order'
    : invoiceType === 'purchase_return' ? 'Purchase Return' : 'Purchase Bill';
}

function PurchaseModule({ initialTab, initialMode }) {
  const [tab, setTab] = useState(initialTab || 'purchase');
  // Opening the page normally lands on the entries list ('old'); only a
  // quick-add shortcut passes initialMode='new' to jump straight to entry.
  const [mode, setMode] = useState(initialMode || 'old');
  // Editing an old document is orthogonal to the New/Old toggle above — it's
  // entered via the Old list's Edit button and always returns to the Old
  // list on close, regardless of whatever the toggle was last set to.
  const [editingInvoice, setEditingInvoice] = useState(null);
  // PurchaseEntryForm reports its own dirty state up so these tab/mode
  // buttons — which remount/discard it via `key={tab}` — can warn before
  // silently wiping an in-progress bill, the same protection the unsaved-
  // changes guard gives the browser Back button.
  const [entryDirty, setEntryDirty] = useState(false);

  function guardedSwitch(fn) {
    if ((mode === 'new' || editingInvoice) && entryDirty
        && !window.confirm('You have unsaved changes on this form. Switching will discard them. Continue?')) {
      return;
    }
    setEntryDirty(false);
    setEditingInvoice(null);
    fn();
  }

  return (
    <div>
      {/* Mobile: compact stacked single-line bars */}
      <div className="flex flex-col gap-2 mb-4 md:hidden">
        <SegmentedBar
          options={PURCHASE_TABS.map((t) => ({ key: t.key, label: t.mobileLabel }))}
          value={tab}
          onChange={(k) => { if (k !== tab) guardedSwitch(() => { setTab(k); setMode('old'); }); }}
        />
        <SegmentedBar
          options={[{ key: 'new', label: 'New' }, { key: 'old', label: 'Old' }]}
          value={mode}
          onChange={(k) => { if (k !== mode || editingInvoice) guardedSwitch(() => setMode(k)); }}
        />
      </div>

      {/* Desktop: pill row */}
      <div className="hidden md:flex flex-wrap items-center justify-between gap-3 mb-5">
        <div className="flex flex-wrap gap-2">
          {PURCHASE_TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => { if (t.key !== tab) guardedSwitch(() => { setTab(t.key); setMode('old'); }); }}
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
              onClick={() => { if (o.k !== mode || editingInvoice) guardedSwitch(() => setMode(o.k)); }}
              className="px-3 py-1.5 rounded-md text-sm font-medium"
              style={mode === o.k && !editingInvoice ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {o.l}
            </button>
          ))}
        </div>
      </div>

      {editingInvoice
        ? (
          <PurchaseEntryForm
            key={`edit-${editingInvoice.id}`} invoiceType={tab} editInvoiceId={editingInvoice.id}
            onSavedClose={() => { setEditingInvoice(null); setMode('old'); }} onDirtyChange={setEntryDirty}
          />
        )
        : mode === 'new'
          ? <PurchaseEntryForm key={tab} invoiceType={tab} onSavedClose={() => setMode('old')} onDirtyChange={setEntryDirty} />
          : <PurchaseOldList key={tab} invoiceType={tab} onEdit={(row) => setEditingInvoice(row)} />}
    </div>
  );
}

function emptyPurchaseLine(defaultItem) {
  return {
    itemId: defaultItem?.id || null, itemName: defaultItem?.name || '',
    unit: 'KG', quantity: '', rate: '', narration: '', itemType: defaultItem?.item_type || 'product',
    // Optional: earmarks this line for a customer at purchase time, so it
    // can be suggested (and auto-filled) when that customer's Sale Bill is
    // entered later. Purchase Bill only — see PurchaseEntryForm's isBill.
    reservedForPartyId: null, reservedForPartyName: '',
    // Optional free-text color/GSM, shown for fabric-category brands only.
    color: '', gsm: '',
  };
}

function PurchaseEntryForm({ invoiceType, editInvoiceId, onSavedClose, onDirtyChange }) {
  const isBill = invoiceType === 'purchase';
  const title = purchaseDocLabel(invoiceType);

  const [brands, setBrands] = useState([]);
  const [brand, setBrand] = useState(null);
  const [vendor, setVendor] = useState(null);
  const [vendorResetKey, setVendorResetKey] = useState(0);
  const [date, setDate] = useState(toDateInput(new Date()));
  const [defaultItem, setDefaultItem] = useState(null);
  const [lines, setLines] = useState([emptyPurchaseLine()]);
  const [saving, setSaving] = useState(false);
  const [savedNo, setSavedNo] = useState(null);
  const [showReport, setShowReport] = useState(false);
  const [loadingEdit, setLoadingEdit] = useState(!!editInvoiceId);
  const [editInvoiceNo, setEditInvoiceNo] = useState(null);
  const { show, ToastHost } = useToast();

  const [supplierInvoiceNo, setSupplierInvoiceNo] = useState('');
  const [poOptions, setPoOptions] = useState([]);
  const [linkedOrder, setLinkedOrder] = useState(null);
  // Hidden from the entry UI (see brief), but kept so the total formula and
  // create_invoice's params stay unchanged — they just always send 0 now.
  const [transport, setTransport] = useState('0');
  const [loadingCharge, setLoadingCharge] = useState('0');
  const [discount, setDiscount] = useState('0');
  const [tax, setTax] = useState('0');

  const dateRef = useRef(null);
  const vendorRef = useRef(null);
  const lineRefs = useRef({});
  function getLineRefs(i) {
    if (!lineRefs.current[i]) {
      lineRefs.current[i] = {
        item: React.createRef(), unit: React.createRef(), qty: React.createRef(),
        rate: React.createRef(), color: React.createRef(), gsm: React.createRef(), narration: React.createRef(),
      };
    }
    return lineRefs.current[i];
  }

  const isDirty = !!vendor || !!supplierInvoiceNo.trim() || !!linkedOrder
    || lines.some((l) => Number(l.quantity) > 0 || Number(l.rate) > 0 || (l.narration && l.narration.trim()));
  const { showUnsavedConfirm, stayOnPage, leavePage } = useUnsavedChangesGuard(isDirty);

  const draftKey = editInvoiceId ? `skf_draft_purchase_edit_${editInvoiceId}` : `skf_draft_purchase_${invoiceType}`;
  const draftSnapshot = { brandKey: brand?.brand_key, vendor: vendor ? { id: vendor.id, name: vendor.name } : null, date, supplierInvoiceNo, lines };
  const { restorable: draftRestorable, clearDraft, dismissRestore } = useDraftAutosave(draftKey, draftSnapshot, isDirty);

  function restoreDraft() {
    const d = draftRestorable?.data;
    if (!d) return;
    if (d.brandKey) {
      const b = brands.find((x) => x.brand_key === d.brandKey);
      if (b) setBrand(b);
    }
    if (d.vendor) { setVendor(d.vendor); setVendorResetKey((k) => k + 1); }
    if (d.date) setDate(d.date);
    if (d.supplierInvoiceNo) setSupplierInvoiceNo(d.supplierInvoiceNo);
    if (Array.isArray(d.lines) && d.lines.length) setLines(d.lines);
    clearDraft();
  }

  useEffect(() => { onDirtyChange?.(isDirty); }, [isDirty]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    fetchBrands().then((rows) => { setBrands(rows); if (rows.length && !brand) setBrand(rows[0]); });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { dateRef.current?.focus(); }, []);

  // Editing an old document: fetch it (once brands are loaded, so its
  // brand_key resolves to a real brand object) and populate the form from
  // it instead of starting blank.
  useEffect(() => {
    if (!editInvoiceId || !brands.length) return;
    let alive = true;
    (async () => {
      try {
        const { invoice, items } = await fetchInvoiceWithItems(editInvoiceId);
        if (!alive) return;
        const b = brands.find((x) => x.brand_key === invoice.brand_key);
        if (b) setBrand(b);
        setVendor({ id: invoice.party_id, name: invoice.parties?.name || '' });
        setVendorResetKey((k) => k + 1);
        setDate(toDateInput(invoice.invoice_date));
        setSupplierInvoiceNo(invoice.supplier_invoice_no || '');
        setTransport(String(invoice.transport_charges || 0));
        setLoadingCharge(String(invoice.loading_charges || 0));
        setDiscount(String(invoice.discount_amount || 0));
        setTax(String(invoice.tax_amount || 0));
        setLines(items.map((it) => ({
          itemId: it.item_id, itemName: it.items?.name || it.description || '',
          itemType: it.items?.item_type || 'product',
          unit: it.unit, quantity: String(it.quantity), rate: String(it.rate),
          narration: it.narration || '', color: it.color || '', gsm: it.gsm || '',
          reservedForPartyId: it.reserved_for_party_id || null, reservedForPartyName: it.parties?.name || '',
        })));
        setEditInvoiceNo(invoice.invoice_no);
        lineRefs.current = {};
        if (invoice.linked_order_id) {
          try {
            const { invoice: order } = await fetchInvoiceWithItems(invoice.linked_order_id);
            if (alive) setLinkedOrder(order);
          } catch {
            // best-effort — only affects the "loaded from PO" display, not saving
          }
        }
      } catch (e) {
        show(`Could not load document to edit: ${e.message}`, 'danger');
      } finally {
        if (alive) setLoadingEdit(false);
      }
    })();
    return () => { alive = false; };
  }, [editInvoiceId, brands]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!isBill || !vendor) { setPoOptions([]); return; }
    let alive = true;
    fetchOpenPurchaseOrders(vendor.id).then((rows) => { if (alive) setPoOptions(rows); });
    return () => { alive = false; };
  }, [isBill, vendor]);

  // Default quality: LLD Polybag, for the Polybags brand only.
  useEffect(() => {
    if (brand?.category !== 'polybags') { setDefaultItem(null); return; }
    let alive = true;
    fetchDefaultPolybagItem().then((item) => {
      if (!alive) return;
      setDefaultItem(item);
      if (item) {
        setLines((ls) => (ls.length === 1 && !ls[0].itemId
          ? [{ ...ls[0], itemId: item.id, itemName: item.name }]
          : ls));
      }
    });
    return () => { alive = false; };
  }, [brand?.category]);

  function switchBrand(b) {
    if (b?.brand_key === brand?.brand_key) return; // already on this brand — nothing to do
    if (isDirty && !window.confirm('Switching category will clear the vendor and line items you already entered. Continue?')) {
      return;
    }
    setBrand(b);
    setLines([emptyPurchaseLine(b?.category === 'polybags' ? defaultItem : null)]);
    setVendor(null);
    setVendorResetKey((k) => k + 1);
    setLinkedOrder(null);
    setSupplierInvoiceNo('');
    setTransport('0'); setLoadingCharge('0'); setDiscount('0'); setTax('0');
    lineRefs.current = {};
  }

  function addLine(focus = true) {
    setLines((ls) => {
      const next = [...ls, emptyPurchaseLine(defaultItem)];
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
      itemType: item.item_type || 'product',
      unit: item.default_unit || purchaseUnitOptionsFor(brand?.category)[0],
      rate: item.last_purchase_rate != null && !lines[i].rate ? String(item.last_purchase_rate) : lines[i].rate,
    });
  }

  async function applyLinkedOrder(order) {
    if (!order) { setLinkedOrder(null); return; }
    const hasManualLines = lines.some((l) => l.itemId);
    if (hasManualLines && !window.confirm('Loading this purchase order will replace the line items you already entered. Continue?')) {
      return;
    }
    try {
      const { items } = await fetchInvoiceWithItems(order.id);
      setLinkedOrder(order);
      setLines(items.map((it) => ({
        itemId: it.item_id, itemName: it.items?.name || it.description || '',
        itemType: it.items?.item_type || 'product',
        unit: it.unit, quantity: String(it.quantity), rate: String(it.rate),
        narration: it.narration || '', color: it.color || '', gsm: it.gsm || '',
        reservedForPartyId: it.reserved_for_party_id || null, reservedForPartyName: it.parties?.name || '',
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
    setLines([emptyPurchaseLine(defaultItem)]);
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
      const itemsPayload = validLines.map((l) => ({ itemId: l.itemId, quantity: l.quantity, unit: l.unit, rate: l.rate, description: l.itemName, narration: l.narration, itemType: l.itemType, reservedForPartyId: l.reservedForPartyId, color: l.color, gsm: l.gsm }));
      if (editInvoiceId) {
        await updateInvoice(editInvoiceId, {
          partyId: vendor.id, invoiceDate: date, items: itemsPayload,
          supplierInvoiceNo: isBill ? supplierInvoiceNo : undefined,
          linkedOrderId: isBill ? linkedOrder?.id : undefined,
          transport: isBill ? transport : undefined,
          loading: isBill ? loadingCharge : undefined,
          discount: isBill ? discount : undefined,
          tax: isBill ? tax : undefined,
        });
        show(`Saved. ${editInvoiceNo} updated.`);
        clearDraft();
        // An edit is a single, focused operation on one document — always
        // return to the list afterward rather than clearing for another entry.
        onSavedClose?.();
        return;
      }
      const id = await createInvoice({
        invoiceType, brandKey: brand.brand_key, category: brand.category,
        partyId: vendor.id, invoiceDate: date,
        items: itemsPayload,
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
      clearDraft();
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
      invoice_type: invoiceType, category: brand?.category, supplier_invoice_no: supplierInvoiceNo, brand_key: brand?.brand_key,
      transport_charges: transport, loading_charges: loadingCharge, discount_amount: discount, tax_amount: tax,
      total_amount: grandTotal,
    };
    const pseudoItems = lines.filter((l) => l.itemId).map((l) => ({
      items: { name: l.itemName }, unit: l.unit, quantity: l.quantity, rate: l.rate,
      amount: (Number(l.quantity) || 0) * (Number(l.rate) || 0), narration: l.narration, color: l.color, gsm: l.gsm,
    }));
    return { pseudoInvoice, pseudoItems };
  }
  async function draftPrint() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    printPdfDoc(await buildPurchaseDocPdf(pseudoInvoice, pseudoItems));
  }
  async function draftExportPdf() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    (await buildPurchaseDocPdf(pseudoInvoice, pseudoItems)).save(`${pseudoInvoice.invoice_no}.pdf`);
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

  if (editInvoiceId && loadingEdit) return <div className="py-20 flex justify-center"><Spinner /></div>;
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
              const next = brand.category === 'fabric' ? getLineRefs(i).color : getLineRefs(i).narration;
              next.current?.focus();
            }
          }}
        />
      ),
      color: (
        <Input
          ref={getLineRefs(i).color}
          label="Color (optional)" value={line.color}
          placeholder="e.g. Sky Blue"
          onChange={(e) => updateLine(i, { color: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).gsm.current?.focus(); } }}
        />
      ),
      gsm: (
        <Input
          ref={getLineRefs(i).gsm}
          label="GSM (optional)" value={line.gsm}
          placeholder="e.g. 120"
          onChange={(e) => updateLine(i, { gsm: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).narration.current?.focus(); } }}
        />
      ),
      narration: (
        <Input
          ref={getLineRefs(i).narration}
          label="Narration (optional)" value={line.narration}
          placeholder="e.g. Order A"
          onChange={(e) => updateLine(i, { narration: e.target.value })}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              if (i === lines.length - 1) addLine();
              else getLineRefs(i + 1).item.current?.focus();
            }
          }}
        />
      ),
      // Earmarks this line for a customer — surfaced as a suggestion (with
      // auto-fill) when that customer's Sale Bill is entered later. Bill only.
      sellTo: (
        <PartyPicker
          type="customer"
          value={line.reservedForPartyId ? { id: line.reservedForPartyId, name: line.reservedForPartyName } : null}
          onChange={(p) => updateLine(i, { reservedForPartyId: p?.id || null, reservedForPartyName: p?.name || '' })}
          resetKey={`${i}-${line.reservedForPartyId || 'none'}`}
          label="Sell to (optional)"
        />
      ),
      amount: formatPkr((Number(line.quantity) || 0) * (Number(line.rate) || 0)),
    };
  }

  return (
    <div className="max-w-5xl">
      <h2 className="font-display font-semibold text-lg mb-4">
        {editInvoiceId ? `Edit ${title} — ${editInvoiceNo || ''}` : title}
      </h2>

      <div className="flex flex-wrap items-end gap-4 mb-5">
        <BrandTabs brands={brands} value={brand} onChange={editInvoiceId ? () => {} : switchBrand} />
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
              <th className="text-left font-medium px-3 py-2.5 w-1/3">Item</th>
              <th className="text-left font-medium px-3 py-2.5">Unit</th>
              <th className="text-left font-medium px-3 py-2.5">Qty</th>
              <th className="text-left font-medium px-3 py-2.5">Rate</th>
              {brand.category === 'fabric' && <th className="text-left font-medium px-3 py-2.5">Color</th>}
              {brand.category === 'fabric' && <th className="text-left font-medium px-3 py-2.5">GSM</th>}
              <th className="text-left font-medium px-3 py-2.5 w-1/5">Narration</th>
              {isBill && <th className="text-left font-medium px-3 py-2.5 w-1/5">Sell to</th>}
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
                  {brand.category === 'fabric' && <td className="px-3 py-2">{f.color}</td>}
                  {brand.category === 'fabric' && <td className="px-3 py-2">{f.gsm}</td>}
                  <td className="px-3 py-2">{f.narration}</td>
                  {isBill && <td className="px-3 py-2">{f.sellTo}</td>}
                  <td className="px-3 py-2 w-28 pt-4 font-medium">{f.amount}</td>
                  <td className="px-2 py-2 pt-4">
                    <button onClick={() => removeLine(i)} aria-label="Remove line" title="Remove line" className="text-gray-400 hover:text-red-500 p-1 -m-1">
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
                <button onClick={() => removeLine(i)} aria-label="Remove line" title="Remove line" className="text-gray-400 hover:text-red-500 p-1 -m-1">
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
              {brand.category === 'fabric' && f.color}
              {brand.category === 'fabric' && f.gsm}
              {f.narration}
              {isBill && f.sellTo}
            </Card>
          );
        })}
      </div>

      <div className="flex items-center justify-end gap-2 mt-5 mb-6">
        <span className="text-gray-500">{isBill ? 'Grand Total:' : 'Total:'}</span>
        <span className="text-xl font-bold" style={{ color: THEME.blue }}>{formatPkr(grandTotal)}</span>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        {editInvoiceId ? (
          <Button onClick={() => save(true)} loading={saving}>Save Changes</Button>
        ) : (
          <>
            <Button onClick={() => save(false)} loading={saving}>Save</Button>
            <Button variant="outline" onClick={() => save(true)} loading={saving}>Save &amp; Close</Button>
          </>
        )}
        <Button variant="outline" icon={FileDown} onClick={draftPrint}>Print</Button>
        <Button variant="outline" icon={FileDown} onClick={draftExportPdf}>Export</Button>
        <Button variant="outline" icon={FileDown} onClick={() => setShowReport(true)}>Report</Button>
        {savedNo && <Badge tone="success">Last saved: {savedNo}</Badge>}
      </div>
      <p className="text-xs text-gray-500 mt-2">
        Enter moves Date → Vendor → Item → Unit → Qty → Rate → Narration → next line. F2 on the vendor field adds a vendor, F3 on an item field adds an item. Ctrl+S saves, Ctrl+P prints the draft.
      </p>
      <DocReportModal
        open={showReport} onClose={() => setShowReport(false)}
        title={editInvoiceId ? `Edit ${title}` : title} buildDoc={() => buildDraft()} buildPdf={buildPurchaseDocPdf}
      />
      <UnsavedChangesModal open={showUnsavedConfirm} onStay={stayOnPage} onLeave={leavePage} />
      <RestoreDraftModal open={!!draftRestorable} savedAt={draftRestorable?.savedAt} onRestore={restoreDraft} onDiscard={dismissRestore} />
      <ToastHost />
    </div>
  );
}

function brandDisplayName(brandKey) {
  return brandKey === 'skf_polybags' ? 'SKF PolyBags' : 'SKF PolyTex';
}

// Shared layout for the customer/vendor-facing Purchase & Sale documents —
// single brand logo (whichever brand the document was created under, not
// both), bold doc-type header, Bill-To/Vendor block, item table, and a
// clean totals block. Purchase/Sale differ only in labels, so both call
// through here instead of duplicating the layout.
async function buildTradeDocPdf({ invoice, items, docLabel, partyRoleLabel, refLabel, refValue }) {
  const { jsPDF, autoTable } = await loadPdfLibs();
  const doc = new jsPDF();
  const pageWidth = doc.internal.pageSize.getWidth();
  const pageHeight = doc.internal.pageSize.getHeight();

  doc.setDrawColor(210);
  doc.rect(8, 8, pageWidth - 16, pageHeight - 16);

  const brandKey = invoice.brand_key;
  let textX = 16;
  try {
    const logo = brandKey ? BRAND_LOGOS[brandKey] : null;
    if (logo) {
      const dataUrl = await loadImageAsDataUrl(logo);
      doc.addImage(dataUrl, 'PNG', 16, 14, 16, 16);
      textX = 36;
    }
  } catch {
    // fall back to text-only header if the logo can't be loaded
  }

  doc.setFont(undefined, 'bold');
  doc.setFontSize(20);
  doc.setTextColor(18, 20, 28);
  doc.text(docLabel.toUpperCase(), textX, 22);
  doc.setFont(undefined, 'normal');
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(brandDisplayName(brandKey), textX, 29);

  const rightX = pageWidth - 16;
  doc.setFontSize(9);
  doc.setTextColor(80);
  doc.text(`Invoice #: ${invoice.invoice_no}`, rightX, 17, { align: 'right' });
  doc.text(`Date: ${formatDate(invoice.invoice_date)}`, rightX, 23, { align: 'right' });
  doc.setTextColor(150);
  doc.text(`Generated: ${formatDate(new Date())}`, rightX, 29, { align: 'right' });

  doc.setDrawColor(230);
  doc.line(16, 36, pageWidth - 16, 36);

  doc.setFontSize(8);
  doc.setTextColor(140);
  doc.text(partyRoleLabel.toUpperCase(), 16, 44);
  doc.setFontSize(11);
  doc.setTextColor(18, 20, 28);
  doc.text(invoice.parties?.name || '', 16, 51);

  let startY = 60;
  if (refValue) {
    doc.setFontSize(9);
    doc.setTextColor(120);
    doc.text(`${refLabel}: ${refValue}`, 16, 57);
    startY = 64;
  }

  const isFabric = invoice.category === 'fabric';
  const rows = items.map((it) => {
    const row = [it.items?.name || it.description || '', it.unit, String(it.quantity), formatPkr(it.rate)];
    if (isFabric) row.push(it.color || '', it.gsm || '');
    row.push(it.narration || '', formatPkr(it.amount));
    return row;
  });
  const subtotal = items.reduce((s, it) => s + Number(it.amount || 0), 0);
  const extraCharges = Number(invoice.transport_charges || 0) + Number(invoice.loading_charges || 0)
    + Number(invoice.tax_amount || 0) - Number(invoice.discount_amount || 0);
  const footPrefix = isFabric ? ['', '', '', '', '', ''] : ['', '', '', ''];
  const foot = [[...footPrefix, 'Subtotal', formatPkr(subtotal)]];
  if (extraCharges !== 0) {
    foot.push([...footPrefix, 'Transport + Loading + Tax − Discount', formatPkr(extraCharges)]);
  }
  foot.push([...footPrefix, 'Total', formatPkr(invoice.total_amount)]);

  autoTable(doc, {
    startY,
    head: [isFabric
      ? ['Item', 'Unit', 'Qty', 'Rate', 'Color', 'GSM', 'Narration', 'Amount']
      : ['Item', 'Unit', 'Qty', 'Rate', 'Narration', 'Amount']],
    body: rows,
    foot,
    margin: { left: 16, right: 16 },
    headStyles: { fillColor: [30, 32, 40], textColor: [255, 255, 255], fontStyle: 'bold', fontSize: 9 },
    footStyles: { fillColor: [255, 255, 255], textColor: [90, 90, 90], fontStyle: 'normal', fontSize: 9 },
    alternateRowStyles: { fillColor: [248, 248, 250] },
    styles: { fontSize: 9, cellPadding: 3 },
    didParseCell: (data) => {
      if (data.section === 'foot' && data.row.index === foot.length - 1) {
        data.cell.styles.fontStyle = 'bold';
        data.cell.styles.fontSize = 10.5;
        data.cell.styles.textColor = [18, 20, 28];
      }
    },
    didDrawPage: () => drawPdfFooter(doc),
  });

  const afterTableY = doc.lastAutoTable.finalY + 12;
  if (afterTableY < pageHeight - 24) {
    doc.setFontSize(8);
    doc.setTextColor(140);
    doc.text('NOTES', 16, afterTableY);
    doc.setFontSize(9);
    doc.setTextColor(90);
    doc.text('Thank you for your business.', 16, afterTableY + 6, { maxWidth: pageWidth - 32 });
  }

  return doc;
}

async function buildPurchaseDocPdf(invoice, items) {
  return buildTradeDocPdf({
    invoice, items,
    docLabel: purchaseDocLabel(invoice.invoice_type),
    partyRoleLabel: 'Vendor',
    refLabel: 'Supplier Invoice #',
    refValue: invoice.supplier_invoice_no,
  });
}

function printPdfDoc(doc) {
  doc.autoPrint();
  window.open(doc.output('bloburl'), '_blank');
}

// Report preview shared by Purchase/Sale entry forms — same generated PDF
// used by Print/Export, plus a native share sheet (falls back to opening
// the PDF in a new tab on desktop or any browser without Web Share) so a
// bill can go straight to a vendor/customer over WhatsApp from a phone.
function DocReportModal({ open, onClose, title, buildDoc, buildPdf }) {
  return (
    <SimpleReportModal
      open={open} onClose={onClose} title={title}
      buildPdfDoc={() => {
        const { pseudoInvoice, pseudoItems } = buildDoc();
        return buildPdf(pseudoInvoice, pseudoItems);
      }}
    />
  );
}

// Generic report preview shared by vouchers, General Ledger, and anywhere
// else a document needs Preview/Print/Export/Share (+ optional Excel with
// real structured rows, not a screenshot). buildPdfDoc is a zero-arg async
// function that returns a ready jsPDF doc — callers close over whatever
// data they need to build it.
function SimpleReportModal({ open, onClose, title, buildPdfDoc, excelData }) {
  const [previewUrl, setPreviewUrl] = useState(null);
  const [docRef, setDocRef] = useState(null);
  const [loading, setLoading] = useState(false);
  const [savingImage, setSavingImage] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    if (!open) { setPreviewUrl(null); setDocRef(null); return; }
    let alive = true;
    setLoading(true);
    Promise.resolve(buildPdfDoc()).then((doc) => {
      if (!alive) return;
      setDocRef(doc);
      setPreviewUrl(doc.output('bloburl'));
    }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps

  // Rasterizes the same generated report the Print/Export buttons use (via
  // pdf.js), never a screenshot of the live ERP screen.
  async function handleSaveImage() {
    if (!docRef) return;
    setSavingImage(true);
    try {
      const dataUrl = await pdfDocToPngDataUrl(docRef);
      const a = document.createElement('a');
      a.href = dataUrl;
      a.download = `${slug(title)}.png`;
      a.click();
    } catch (e) {
      show(`Could not generate image: ${e.message}`, 'danger');
    } finally {
      setSavingImage(false);
    }
  }

  async function handleShare() {
    if (!docRef) return;
    try {
      // Prefer sharing the rasterized report as an image — that's what
      // renders an inline preview in WhatsApp/etc, rather than a bare
      // document icon. Falls back to the PDF if image generation fails.
      try {
        const dataUrl = await pdfDocToPngDataUrl(docRef);
        const imgBlob = await (await fetch(dataUrl)).blob();
        const imgFile = new File([imgBlob], `${slug(title)}.png`, { type: 'image/png' });
        if (navigator.canShare && navigator.canShare({ files: [imgFile] })) {
          await navigator.share({ files: [imgFile], title });
          return;
        }
      } catch {
        // fall through to PDF share below
      }
      const blob = docRef.output('blob');
      const file = new File([blob], `${slug(title)}.pdf`, { type: 'application/pdf' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({ files: [file], title });
      } else if (navigator.share) {
        await navigator.share({ title, url: previewUrl });
      } else {
        window.open(previewUrl, '_blank');
      }
    } catch (e) {
      if (e.name !== 'AbortError') show(`Could not share: ${e.message}`, 'danger');
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`${title} — Report`} width={880}>
      {loading ? (
        <div className="py-16 flex justify-center"><Spinner /></div>
      ) : previewUrl ? (
        <div className="space-y-3 max-h-[82vh] overflow-y-auto">
          {/* A4 aspect ratio (210x297mm) so the full page — every column —
              renders on screen at a legible size, not a cramped fixed-height
              slot the browser's PDF viewer has to squeeze the page into. */}
          <iframe title="report-preview" src={previewUrl} className="w-full rounded-lg border" style={{ aspectRatio: '210 / 297', borderColor: THEME.line }} />
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" icon={FileDown} onClick={() => printPdfDoc(docRef)}>Print</Button>
            <Button variant="outline" icon={FileDown} loading={savingImage} onClick={handleSaveImage}>Save Image</Button>
            <Button variant="outline" icon={FileDown} onClick={() => docRef.save(`${slug(title)}.pdf`)}>Export PDF</Button>
            {excelData && (
              <Button variant="outline" icon={FileSpreadsheet} onClick={() => exportExcel({ title, columns: excelData.columns, rows: excelData.rows })}>Export Excel</Button>
            )}
            <Button icon={FileDown} onClick={handleShare}>Share</Button>
          </div>
        </div>
      ) : null}
      <ToastHost />
    </Modal>
  );
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

  const docNo = target?.invoice_no || target?.voucher_no || '';
  const showStockNote = !!target?.invoice_type && target.invoice_type !== 'purchase_order';

  return (
    <Modal open={!!target} onClose={onClose} title={`Void ${docNo}`}>
      <div className="space-y-3">
        <p className="text-sm text-gray-500">
          This reverses the ledger{showStockNote ? ' and stock' : ''} impact of this document with an audit-trail entry. It cannot be undone.
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
  const [fulfilledSet, setFulfilledSet] = useState(new Set());
  const hasReservations = doc?.items?.some((it) => it.reserved_for_party_id);

  useEffect(() => {
    if (!hasReservations) { setFulfilledSet(new Set()); return; }
    let alive = true;
    fetchFulfilledPurchaseItemIds().then((s) => { if (alive) setFulfilledSet(s); });
    return () => { alive = false; };
  }, [doc?.invoice?.id, hasReservations]);

  if (!doc) return null;
  const { invoice, items } = doc;
  const isFabric = invoice.category === 'fabric';
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
                {isFabric && <th className="text-left px-3 py-2">Color</th>}
                {isFabric && <th className="text-left px-3 py-2">GSM</th>}
                <th className="text-left px-3 py-2">Narration</th>
                <th className="text-left px-3 py-2">Amount</th>
                {hasReservations && <th className="text-left px-3 py-2">Sell to</th>}
              </tr>
            </thead>
            <tbody>
              {items.map((it) => (
                <tr key={it.id} className="border-t" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{it.items?.name || it.description}</td>
                  <td className="px-3 py-2">{it.unit}</td>
                  <td className="px-3 py-2">{it.quantity}</td>
                  <td className="px-3 py-2">{formatPkr(it.rate)}</td>
                  {isFabric && <td className="px-3 py-2 text-gray-500">{it.color || ''}</td>}
                  {isFabric && <td className="px-3 py-2 text-gray-500">{it.gsm || ''}</td>}
                  <td className="px-3 py-2 text-gray-500">{it.narration || ''}</td>
                  <td className="px-3 py-2">{formatPkr(it.amount)}</td>
                  {hasReservations && (
                    <td className="px-3 py-2">
                      {it.reserved_for_party_id ? (
                        <span className="flex items-center gap-1.5">
                          {it.parties?.name || '—'}
                          {fulfilledSet.has(it.id)
                            ? <Badge tone="success">Billed</Badge>
                            : <Badge tone="amber">Pending</Badge>}
                        </span>
                      ) : '—'}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
        {invoice.invoice_type === 'purchase' && (Number(invoice.transport_charges) || Number(invoice.loading_charges) || Number(invoice.tax_amount) || Number(invoice.discount_amount)) ? (
          <div className="text-xs text-gray-500">
            Transport: {formatPkr(invoice.transport_charges)} · Loading: {formatPkr(invoice.loading_charges)} ·
            Tax: {formatPkr(invoice.tax_amount)} · Discount: {formatPkr(invoice.discount_amount)}
          </div>
        ) : null}
        {invoice.narration && <div className="text-gray-500">Narration: {invoice.narration}</div>}
        <div className="text-right font-bold" style={{ color: THEME.blue }}>Total: {formatPkr(invoice.total_amount)}</div>
      </div>
    </Modal>
  );
}

function PurchaseOldList({ invoiceType, onEdit }) {
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
  const [reservationInfo, setReservationInfo] = useState({});
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

  // For Purchase Bills only: which rows have lines reserved for a customer,
  // and how many of those lines have already been pulled into a Sale Bill
  // ("Billed") vs are still waiting ("Reserved").
  useEffect(() => {
    if (invoiceType !== 'purchase' || !rows || rows.length === 0) { setReservationInfo({}); return; }
    let alive = true;
    (async () => {
      const ids = rows.map((r) => r.id);
      const [{ data: resItems, error }, fulfilledSet] = await Promise.all([
        supabase.from('invoice_items').select('id, invoice_id').in('invoice_id', ids).not('reserved_for_party_id', 'is', null),
        fetchFulfilledPurchaseItemIds(),
      ]);
      if (error || !alive) return;
      const info = {};
      (resItems || []).forEach((it) => {
        if (!info[it.invoice_id]) info[it.invoice_id] = { total: 0, billed: 0 };
        info[it.invoice_id].total += 1;
        if (fulfilledSet.has(it.id)) info[it.invoice_id].billed += 1;
      });
      setReservationInfo(info);
    })();
    return () => { alive = false; };
  }, [invoiceType, rows]);

  const filtered = poNo
    ? (rows || []).filter((r) => (orderLookup[r.linked_order_id] || '').toLowerCase().includes(poNo.toLowerCase()))
    : rows;

  async function handleView(row) {
    try { setViewDoc(await fetchInvoiceWithItems(row.id)); }
    catch (e) { show(`Could not load document: ${e.message}`, 'danger'); }
  }
  async function handlePrint(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); printPdfDoc(await buildPurchaseDocPdf(invoice, items)); }
    catch (e) { show(`Could not print: ${e.message}`, 'danger'); }
  }
  async function handleExportPdf(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); (await buildPurchaseDocPdf(invoice, items)).save(`${invoice.invoice_no}.pdf`); }
    catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleExportExcel(row) {
    try {
      const { items } = await fetchInvoiceWithItems(row.id);
      const isFabric = row.category === 'fabric';
      exportExcel({
        title: row.invoice_no,
        columns: isFabric ? ['Item', 'Unit', 'Qty', 'Rate', 'Color', 'GSM', 'Amount'] : ['Item', 'Unit', 'Qty', 'Rate', 'Amount'],
        rows: items.map((it) => {
          const r = [it.items?.name || it.description || '', it.unit, it.quantity, it.rate];
          if (isFabric) r.push(it.color || '', it.gsm || '');
          r.push(it.amount);
          return r;
        }),
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
                  {reservationInfo[row.id] && (
                    reservationInfo[row.id].billed >= reservationInfo[row.id].total
                      ? <Badge tone="success">Billed</Badge>
                      : reservationInfo[row.id].billed > 0
                        ? <Badge tone="amber">{`Partly billed (${reservationInfo[row.id].billed}/${reservationInfo[row.id].total})`}</Badge>
                        : <Badge tone="amber">Reserved — not billed</Badge>
                  )}
                  {invoiceType === 'purchase' && orderLookup[row.linked_order_id] && (
                    <span className="text-xs text-gray-400">from {orderLookup[row.linked_order_id]}</span>
                  )}
                </div>
                <div className="text-xs text-gray-500">{formatDate(row.invoice_date)} · {row.parties?.name}</div>
              </div>
              <div className="font-semibold w-28 text-right" style={{ color: THEME.blue }}>{formatPkr(row.total_amount)}</div>
              <div className="flex items-center gap-1">
                <button onClick={() => handleView(row)} title="View" aria-label="View" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <Search size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => onEdit?.(row)} title="Edit" aria-label="Edit" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                    <Pencil size={16} />
                  </button>
                )}
                <button onClick={() => handlePrint(row)} title="Print" aria-label="Print" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportPdf(row)} title="Export PDF" aria-label="Export PDF" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportExcel(row)} title="Export Excel" aria-label="Export Excel" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileSpreadsheet size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => setVoidTarget(row)} title="Void" aria-label="Void" className="p-2.5 rounded-lg hover:bg-red-50 text-red-500">
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
  { key: 'sale_order', label: 'Sale Order', mobileLabel: 'Order' },
  { key: 'sale', label: 'Sale Bill', mobileLabel: 'Bill' },
  { key: 'sale_return', label: 'Sale Return', mobileLabel: 'Return' },
];

function saleDocLabel(invoiceType) {
  return invoiceType === 'sale_order' ? 'Sale Order'
    : invoiceType === 'sale_return' ? 'Sale Return' : 'Sale Bill';
}

function SalesModule({ initialTab, initialMode }) {
  const [tab, setTab] = useState(initialTab || 'sale');
  // Opening the page normally lands on the entries list ('old'); only a
  // quick-add shortcut passes initialMode='new' to jump straight to entry.
  const [mode, setMode] = useState(initialMode || 'old');
  // Editing an old document is orthogonal to the New/Old toggle above — it's
  // entered via the Old list's Edit button and always returns to the Old
  // list on close, regardless of whatever the toggle was last set to.
  const [editingInvoice, setEditingInvoice] = useState(null);
  // SaleEntryForm reports its own dirty state up so these tab/mode buttons
  // — which remount/discard it via `key={tab}` — can warn before silently
  // wiping an in-progress bill, the same protection the unsaved-changes
  // guard gives the browser Back button.
  const [entryDirty, setEntryDirty] = useState(false);

  function guardedSwitch(fn) {
    if ((mode === 'new' || editingInvoice) && entryDirty
        && !window.confirm('You have unsaved changes on this form. Switching will discard them. Continue?')) {
      return;
    }
    setEntryDirty(false);
    setEditingInvoice(null);
    fn();
  }

  return (
    <div>
      {/* Mobile: compact stacked single-line bars */}
      <div className="flex flex-col gap-2 mb-4 md:hidden">
        <SegmentedBar
          options={SALE_TABS.map((t) => ({ key: t.key, label: t.mobileLabel }))}
          value={tab}
          onChange={(k) => { if (k !== tab) guardedSwitch(() => { setTab(k); setMode('old'); }); }}
        />
        <SegmentedBar
          options={[{ key: 'new', label: 'New' }, { key: 'old', label: 'Old' }]}
          value={mode}
          onChange={(k) => { if (k !== mode || editingInvoice) guardedSwitch(() => setMode(k)); }}
        />
      </div>

      {/* Desktop: pill row */}
      <div className="hidden md:flex flex-wrap items-center justify-between gap-3 mb-5">
        <div className="flex flex-wrap gap-2">
          {SALE_TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => { if (t.key !== tab) guardedSwitch(() => { setTab(t.key); setMode('old'); }); }}
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
              onClick={() => { if (o.k !== mode || editingInvoice) guardedSwitch(() => setMode(o.k)); }}
              className="px-3 py-1.5 rounded-md text-sm font-medium"
              style={mode === o.k && !editingInvoice ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {o.l}
            </button>
          ))}
        </div>
      </div>

      {editingInvoice
        ? (
          <SaleEntryForm
            key={`edit-${editingInvoice.id}`} invoiceType={tab} editInvoiceId={editingInvoice.id}
            onSavedClose={() => { setEditingInvoice(null); setMode('old'); }} onDirtyChange={setEntryDirty}
          />
        )
        : mode === 'new'
          ? <SaleEntryForm key={tab} invoiceType={tab} onSavedClose={() => setMode('old')} onDirtyChange={setEntryDirty} />
          : <SaleOldList key={tab} invoiceType={tab} onEdit={(row) => setEditingInvoice(row)} />}
    </div>
  );
}

function emptySaleLine(defaultItem) {
  return {
    itemId: defaultItem?.id || null, itemName: defaultItem?.name || '',
    unit: 'KG', quantity: '', rate: '', narration: '', itemType: defaultItem?.item_type || 'product',
    // Set when this line was auto-filled from a suggested Purchase Bill
    // reservation — records the link so that purchase line shows "Billed"
    // and stops being suggested again.
    fulfilledFromItemId: null,
    // Optional free-text color/GSM, shown for fabric-category brands only.
    color: '', gsm: '',
  };
}

function SaleEntryForm({ invoiceType, editInvoiceId, onSavedClose, onDirtyChange }) {
  const isBill = invoiceType === 'sale';
  const title = saleDocLabel(invoiceType);

  const [brands, setBrands] = useState([]);
  const [brand, setBrand] = useState(null);
  const [customer, setCustomer] = useState(null);
  const [customerResetKey, setCustomerResetKey] = useState(0);
  const [date, setDate] = useState(toDateInput(new Date()));
  const [defaultItem, setDefaultItem] = useState(null);
  const [lines, setLines] = useState([emptySaleLine()]);
  const [saving, setSaving] = useState(false);
  const [savedNo, setSavedNo] = useState(null);
  const [showReport, setShowReport] = useState(false);
  const [loadingEdit, setLoadingEdit] = useState(!!editInvoiceId);
  const [editInvoiceNo, setEditInvoiceNo] = useState(null);
  const { show, ToastHost } = useToast();

  const [customerPoNo, setCustomerPoNo] = useState('');
  const [soOptions, setSoOptions] = useState([]);
  const [openReservations, setOpenReservations] = useState([]);
  const [linkedOrder, setLinkedOrder] = useState(null);
  // Hidden from the entry UI (see brief), but kept so the total formula and
  // create_invoice's params stay unchanged — they just always send 0 now.
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
      lineRefs.current[i] = {
        item: React.createRef(), unit: React.createRef(), qty: React.createRef(),
        rate: React.createRef(), color: React.createRef(), gsm: React.createRef(), narration: React.createRef(),
      };
    }
    return lineRefs.current[i];
  }

  const isDirty = !!customer || !!customerPoNo.trim() || !!linkedOrder
    || lines.some((l) => Number(l.quantity) > 0 || Number(l.rate) > 0 || (l.narration && l.narration.trim()));
  const { showUnsavedConfirm, stayOnPage, leavePage } = useUnsavedChangesGuard(isDirty);

  const draftKey = editInvoiceId ? `skf_draft_sale_edit_${editInvoiceId}` : `skf_draft_sale_${invoiceType}`;
  const draftSnapshot = { brandKey: brand?.brand_key, customer: customer ? { id: customer.id, name: customer.name } : null, date, customerPoNo, lines };
  const { restorable: draftRestorable, clearDraft, dismissRestore } = useDraftAutosave(draftKey, draftSnapshot, isDirty);

  function restoreDraft() {
    const d = draftRestorable?.data;
    if (!d) return;
    if (d.brandKey) {
      const b = brands.find((x) => x.brand_key === d.brandKey);
      if (b) setBrand(b);
    }
    if (d.customer) { setCustomer(d.customer); setCustomerResetKey((k) => k + 1); }
    if (d.date) setDate(d.date);
    if (d.customerPoNo) setCustomerPoNo(d.customerPoNo);
    if (Array.isArray(d.lines) && d.lines.length) setLines(d.lines);
    clearDraft();
  }

  useEffect(() => { onDirtyChange?.(isDirty); }, [isDirty]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    fetchBrands().then((rows) => { setBrands(rows); if (rows.length && !brand) setBrand(rows[0]); });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { dateRef.current?.focus(); }, []);

  // Editing an old document: fetch it (once brands are loaded, so its
  // brand_key resolves to a real brand object) and populate the form from
  // it instead of starting blank.
  useEffect(() => {
    if (!editInvoiceId || !brands.length) return;
    let alive = true;
    (async () => {
      try {
        const { invoice, items } = await fetchInvoiceWithItems(editInvoiceId);
        if (!alive) return;
        const b = brands.find((x) => x.brand_key === invoice.brand_key);
        if (b) setBrand(b);
        setCustomer({ id: invoice.party_id, name: invoice.parties?.name || '' });
        setCustomerResetKey((k) => k + 1);
        setDate(toDateInput(invoice.invoice_date));
        setCustomerPoNo(invoice.customer_po_no || '');
        setTransport(String(invoice.transport_charges || 0));
        setLoadingCharge(String(invoice.loading_charges || 0));
        setDiscount(String(invoice.discount_amount || 0));
        setTax(String(invoice.tax_amount || 0));
        setLines(items.map((it) => ({
          itemId: it.item_id, itemName: it.items?.name || it.description || '',
          itemType: it.items?.item_type || 'product',
          unit: it.unit, quantity: String(it.quantity), rate: String(it.rate),
          narration: it.narration || '', color: it.color || '', gsm: it.gsm || '',
          fulfilledFromItemId: it.fulfilled_from_item_id || null,
        })));
        setEditInvoiceNo(invoice.invoice_no);
        lineRefs.current = {};
        if (invoice.linked_order_id) {
          try {
            const { invoice: order } = await fetchInvoiceWithItems(invoice.linked_order_id);
            if (alive) setLinkedOrder(order);
          } catch {
            // best-effort — only affects the "loaded from SO" display, not saving
          }
        }
      } catch (e) {
        show(`Could not load document to edit: ${e.message}`, 'danger');
      } finally {
        if (alive) setLoadingEdit(false);
      }
    })();
    return () => { alive = false; };
  }, [editInvoiceId, brands]); // eslint-disable-line react-hooks/exhaustive-deps

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

  // Purchase Bill lines already earmarked ("sold to") this customer, not
  // yet pulled into a Sale Bill — surfaced as one-click suggestions below.
  useEffect(() => {
    if (!isBill || !customer) { setOpenReservations([]); return; }
    let alive = true;
    fetchOpenPurchaseReservations(customer.id).then((rows) => { if (alive) setOpenReservations(rows); });
    return () => { alive = false; };
  }, [isBill, customer]);

  function fillLineFromReservation(res) {
    setLines((ls) => {
      // A line pre-filled by the default-item logic (itemId set, no qty
      // entered yet) is still "empty" for this purpose — overwrite it
      // instead of appending a duplicate line.
      const emptyIdx = ls.findIndex((l) => !Number(l.quantity));
      const filled = {
        itemId: res.item_id, itemName: res.item_name || res.description || '',
        itemType: res.item_type || 'product', unit: res.unit,
        quantity: String(res.quantity), rate: '', narration: '',
        fulfilledFromItemId: res.id,
      };
      if (emptyIdx !== -1) return ls.map((l, idx) => (idx === emptyIdx ? filled : l));
      return [...ls, filled];
    });
    setOpenReservations((rs) => rs.filter((r) => r.id !== res.id));
  }

  // Default quality: LLD Polybag, for the Polybags brand only.
  useEffect(() => {
    if (brand?.category !== 'polybags') { setDefaultItem(null); return; }
    let alive = true;
    fetchDefaultPolybagItem().then((item) => {
      if (!alive) return;
      setDefaultItem(item);
      if (item) {
        setLines((ls) => (ls.length === 1 && !ls[0].itemId
          ? [{ ...ls[0], itemId: item.id, itemName: item.name }]
          : ls));
      }
    });
    return () => { alive = false; };
  }, [brand?.category]);

  function switchBrand(b) {
    if (b?.brand_key === brand?.brand_key) return; // already on this brand — nothing to do
    if (isDirty && !window.confirm('Switching category will clear the customer and line items you already entered. Continue?')) {
      return;
    }
    setBrand(b);
    setLines([emptySaleLine(b?.category === 'polybags' ? defaultItem : null)]);
    setCustomer(null);
    setCustomerResetKey((k) => k + 1);
    setLinkedOrder(null);
    setCustomerPoNo('');
    setTransport('0'); setLoadingCharge('0'); setDiscount('0'); setTax('0');
    lineRefs.current = {};
  }

  function addLine(focus = true) {
    setLines((ls) => {
      const next = [...ls, emptySaleLine(defaultItem)];
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
      itemType: item.item_type || 'product',
      unit: item.default_unit || purchaseUnitOptionsFor(brand?.category)[0],
      rate: item.last_sale_rate != null && !lines[i].rate ? String(item.last_sale_rate) : lines[i].rate,
    });
  }

  async function applyLinkedOrder(order) {
    if (!order) { setLinkedOrder(null); return; }
    const hasManualLines = lines.some((l) => l.itemId);
    if (hasManualLines && !window.confirm('Loading this sale order will replace the line items you already entered. Continue?')) {
      return;
    }
    try {
      const { items } = await fetchInvoiceWithItems(order.id);
      setLinkedOrder(order);
      setLines(items.map((it) => ({
        itemId: it.item_id, itemName: it.items?.name || it.description || '',
        itemType: it.items?.item_type || 'product',
        unit: it.unit, quantity: String(it.quantity), rate: String(it.rate),
        narration: it.narration || '', color: it.color || '', gsm: it.gsm || '',
        fulfilledFromItemId: it.fulfilled_from_item_id || null,
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
    setLines([emptySaleLine(defaultItem)]);
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
      const itemsPayload = validLines.map((l) => ({ itemId: l.itemId, quantity: l.quantity, unit: l.unit, rate: l.rate, description: l.itemName, narration: l.narration, itemType: l.itemType, fulfilledFromItemId: l.fulfilledFromItemId, color: l.color, gsm: l.gsm }));
      if (editInvoiceId) {
        await updateInvoice(editInvoiceId, {
          partyId: customer.id, invoiceDate: date, items: itemsPayload,
          customerPoNo: isBill ? customerPoNo : undefined,
          linkedOrderId: isBill ? linkedOrder?.id : undefined,
          transport: isBill ? transport : undefined,
          loading: isBill ? loadingCharge : undefined,
          discount: isBill ? discount : undefined,
          tax: isBill ? tax : undefined,
        });
        show(`Saved. ${editInvoiceNo} updated.`);
        clearDraft();
        if (isBill) fetchStockBalance().then((rows) => {
          const map = {};
          rows.forEach((r) => { map[r.item_id] = r; });
          setStockMap(map);
        });
        // An edit is a single, focused operation on one document — always
        // return to the list afterward rather than clearing for another entry.
        onSavedClose?.();
        return;
      }
      const id = await createInvoice({
        invoiceType, brandKey: brand.brand_key, category: brand.category,
        partyId: customer.id, invoiceDate: date,
        items: itemsPayload,
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
      clearDraft();
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
      invoice_type: invoiceType, category: brand?.category, customer_po_no: customerPoNo, brand_key: brand?.brand_key,
      transport_charges: transport, loading_charges: loadingCharge, discount_amount: discount, tax_amount: tax,
      total_amount: grandTotal,
    };
    const pseudoItems = lines.filter((l) => l.itemId).map((l) => ({
      items: { name: l.itemName }, unit: l.unit, quantity: l.quantity, rate: l.rate,
      amount: (Number(l.quantity) || 0) * (Number(l.rate) || 0), narration: l.narration, color: l.color, gsm: l.gsm,
    }));
    return { pseudoInvoice, pseudoItems };
  }
  async function draftPrint() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    printPdfDoc(await buildSaleDocPdf(pseudoInvoice, pseudoItems));
  }
  async function draftExportPdf() {
    const { pseudoInvoice, pseudoItems } = buildDraft();
    (await buildSaleDocPdf(pseudoInvoice, pseudoItems)).save(`${pseudoInvoice.invoice_no}.pdf`);
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

  if (editInvoiceId && loadingEdit) return <div className="py-20 flex justify-center"><Spinner /></div>;
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
              const next = brand.category === 'fabric' ? getLineRefs(i).color : getLineRefs(i).narration;
              next.current?.focus();
            }
          }}
        />
      ),
      color: (
        <Input
          ref={getLineRefs(i).color}
          label="Color (optional)" value={line.color}
          placeholder="e.g. Sky Blue"
          onChange={(e) => updateLine(i, { color: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).gsm.current?.focus(); } }}
        />
      ),
      gsm: (
        <Input
          ref={getLineRefs(i).gsm}
          label="GSM (optional)" value={line.gsm}
          placeholder="e.g. 120"
          onChange={(e) => updateLine(i, { gsm: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).narration.current?.focus(); } }}
        />
      ),
      narration: (
        <Input
          ref={getLineRefs(i).narration}
          label="Narration (optional)" value={line.narration}
          placeholder="e.g. Order A"
          onChange={(e) => updateLine(i, { narration: e.target.value })}
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
      <h2 className="font-display font-semibold text-lg mb-4">
        {editInvoiceId ? `Edit ${title} — ${editInvoiceNo || ''}` : title}
      </h2>

      <div className="flex flex-wrap items-end gap-4 mb-5">
        <BrandTabs brands={brands} value={brand} onChange={editInvoiceId ? () => {} : switchBrand} />
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

      {isBill && openReservations.length > 0 && (
        <Card className="p-4 mb-5" style={{ borderColor: THEME.line }}>
          <h3 className="font-medium text-sm text-gray-700 mb-2">
            Suggested from Purchase — already reserved for {customer?.name}
          </h3>
          <div className="space-y-2">
            {openReservations.map((r) => (
              <button
                key={r.id}
                type="button"
                onClick={() => fillLineFromReservation(r)}
                className="w-full flex items-center justify-between gap-3 text-left px-3 py-2 rounded-lg border hover:bg-gray-50"
                style={{ borderColor: THEME.line }}
              >
                <span className="min-w-0">
                  <span className="font-medium">{r.item_name || r.description}</span>
                  <span className="text-gray-500 text-xs block sm:inline sm:ml-2">
                    {formatDate(r.invoice_date)} · {r.invoice_no}
                  </span>
                </span>
                <span className="font-medium whitespace-nowrap">{r.quantity} {r.unit}</span>
              </button>
            ))}
          </div>
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
              <th className="text-left font-medium px-3 py-2.5 w-1/3">Item</th>
              <th className="text-left font-medium px-3 py-2.5">Unit</th>
              <th className="text-left font-medium px-3 py-2.5">Qty</th>
              <th className="text-left font-medium px-3 py-2.5">Rate</th>
              {brand.category === 'fabric' && <th className="text-left font-medium px-3 py-2.5">Color</th>}
              {brand.category === 'fabric' && <th className="text-left font-medium px-3 py-2.5">GSM</th>}
              <th className="text-left font-medium px-3 py-2.5 w-1/5">Narration</th>
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
                  {brand.category === 'fabric' && <td className="px-3 py-2">{f.color}</td>}
                  {brand.category === 'fabric' && <td className="px-3 py-2">{f.gsm}</td>}
                  <td className="px-3 py-2">{f.narration}</td>
                  <td className="px-3 py-2 w-28 pt-4 font-medium">{f.amount}</td>
                  <td className="px-2 py-2 pt-4">
                    <button onClick={() => removeLine(i)} aria-label="Remove line" title="Remove line" className="text-gray-400 hover:text-red-500 p-1 -m-1">
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
                <button onClick={() => removeLine(i)} aria-label="Remove line" title="Remove line" className="text-gray-400 hover:text-red-500 p-1 -m-1">
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
              {brand.category === 'fabric' && f.color}
              {brand.category === 'fabric' && f.gsm}
              {f.narration}
            </Card>
          );
        })}
      </div>

      <div className="flex items-center justify-end gap-2 mt-5 mb-6">
        <span className="text-gray-500">{isBill ? 'Grand Total:' : 'Total:'}</span>
        <span className="text-xl font-bold" style={{ color: THEME.blue }}>{formatPkr(grandTotal)}</span>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        {editInvoiceId ? (
          <Button onClick={() => save(true)} loading={saving}>Save Changes</Button>
        ) : (
          <>
            <Button onClick={() => save(false)} loading={saving}>Save</Button>
            <Button variant="outline" onClick={() => save(true)} loading={saving}>Save &amp; Close</Button>
          </>
        )}
        <Button variant="outline" icon={FileDown} onClick={draftPrint}>Print</Button>
        <Button variant="outline" icon={FileDown} onClick={draftExportPdf}>Export</Button>
        <Button variant="outline" icon={FileDown} onClick={() => setShowReport(true)}>Report</Button>
        {savedNo && <Badge tone="success">Last saved: {savedNo}</Badge>}
      </div>
      <p className="text-xs text-gray-500 mt-2">
        Enter moves Date → Customer → Item → Unit → Qty → Rate → Narration → next line. F2 on the customer field adds a customer, F3 on an item field adds an item. Ctrl+S saves, Ctrl+P prints the draft.
      </p>
      <DocReportModal
        open={showReport} onClose={() => setShowReport(false)}
        title={editInvoiceId ? `Edit ${title}` : title} buildDoc={() => buildDraft()} buildPdf={buildSaleDocPdf}
      />
      <UnsavedChangesModal open={showUnsavedConfirm} onStay={stayOnPage} onLeave={leavePage} />
      <RestoreDraftModal open={!!draftRestorable} savedAt={draftRestorable?.savedAt} onRestore={restoreDraft} onDiscard={dismissRestore} />
      <ToastHost />
    </div>
  );
}

async function buildSaleDocPdf(invoice, items) {
  return buildTradeDocPdf({
    invoice, items,
    docLabel: saleDocLabel(invoice.invoice_type),
    partyRoleLabel: 'Bill To',
    refLabel: 'Customer PO #',
    refValue: invoice.customer_po_no,
  });
}

function SaleViewModal({ doc, onClose }) {
  if (!doc) return null;
  const { invoice, items } = doc;
  const isFabric = invoice.category === 'fabric';
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
                {isFabric && <th className="text-left px-3 py-2">Color</th>}
                {isFabric && <th className="text-left px-3 py-2">GSM</th>}
                <th className="text-left px-3 py-2">Narration</th>
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
                  {isFabric && <td className="px-3 py-2 text-gray-500">{it.color || ''}</td>}
                  {isFabric && <td className="px-3 py-2 text-gray-500">{it.gsm || ''}</td>}
                  <td className="px-3 py-2 text-gray-500">{it.narration || ''}</td>
                  <td className="px-3 py-2">{formatPkr(it.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
        {invoice.invoice_type === 'sale' && (Number(invoice.transport_charges) || Number(invoice.loading_charges) || Number(invoice.tax_amount) || Number(invoice.discount_amount)) ? (
          <div className="text-xs text-gray-500">
            Transport: {formatPkr(invoice.transport_charges)} · Loading: {formatPkr(invoice.loading_charges)} ·
            Tax: {formatPkr(invoice.tax_amount)} · Discount: {formatPkr(invoice.discount_amount)}
          </div>
        ) : null}
        <div className="text-right font-bold" style={{ color: THEME.blue }}>Total: {formatPkr(invoice.total_amount)}</div>
      </div>
    </Modal>
  );
}

function SaleOldList({ invoiceType, onEdit }) {
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
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); printPdfDoc(await buildSaleDocPdf(invoice, items)); }
    catch (e) { show(`Could not print: ${e.message}`, 'danger'); }
  }
  async function handleExportPdf(row) {
    try { const { invoice, items } = await fetchInvoiceWithItems(row.id); (await buildSaleDocPdf(invoice, items)).save(`${invoice.invoice_no}.pdf`); }
    catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleExportExcel(row) {
    try {
      const { items } = await fetchInvoiceWithItems(row.id);
      const isFabric = row.category === 'fabric';
      exportExcel({
        title: row.invoice_no,
        columns: isFabric ? ['Item', 'Unit', 'Qty', 'Rate', 'Color', 'GSM', 'Amount'] : ['Item', 'Unit', 'Qty', 'Rate', 'Amount'],
        rows: items.map((it) => {
          const r = [it.items?.name || it.description || '', it.unit, it.quantity, it.rate];
          if (isFabric) r.push(it.color || '', it.gsm || '');
          r.push(it.amount);
          return r;
        }),
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
                <button onClick={() => handleView(row)} title="View" aria-label="View" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <Search size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => onEdit?.(row)} title="Edit" aria-label="Edit" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                    <Pencil size={16} />
                  </button>
                )}
                <button onClick={() => handlePrint(row)} title="Print" aria-label="Print" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportPdf(row)} title="Export PDF" aria-label="Export PDF" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportExcel(row)} title="Export Excel" aria-label="Export Excel" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileSpreadsheet size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => setVoidTarget(row)} title="Void" aria-label="Void" className="p-2.5 rounded-lg hover:bg-red-50 text-red-500">
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
// PAYMENT VOUCHERS — CRV / CPV / BRV / BPV. Not a new document type: all
// four are the existing record_payment() receipt/payment, tabbed by which
// cash_bank_kind the money moved through (cash vs bank), same New/Old
// pattern as Purchase and Sales. Sharing one entry_voucher permission
// (not four) keeps the permission grid from growing a row per tab.
// ============================================================================

const VOUCHER_TABS = [
  { key: 'crv', label: 'Cash Receipt (CRV)', direction: 'receipt', kind: 'cash' },
  { key: 'brv', label: 'Bank Receipt (BRV)', direction: 'receipt', kind: 'bank' },
  { key: 'cpv', label: 'Cash Payment (CPV)', direction: 'payment', kind: 'cash' },
  { key: 'bpv', label: 'Bank Payment (BPV)', direction: 'payment', kind: 'bank' },
];

function VoucherModule({ initialTab, initialMode }) {
  const [tab, setTab] = useState(initialTab || 'crv');
  // Opening the page normally lands on the entries list ('old'); only a
  // quick-add shortcut passes initialMode='new' to jump straight to entry.
  const [mode, setMode] = useState(initialMode || 'old');
  const active = VOUCHER_TABS.find((t) => t.key === tab);

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-5">
        <div className="flex flex-wrap gap-2">
          {VOUCHER_TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => { setTab(t.key); setMode('old'); }}
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
        ? <VoucherEntryForm key={tab} tab={active} onSavedClose={() => setMode('old')} />
        : <VoucherOldList key={tab} tab={active} />}
    </div>
  );
}

const PAYABLE_ACCOUNT_TYPES = ['expense', 'drawings'];

function VoucherEntryForm({ tab, onSavedClose }) {
  const partyType = tab.direction === 'receipt' ? 'customer' : 'supplier';
  const invoiceType = tab.direction === 'receipt' ? 'sale' : 'purchase';
  // Only a payment (money out) can go straight to an expense/drawings
  // account instead of a supplier — a receipt always names a party.
  const isPaymentDirection = tab.direction === 'payment';

  const [accounts, setAccounts] = useState([]);
  const [cashBankAccountId, setCashBankAccountId] = useState('');
  const [date, setDate] = useState(toDateInput(new Date()));
  const [payMode, setPayMode] = useState('party'); // 'party' | 'account' — payment direction only
  const [party, setParty] = useState(null);
  const [partyResetKey, setPartyResetKey] = useState(0);
  const [expenseAccount, setExpenseAccount] = useState(null);
  const [expenseAccountResetKey, setExpenseAccountResetKey] = useState(0);
  const [amount, setAmount] = useState('');
  const [method, setMethod] = useState('bank_transfer');
  const [linkedInvoiceId, setLinkedInvoiceId] = useState('');
  const [outstanding, setOutstanding] = useState([]);
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [savedNo, setSavedNo] = useState(null);
  const [showReport, setShowReport] = useState(false);
  const { show, ToastHost } = useToast();

  const dateRef = useRef(null);
  const partyRef = useRef(null);
  const expenseAccountRef = useRef(null);
  const amountRef = useRef(null);
  const notesRef = useRef(null);

  const usingAccount = isPaymentDirection && payMode === 'account';
  const isDirty = !!party || !!expenseAccount || !!amount.trim() || !!notes.trim();
  const { showUnsavedConfirm, stayOnPage, leavePage } = useUnsavedChangesGuard(isDirty);

  useEffect(() => { dateRef.current?.focus(); }, []);

  useEffect(() => {
    fetchChartOfAccounts().then((rows) => {
      const ofKind = rows.filter((a) => a.type === 'cash_bank' && a.cash_bank_kind === tab.kind);
      setAccounts(ofKind);
      if (ofKind.length === 1) setCashBankAccountId(ofKind[0].id);
    });
  }, [tab.kind]);

  useEffect(() => {
    if (!party) { setOutstanding([]); setLinkedInvoiceId(''); return; }
    let alive = true;
    fetchOutstandingInvoices(party.id, invoiceType).then((rows) => { if (alive) setOutstanding(rows); });
    return () => { alive = false; };
  }, [party, invoiceType]);

  function switchPayMode(mode) {
    if (mode === payMode) return;
    setPayMode(mode);
    setParty(null);
    setPartyResetKey((k) => k + 1);
    setExpenseAccount(null);
    setExpenseAccountResetKey((k) => k + 1);
  }

  function resetForm() {
    setParty(null);
    setPartyResetKey((k) => k + 1);
    setExpenseAccount(null);
    setExpenseAccountResetKey((k) => k + 1);
    setAmount('');
    setLinkedInvoiceId('');
    setNotes('');
    requestAnimationFrame(() => dateRef.current?.focus());
  }

  async function save(closeAfter) {
    if (usingAccount) {
      if (!expenseAccount) { show('Pick an expense or drawings account.', 'danger'); return; }
    } else if (!party) {
      show('Pick a party.', 'danger'); return;
    }
    if (!cashBankAccountId) { show(`No ${tab.kind} account is set up yet — add one under Admin.`, 'danger'); return; }
    if (!Number(amount) || Number(amount) <= 0) { show('Enter a valid amount.', 'danger'); return; }
    setSaving(true);
    try {
      const id = await recordPayment({
        paymentDate: date,
        partyId: usingAccount ? undefined : party.id,
        directAccountId: usingAccount ? expenseAccount.id : undefined,
        direction: tab.direction, amount,
        method: tab.kind === 'cash' ? 'cash' : method, cashBankAccountId,
        linkedInvoiceId: linkedInvoiceId || undefined, notes,
      });
      const saved = await fetchPaymentById(id);
      show(`Saved. ${saved.voucher_no} created.`);
      setSavedNo(saved.voucher_no);
      resetForm();
      if (closeAfter) onSavedClose?.();
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  function buildDraftPayment() {
    return {
      voucher_no: savedNo || 'DRAFT', payment_date: date, direction: tab.direction,
      amount, method: tab.kind === 'cash' ? 'cash' : method, notes,
      parties: usingAccount ? null : { name: party?.name },
      direct_account: usingAccount ? { name: expenseAccount?.name } : null,
      chart_of_accounts: { name: accounts.find((a) => a.id === cashBankAccountId)?.name },
    };
  }
  async function draftPrint() {
    printPdfDoc(await buildVoucherPdf(buildDraftPayment()));
  }
  async function draftExportPdf() {
    (await buildVoucherPdf(buildDraftPayment())).save(`${savedNo || 'voucher'}.pdf`);
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

  return (
    <div className="max-w-lg">
      <h2 className="font-display font-semibold text-lg mb-4">{tab.label}</h2>
      <div className="space-y-4">
        <Input
          ref={dateRef} type="date" label="Date" value={date}
          onChange={(e) => setDate(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); (usingAccount ? expenseAccountRef : partyRef).current?.focus(); } }}
        />

        {isPaymentDirection && (
          <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
            {[{ k: 'party', l: 'Supplier' }, { k: 'account', l: 'Expense / Drawings' }].map((o) => (
              <button
                key={o.k} type="button"
                onClick={() => switchPayMode(o.k)}
                className="px-3 py-1.5 rounded-md text-sm font-medium"
                style={payMode === o.k ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
              >
                {o.l}
              </button>
            ))}
          </div>
        )}

        {usingAccount ? (
          <AccountPicker
            types={PAYABLE_ACCOUNT_TYPES} value={expenseAccount} onChange={setExpenseAccount}
            resetKey={expenseAccountResetKey} inputRef={expenseAccountRef}
            label="Expense / Drawings account" placeholder="Search expense or drawings accounts…"
            onEnterNext={() => amountRef.current?.focus()}
          />
        ) : (
          <PartyPicker
            type={partyType} value={party} onChange={setParty}
            resetKey={partyResetKey} inputRef={partyRef} label="Party"
            onEnterNext={() => amountRef.current?.focus()}
          />
        )}

        {accounts.length > 1 && (
          <Select label={`${tab.kind === 'cash' ? 'Cash' : 'Bank'} account`} value={cashBankAccountId} onChange={(e) => setCashBankAccountId(e.target.value)}>
            <option value="">Select…</option>
            {accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </Select>
        )}
        {accounts.length === 0 && (
          <p className="text-xs" style={{ color: THEME.danger }}>No {tab.kind} account is set up yet — add one under Admin &rarr; Chart of Accounts.</p>
        )}

        {tab.kind === 'bank' && (
          <Select label="Method" value={method} onChange={(e) => setMethod(e.target.value)}>
            <option value="bank_transfer">Bank transfer</option>
            <option value="cheque">Cheque</option>
            <option value="other">Other</option>
          </Select>
        )}

        <Input
          ref={amountRef} type="number" label="Amount (PKR)" value={amount}
          onChange={(e) => setAmount(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); notesRef.current?.focus(); } }}
        />

        {outstanding.length > 0 && (
          <Select label="Apply against invoice (optional)" value={linkedInvoiceId} onChange={(e) => setLinkedInvoiceId(e.target.value)}>
            <option value="">— none / general —</option>
            {outstanding.map((o) => (
              <option key={o.invoice_id} value={o.invoice_id}>{o.invoice_no} · {formatDate(o.invoice_date)} · outstanding {formatPkr(o.outstanding)}</option>
            ))}
          </Select>
        )}

        <Input ref={notesRef} label="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />

        <div className="flex flex-wrap items-center gap-2 pt-2">
          <Button onClick={() => save(false)} loading={saving}>Save</Button>
          <Button variant="outline" onClick={() => save(true)} loading={saving}>Save &amp; Close</Button>
          <Button variant="outline" icon={FileDown} onClick={draftPrint}>Print</Button>
          <Button variant="outline" icon={FileDown} onClick={draftExportPdf}>Export</Button>
          <Button variant="outline" icon={FileDown} onClick={() => setShowReport(true)}>Report</Button>
          {savedNo && <Badge tone="success">Last saved: {savedNo}</Badge>}
        </div>
        <p className="text-xs text-gray-500">
          Enter moves Date → {usingAccount ? 'Account' : 'Party'} → Amount → Notes. Ctrl+S saves, Ctrl+P prints the draft.
        </p>
      </div>
      <SimpleReportModal
        open={showReport} onClose={() => setShowReport(false)}
        title={voucherTitle(buildDraftPayment())}
        buildPdfDoc={() => buildVoucherPdf(buildDraftPayment())}
        excelData={{
          columns: ['Voucher No.', 'Date', 'Paid to / Received from', 'Account', 'Method', 'Narration', 'Amount'],
          rows: [[
            savedNo || 'DRAFT', formatDate(date), usingAccount ? (expenseAccount?.name || '') : (party?.name || ''),
            accounts.find((a) => a.id === cashBankAccountId)?.name || '',
            tab.kind === 'cash' ? 'cash' : method, notes, Number(amount) || 0,
          ]],
        }}
      />
      <UnsavedChangesModal open={showUnsavedConfirm} onStay={stayOnPage} onLeave={leavePage} />
      <ToastHost />
    </div>
  );
}

function voucherTitle(payment) {
  const kind = payment.method === 'cash' ? 'CASH' : 'BANK';
  const dir = payment.direction === 'receipt' ? 'RECEIPT' : 'PAYMENT';
  return `${kind} ${dir} VOUCHER`;
}

async function buildVoucherPdf(payment) {
  const { jsPDF, autoTable } = await loadPdfLibs();
  const doc = new jsPDF();
  let textX = 14;
  try {
    const [logo1, logo2] = await Promise.all([loadImageAsDataUrl(logoSkfPolytex), loadImageAsDataUrl(logoSkfPolybags)]);
    doc.addImage(logo1, 'PNG', 14, 8, 14, 14);
    doc.addImage(logo2, 'PNG', 29, 8, 14, 14);
    textX = 47;
  } catch {
    // fall back to text-only header if the logos can't be loaded
  }
  doc.setFontSize(14);
  doc.text(voucherTitle(payment), textX, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(`Voucher No: ${payment.voucher_no}`, textX, 23);
  doc.text(`Date: ${formatDate(payment.payment_date)}   ${payment.direction === 'receipt' ? 'Received from' : 'Paid to'}: ${paymentRecipientLabel(payment)}`, textX, 29);
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });

  autoTable(doc, {
    startY: 36,
    head: [[payment.direction === 'receipt' ? 'Received from' : 'Paid to', 'Account', 'Method', 'Narration', 'Amount']],
    body: [[paymentRecipientLabel(payment), payment.chart_of_accounts?.name || '', payment.method || '', payment.notes || '', formatPkr(payment.amount)]],
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 9, cellPadding: 3 },
    didDrawPage: () => drawPdfFooter(doc),
  });
  return doc;
}

function VoucherViewModal({ payment, onClose }) {
  if (!payment) return null;
  return (
    <Modal open={!!payment} onClose={onClose} title={payment.voucher_no} width={480}>
      <div className="space-y-3 text-sm">
        <div className="grid grid-cols-2 gap-2">
          <div><span className="text-gray-500">Date:</span> {formatDate(payment.payment_date)}</div>
          <div><span className="text-gray-500">{payment.direction === 'receipt' ? 'Received from' : 'Paid to'}:</span> {paymentRecipientLabel(payment)}</div>
          <div><span className="text-gray-500">Account:</span> {payment.chart_of_accounts?.name}</div>
          <div><span className="text-gray-500">Method:</span> {payment.method}</div>
          <div><span className="text-gray-500">Status:</span> <Badge tone={payment.status === 'voided' ? 'danger' : 'success'}>{payment.status}</Badge></div>
        </div>
        {payment.notes && <div className="text-gray-500">Notes: {payment.notes}</div>}
        <div className="text-right font-bold" style={{ color: THEME.blue }}>Amount: {formatPkr(payment.amount)}</div>
      </div>
    </Modal>
  );
}

function VoucherOldList({ tab }) {
  const { permissions } = useAuth();
  const canApprove = !!permissions.entry_voucher?.can_approve;

  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [party, setParty] = useState(null);
  const [partyResetKey, setPartyResetKey] = useState(0);
  const [voucherNo, setVoucherNo] = useState('');
  const [rows, setRows] = useState(null);
  const [viewPayment, setViewPayment] = useState(null);
  const [reportRow, setReportRow] = useState(null);
  const [voidTarget, setVoidTarget] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchPayments({ direction: tab.direction, kind: tab.kind, from, to, partyId: party?.id, voucherNo })
      .then((r) => { if (alive) setRows(r); });
    return () => { alive = false; };
  }, [tab, from, to, party, voucherNo, refreshKey]);

  async function handlePrint(row) { printPdfDoc(await buildVoucherPdf(row)); }
  async function handleExportPdf(row) { (await buildVoucherPdf(row)).save(`${row.voucher_no}.pdf`); }
  function handleExportExcel(row) {
    exportExcel({
      title: row.voucher_no,
      columns: ['Date', 'Paid to / Received from', 'Account', 'Method', 'Amount'],
      rows: [[formatDate(row.payment_date), paymentRecipientLabel(row), row.chart_of_accounts?.name || '', row.method || '', row.amount]],
    });
  }
  async function handleVoidConfirm(reason) {
    try {
      await voidPayment(voidTarget.id, reason);
      show(`${voidTarget.voucher_no} voided.`);
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
          <PartyPicker type={tab.direction === 'receipt' ? 'customer' : 'supplier'} value={party} onChange={setParty} resetKey={partyResetKey} label="Party" />
        </div>
        <div className="w-40">
          <Input label="Voucher #" value={voucherNo} onChange={(e) => setVoucherNo(e.target.value)} placeholder="Search…" />
        </div>
        {(party || voucherNo) && (
          <Button variant="ghost" onClick={() => { setParty(null); setPartyResetKey((k) => k + 1); setVoucherNo(''); }}>
            Clear
          </Button>
        )}
      </div>

      {rows === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : rows.length === 0 ? (
        <EmptyState>No {tab.label.toLowerCase()} vouchers in this range.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {rows.map((row) => (
            <div key={row.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
              <div className="flex-1 min-w-[180px]">
                <div className="font-medium flex items-center gap-2">
                  {row.voucher_no}
                  {row.status === 'voided' && <Badge tone="danger">Voided</Badge>}
                </div>
                <div className="text-xs text-gray-500">{formatDate(row.payment_date)} · {paymentRecipientLabel(row)}</div>
              </div>
              <div className="font-semibold w-28 text-right" style={{ color: THEME.blue }}>{formatPkr(row.amount)}</div>
              <div className="flex items-center gap-1">
                <button onClick={() => setViewPayment(row)} title="View" aria-label="View" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <Search size={16} />
                </button>
                <button onClick={() => handlePrint(row)} title="Print" aria-label="Print" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportPdf(row)} title="Export PDF" aria-label="Export PDF" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportExcel(row)} title="Export Excel" aria-label="Export Excel" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileSpreadsheet size={16} />
                </button>
                <button onClick={() => setReportRow(row)} title="Report" aria-label="Report" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => setVoidTarget(row)} title="Void" aria-label="Void" className="p-2.5 rounded-lg hover:bg-red-50 text-red-500">
                    <X size={16} />
                  </button>
                )}
              </div>
            </div>
          ))}
        </Card>
      )}
      <SimpleReportModal
        open={!!reportRow} onClose={() => setReportRow(null)}
        title={reportRow ? voucherTitle(reportRow) : ''}
        buildPdfDoc={() => buildVoucherPdf(reportRow)}
        excelData={reportRow ? {
          columns: ['Voucher No.', 'Date', 'Paid to / Received from', 'Account', 'Method', 'Narration', 'Amount'],
          rows: [[reportRow.voucher_no, formatDate(reportRow.payment_date), paymentRecipientLabel(reportRow), reportRow.chart_of_accounts?.name || '', reportRow.method || '', reportRow.notes || '', reportRow.amount]],
        } : null}
      />

      <VoucherViewModal payment={viewPayment} onClose={() => setViewPayment(null)} />
      <VoidReasonModal target={voidTarget} onClose={() => setVoidTarget(null)} onConfirm={handleVoidConfirm} />
      <ToastHost />
    </div>
  );
}

// ============================================================================
// GENERAL VOUCHER (JV) — free-form multi-line entry. Any number of lines
// (minimum 2), each debits or credits one account; total debit must equal
// total credit before it can be saved. New in this module — see the
// migration's doc comment for why this needed real schema, unlike the
// four payment vouchers above.
// ============================================================================

function emptyJvLine() {
  return { accountId: null, accountName: '', debit: '', credit: '' };
}

function JournalVoucherModule() {
  // Opening the page normally lands on the entries list.
  const [mode, setMode] = useState('old');
  return (
    <div>
      <div className="flex items-center justify-between mb-5">
        <h2 className="font-display font-semibold text-lg">General Voucher</h2>
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
        ? <JournalVoucherEntryForm onSavedClose={() => setMode('old')} />
        : <JournalVoucherOldList />}
    </div>
  );
}

function JournalVoucherEntryForm({ onSavedClose }) {
  const [date, setDate] = useState(toDateInput(new Date()));
  const [narration, setNarration] = useState('');
  const [lines, setLines] = useState([emptyJvLine(), emptyJvLine()]);
  const [saving, setSaving] = useState(false);
  const [savedNo, setSavedNo] = useState(null);
  const [showReport, setShowReport] = useState(false);
  const { show, ToastHost } = useToast();

  const dateRef = useRef(null);
  const narrationRef = useRef(null);
  const lineRefs = useRef({});
  function getLineRefs(i) {
    if (!lineRefs.current[i]) {
      lineRefs.current[i] = { account: React.createRef(), debit: React.createRef(), credit: React.createRef() };
    }
    return lineRefs.current[i];
  }

  const isDirty = !!narration.trim()
    || lines.some((l) => l.accountId || Number(l.debit) > 0 || Number(l.credit) > 0 || (l.narration && l.narration.trim()));
  const { showUnsavedConfirm, stayOnPage, leavePage } = useUnsavedChangesGuard(isDirty);

  useEffect(() => { dateRef.current?.focus(); }, []);

  function addLine(focus = true) {
    setLines((ls) => {
      const next = [...ls, emptyJvLine()];
      if (focus) {
        const idx = next.length - 1;
        requestAnimationFrame(() => getLineRefs(idx).account.current?.focus());
      }
      return next;
    });
  }
  function updateLine(i, patch) {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  }
  function removeLine(i) {
    setLines((ls) => (ls.length <= 2 ? ls : ls.filter((_, idx) => idx !== i)));
  }

  const totalDebit = lines.reduce((s, l) => s + (Number(l.debit) || 0), 0);
  const totalCredit = lines.reduce((s, l) => s + (Number(l.credit) || 0), 0);
  const balanced = totalDebit > 0 && totalDebit === totalCredit;

  function resetForm() {
    setNarration('');
    setLines([emptyJvLine(), emptyJvLine()]);
    lineRefs.current = {};
    requestAnimationFrame(() => dateRef.current?.focus());
  }

  async function save(closeAfter) {
    const validLines = lines.filter((l) => l.accountId && (Number(l.debit) > 0 || Number(l.credit) > 0));
    if (validLines.length < 2) { show('Add at least two lines with an account and an amount.', 'danger'); return; }
    if (!balanced) { show('Total debit must equal total credit before saving.', 'danger'); return; }
    setSaving(true);
    try {
      const id = await createJournalVoucher({ voucherDate: date, narration, lines: validLines });
      const { voucher } = await fetchJournalVoucherWithLines(id);
      show(`Saved. ${voucher.voucher_no} created.`);
      setSavedNo(voucher.voucher_no);
      resetForm();
      if (closeAfter) onSavedClose?.();
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  function buildDraftJv() {
    const pseudoVoucher = { voucher_no: savedNo || 'DRAFT', voucher_date: date, narration, total_amount: totalDebit };
    const pseudoLines = lines
      .filter((l) => l.accountId && (Number(l.debit) > 0 || Number(l.credit) > 0))
      .map((l) => ({ chart_of_accounts: { name: l.accountName }, debit: l.debit, credit: l.credit, line_narration: l.narration }));
    return { pseudoVoucher, pseudoLines };
  }
  async function draftPrint() {
    const { pseudoVoucher, pseudoLines } = buildDraftJv();
    printPdfDoc(await buildJvPdf(pseudoVoucher, pseudoLines));
  }
  async function draftExportPdf() {
    const { pseudoVoucher, pseudoLines } = buildDraftJv();
    (await buildJvPdf(pseudoVoucher, pseudoLines)).save(`${pseudoVoucher.voucher_no}.pdf`);
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

  return (
    <div className="max-w-4xl">
      <div className="flex flex-wrap items-end gap-4 mb-5">
        <Input
          ref={dateRef} type="date" label="Date" value={date}
          onChange={(e) => setDate(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); narrationRef.current?.focus(); } }}
        />
        <div className="flex-1 min-w-[240px]">
          <Input
            ref={narrationRef} label="Narration (optional)" value={narration}
            onChange={(e) => setNarration(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(0).account.current?.focus(); } }}
          />
        </div>
      </div>

      <div className="flex items-center justify-between mb-2">
        <h3 className="font-medium text-sm text-gray-700">Lines</h3>
        <Button variant="ghost" icon={Plus} onClick={() => addLine()}>Add line</Button>
      </div>

      <Card className="overflow-auto" style={{ borderColor: THEME.line }}>
        <table className="w-full text-sm">
          <thead>
            <tr style={{ backgroundColor: THEME.surface }}>
              <th className="text-left font-medium px-3 py-2.5 w-2/5">Account</th>
              <th className="text-left font-medium px-3 py-2.5">Debit</th>
              <th className="text-left font-medium px-3 py-2.5">Credit</th>
              <th className="px-2 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lines.map((line, i) => (
              <tr key={i} className="border-t align-top" style={{ borderColor: THEME.line }}>
                <td className="px-3 py-2">
                  <AccountPicker
                    value={line.accountId ? { id: line.accountId, name: line.accountName } : null}
                    onChange={(a) => updateLine(i, { accountId: a.id, accountName: a.name })}
                    resetKey={`${i}-${line.accountId || 'empty'}`}
                    inputRef={getLineRefs(i).account}
                    onEnterNext={() => getLineRefs(i).debit.current?.focus()}
                  />
                </td>
                <td className="px-3 py-2 w-36">
                  <Input
                    ref={getLineRefs(i).debit}
                    type="number" label="Debit" value={line.debit}
                    onChange={(e) => updateLine(i, { debit: e.target.value, credit: e.target.value ? '' : line.credit })}
                    onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); getLineRefs(i).credit.current?.focus(); } }}
                  />
                </td>
                <td className="px-3 py-2 w-36">
                  <Input
                    ref={getLineRefs(i).credit}
                    type="number" label="Credit" value={line.credit}
                    onChange={(e) => updateLine(i, { credit: e.target.value, debit: e.target.value ? '' : line.debit })}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') {
                        e.preventDefault();
                        if (i === lines.length - 1) addLine();
                        else getLineRefs(i + 1).account.current?.focus();
                      }
                    }}
                  />
                </td>
                <td className="px-2 py-2 pt-4">
                  {lines.length > 2 && (
                    <button onClick={() => removeLine(i)} aria-label="Remove line" title="Remove line" className="text-gray-400 hover:text-red-500 p-1 -m-1">
                      <X size={18} />
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>

      <div className="flex items-center justify-end gap-6 mt-5 mb-2 text-sm">
        <span>Total Debit: <strong>{formatPkr(totalDebit)}</strong></span>
        <span>Total Credit: <strong>{formatPkr(totalCredit)}</strong></span>
        <Badge tone={balanced ? 'success' : 'danger'}>{balanced ? 'Balanced' : 'Not balanced'}</Badge>
      </div>

      <div className="flex flex-wrap items-center gap-2 mt-3">
        <Button onClick={() => save(false)} loading={saving} disabled={!balanced}>Save</Button>
        <Button variant="outline" onClick={() => save(true)} loading={saving} disabled={!balanced}>Save &amp; Close</Button>
        <Button variant="outline" icon={FileDown} onClick={draftPrint}>Print</Button>
        <Button variant="outline" icon={FileDown} onClick={draftExportPdf}>Export</Button>
        <Button variant="outline" icon={FileDown} onClick={() => setShowReport(true)}>Report</Button>
        {savedNo && <Badge tone="success">Last saved: {savedNo}</Badge>}
      </div>
      <p className="text-xs text-gray-500 mt-2">
        Enter moves Date → Narration → Account → Debit → Credit → next line. Ctrl+S saves once the two sides balance, Ctrl+P prints the draft.
      </p>
      <SimpleReportModal
        open={showReport} onClose={() => setShowReport(false)}
        title="Journal Voucher"
        buildPdfDoc={() => { const { pseudoVoucher, pseudoLines } = buildDraftJv(); return buildJvPdf(pseudoVoucher, pseudoLines); }}
        excelData={{
          columns: ['Account', 'Debit', 'Credit', 'Narration'],
          rows: lines.filter((l) => l.accountId).map((l) => [l.accountName, Number(l.debit) || 0, Number(l.credit) || 0, l.narration || '']),
        }}
      />
      <UnsavedChangesModal open={showUnsavedConfirm} onStay={stayOnPage} onLeave={leavePage} />
      <ToastHost />
    </div>
  );
}

async function buildJvPdf(voucher, lines) {
  const { jsPDF, autoTable } = await loadPdfLibs();
  const doc = new jsPDF();
  let textX = 14;
  try {
    const [logo1, logo2] = await Promise.all([loadImageAsDataUrl(logoSkfPolytex), loadImageAsDataUrl(logoSkfPolybags)]);
    doc.addImage(logo1, 'PNG', 14, 8, 14, 14);
    doc.addImage(logo2, 'PNG', 29, 8, 14, 14);
    textX = 47;
  } catch {
    // fall back to text-only header if the logos can't be loaded
  }
  doc.setFontSize(14);
  doc.text('JOURNAL VOUCHER', textX, 16);
  doc.setFontSize(10);
  doc.setTextColor(120);
  doc.text(`Voucher No: ${voucher.voucher_no}`, textX, 23);
  doc.text(`Date: ${formatDate(voucher.voucher_date)}${voucher.narration ? `   ${voucher.narration}` : ''}`, textX, 29);
  doc.text(`Generated ${formatDate(new Date())}`, doc.internal.pageSize.getWidth() - 14, 16, { align: 'right' });

  const rows = lines.map((l) => [l.chart_of_accounts?.name || '', l.debit > 0 ? formatPkr(l.debit) : '', l.credit > 0 ? formatPkr(l.credit) : '', l.line_narration || '']);
  const totalDebit = lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const totalCredit = lines.reduce((s, l) => s + Number(l.credit || 0), 0);

  autoTable(doc, {
    startY: 35,
    head: [['Account', 'Debit', 'Credit', 'Narration']],
    body: rows,
    foot: [['Total', formatPkr(totalDebit), formatPkr(totalCredit), '']],
    headStyles: { fillColor: [227, 230, 236], textColor: [18, 20, 28], fontStyle: 'bold' },
    footStyles: { fillColor: [247, 248, 250], textColor: [18, 20, 28], fontStyle: 'bold' },
    styles: { fontSize: 9, cellPadding: 3 },
    didDrawPage: () => drawPdfFooter(doc),
  });
  return doc;
}

function JournalVoucherViewModal({ doc, onClose }) {
  if (!doc) return null;
  const { voucher, lines } = doc;
  return (
    <Modal open={!!doc} onClose={onClose} title={voucher.voucher_no} width={560}>
      <div className="space-y-3 text-sm">
        <div className="grid grid-cols-2 gap-2">
          <div><span className="text-gray-500">Date:</span> {formatDate(voucher.voucher_date)}</div>
          <div><span className="text-gray-500">Status:</span> <Badge tone={voucher.status === 'voided' ? 'danger' : 'success'}>{voucher.status}</Badge></div>
          {voucher.narration && <div className="col-span-2"><span className="text-gray-500">Narration:</span> {voucher.narration}</div>}
        </div>
        <Card className="overflow-auto" style={{ borderColor: THEME.line }}>
          <table className="w-full text-sm">
            <thead>
              <tr style={{ backgroundColor: THEME.surface }}>
                <th className="text-left px-3 py-2">Account</th>
                <th className="text-left px-3 py-2">Debit</th>
                <th className="text-left px-3 py-2">Credit</th>
              </tr>
            </thead>
            <tbody>
              {lines.map((l) => (
                <tr key={l.id} className="border-t" style={{ borderColor: THEME.line }}>
                  <td className="px-3 py-2">{l.chart_of_accounts?.name}</td>
                  <td className="px-3 py-2">{l.debit > 0 ? formatPkr(l.debit) : ''}</td>
                  <td className="px-3 py-2">{l.credit > 0 ? formatPkr(l.credit) : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
        <div className="text-right font-bold" style={{ color: THEME.blue }}>Total: {formatPkr(voucher.total_amount)}</div>
      </div>
    </Modal>
  );
}

function JournalVoucherOldList() {
  const { permissions } = useAuth();
  const canApprove = !!permissions.entry_jv?.can_approve;

  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [voucherNo, setVoucherNo] = useState('');
  const [rows, setRows] = useState(null);
  const [viewDoc, setViewDoc] = useState(null);
  const [reportDoc, setReportDoc] = useState(null);
  const [voidTarget, setVoidTarget] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchJournalVouchers({ from, to, voucherNo }).then((r) => { if (alive) setRows(r); });
    return () => { alive = false; };
  }, [from, to, voucherNo, refreshKey]);

  async function handleView(row) {
    try { setViewDoc(await fetchJournalVoucherWithLines(row.id)); }
    catch (e) { show(`Could not load voucher: ${e.message}`, 'danger'); }
  }
  async function handleReport(row) {
    try { setReportDoc(await fetchJournalVoucherWithLines(row.id)); }
    catch (e) { show(`Could not load voucher: ${e.message}`, 'danger'); }
  }
  async function handlePrint(row) {
    try { const { voucher, lines } = await fetchJournalVoucherWithLines(row.id); printPdfDoc(await buildJvPdf(voucher, lines)); }
    catch (e) { show(`Could not print: ${e.message}`, 'danger'); }
  }
  async function handleExportPdf(row) {
    try { const { voucher, lines } = await fetchJournalVoucherWithLines(row.id); (await buildJvPdf(voucher, lines)).save(`${voucher.voucher_no}.pdf`); }
    catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleExportExcel(row) {
    try {
      const { lines } = await fetchJournalVoucherWithLines(row.id);
      exportExcel({
        title: row.voucher_no,
        columns: ['Account', 'Debit', 'Credit'],
        rows: lines.map((l) => [l.chart_of_accounts?.name || '', l.debit, l.credit]),
      });
    } catch (e) { show(`Could not export: ${e.message}`, 'danger'); }
  }
  async function handleVoidConfirm(reason) {
    try {
      await voidJournalVoucher(voidTarget.id, reason);
      show(`${voidTarget.voucher_no} voided.`);
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
        <div className="w-40">
          <Input label="Voucher #" value={voucherNo} onChange={(e) => setVoucherNo(e.target.value)} placeholder="Search…" />
        </div>
        {voucherNo && <Button variant="ghost" onClick={() => setVoucherNo('')}>Clear</Button>}
      </div>

      {rows === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : rows.length === 0 ? (
        <EmptyState>No general vouchers in this range.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {rows.map((row) => (
            <div key={row.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
              <div className="flex-1 min-w-[180px]">
                <div className="font-medium flex items-center gap-2">
                  {row.voucher_no}
                  {row.status === 'voided' && <Badge tone="danger">Voided</Badge>}
                </div>
                <div className="text-xs text-gray-500">{formatDate(row.voucher_date)}{row.narration ? ` · ${row.narration}` : ''}</div>
              </div>
              <div className="font-semibold w-28 text-right" style={{ color: THEME.blue }}>{formatPkr(row.total_amount)}</div>
              <div className="flex items-center gap-1">
                <button onClick={() => handleView(row)} title="View" aria-label="View" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <Search size={16} />
                </button>
                <button onClick={() => handlePrint(row)} title="Print" aria-label="Print" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportPdf(row)} title="Export PDF" aria-label="Export PDF" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                <button onClick={() => handleExportExcel(row)} title="Export Excel" aria-label="Export Excel" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileSpreadsheet size={16} />
                </button>
                <button onClick={() => handleReport(row)} title="Report" aria-label="Report" className="p-2.5 rounded-lg hover:bg-gray-100 text-gray-500">
                  <FileDown size={16} />
                </button>
                {canApprove && row.status === 'posted' && (
                  <button onClick={() => setVoidTarget(row)} title="Void" aria-label="Void" className="p-2.5 rounded-lg hover:bg-red-50 text-red-500">
                    <X size={16} />
                  </button>
                )}
              </div>
            </div>
          ))}
        </Card>
      )}

      <JournalVoucherViewModal doc={viewDoc} onClose={() => setViewDoc(null)} />
      <SimpleReportModal
        open={!!reportDoc} onClose={() => setReportDoc(null)}
        title="Journal Voucher"
        buildPdfDoc={() => buildJvPdf(reportDoc.voucher, reportDoc.lines)}
        excelData={reportDoc ? {
          columns: ['Account', 'Debit', 'Credit', 'Narration'],
          rows: reportDoc.lines.map((l) => [l.chart_of_accounts?.name || '', l.debit, l.credit, l.line_narration || '']),
        } : null}
      />
      <VoidReasonModal target={voidTarget} onClose={() => setVoidTarget(null)} onConfirm={handleVoidConfirm} />
      <ToastHost />
    </div>
  );
}

// ============================================================================
// MATERIAL CHART — browsable, category-wise Item Master (parallel to Chart
// of Accounts). Guided "Add Fabric" flow: Category -> Group (In House /
// Knitting + Dying, fabric only) -> Name -> Composition (fabric only) ->
// Unit.
// ============================================================================

const MATERIAL_CATEGORIES = [
  { key: null, label: 'All' },
  { key: 'fabric', label: 'Fabric' },
  { key: 'polybags', label: 'Poly Bags' },
];

function fabricGroupLabel(key) {
  return FABRIC_GROUPS.find((g) => g.key === key)?.label || key;
}

function MaterialChartScreen() {
  const [catFilter, setCatFilter] = useState(null);
  const [search, setSearch] = useState('');
  const [items, setItems] = useState(null);
  const [showAdd, setShowAdd] = useState(false);
  const [editItem, setEditItem] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    let alive = true;
    setItems(null);
    fetchItems({ search, category: catFilter }).then((rows) => { if (alive) setItems(rows); });
    return () => { alive = false; };
  }, [search, catFilter, refreshKey]);

  return (
    <div>
      <div className="flex flex-wrap items-end gap-3 mb-5">
        <div className="flex-1 min-w-[220px]">
          <Input label="Search material" placeholder="Type a name…" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
          {MATERIAL_CATEGORIES.map((c) => (
            <button
              key={c.label}
              onClick={() => setCatFilter(c.key)}
              className="px-3 py-1.5 rounded-md text-sm font-medium"
              style={catFilter === c.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
            >
              {c.label}
            </button>
          ))}
        </div>
        <Button icon={Plus} onClick={() => setShowAdd(true)}>Add Fabric</Button>
      </div>

      {items === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : items.length === 0 ? (
        <EmptyState>No materials found.</EmptyState>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {items.map((it) => (
            <button
              key={it.id}
              onClick={() => setEditItem(it)}
              className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-gray-50"
            >
              <div>
                <div className="font-medium text-sm">{it.name}</div>
                <div className="text-xs text-gray-500">
                  {it.category === 'fabric' ? 'Fabric' : 'Poly Bags'} &middot; {it.default_unit}
                  {it.fabric_group ? ` · ${fabricGroupLabel(it.fabric_group)}` : ''}
                  {it.composition ? ` · ${it.composition}` : ''}
                </div>
              </div>
              <ChevronRight size={18} className="text-gray-300 flex-shrink-0" />
            </button>
          ))}
        </Card>
      )}

      <AddMaterialModal open={showAdd} onClose={() => setShowAdd(false)} onCreated={() => { setShowAdd(false); setRefreshKey((k) => k + 1); }} />
      <EditMaterialModal item={editItem} onClose={() => setEditItem(null)} onSaved={() => { setEditItem(null); setRefreshKey((k) => k + 1); }} />
    </div>
  );
}

function AddMaterialModal({ open, onClose, onCreated }) {
  const [category, setCategory] = useState('fabric');
  const [fabricGroup, setFabricGroup] = useState(FABRIC_GROUPS[0].key);
  const [name, setName] = useState('');
  const [composition, setComposition] = useState('');
  const [unit, setUnit] = useState(purchaseUnitOptionsFor('fabric')[0]);
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();
  const isFabric = category === 'fabric';

  useEffect(() => {
    if (!open) return;
    setCategory('fabric'); setFabricGroup(FABRIC_GROUPS[0].key);
    setName(''); setComposition(''); setUnit(purchaseUnitOptionsFor('fabric')[0]);
  }, [open]);

  async function submit() {
    if (!name.trim()) { show('Enter a name.', 'danger'); return; }
    setSaving(true);
    try {
      await createItem({
        name: name.trim(), category, defaultUnit: unit,
        fabricGroup: isFabric ? fabricGroup : null,
        composition: isFabric ? composition : null,
      });
      onCreated();
    } catch (e) {
      show(`Could not add material: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="Add Fabric" width={440}>
      <div className="space-y-3">
        <div>
          <div className="text-sm font-medium mb-1.5" style={{ color: THEME.ink }}>Category</div>
          <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
            {[{ k: 'fabric', l: 'Fabric' }, { k: 'polybags', l: 'Poly Bags' }].map((c) => (
              <button
                key={c.k}
                type="button"
                onClick={() => { setCategory(c.k); setUnit(purchaseUnitOptionsFor(c.k)[0]); }}
                className="px-3 py-1.5 rounded-md text-sm font-medium"
                style={category === c.k ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
              >
                {c.l}
              </button>
            ))}
          </div>
        </div>

        {isFabric && (
          <div>
            <div className="text-sm font-medium mb-1.5" style={{ color: THEME.ink }}>Group</div>
            <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
              {FABRIC_GROUPS.map((g) => (
                <button
                  key={g.key}
                  type="button"
                  onClick={() => setFabricGroup(g.key)}
                  className="px-3 py-1.5 rounded-md text-sm font-medium"
                  style={fabricGroup === g.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
                >
                  {g.label}
                </button>
              ))}
            </div>
          </div>
        )}

        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />

        {isFabric && (
          <Input label="Composition (optional)" placeholder="e.g. 65% Cotton, 35% Polyester" value={composition} onChange={(e) => setComposition(e.target.value)} />
        )}

        <Select label="Unit" value={unit} onChange={(e) => setUnit(e.target.value)}>
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

function EditMaterialModal({ item, onClose, onSaved }) {
  const [name, setName] = useState('');
  const [fabricGroup, setFabricGroup] = useState(FABRIC_GROUPS[0].key);
  const [composition, setComposition] = useState('');
  const [unit, setUnit] = useState('KG');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();
  const isFabric = item?.category === 'fabric';

  useEffect(() => {
    if (!item) return;
    setName(item.name || '');
    setFabricGroup(item.fabric_group || FABRIC_GROUPS[0].key);
    setComposition(item.composition || '');
    setUnit(item.default_unit || 'KG');
  }, [item]);

  if (!item) return null;

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      await updateItem({
        id: item.id, name: name.trim(), defaultUnit: unit,
        fabricGroup: isFabric ? fabricGroup : null,
        composition: isFabric ? composition : null,
      });
      onSaved();
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={!!item} onClose={onClose} title={`Edit ${isFabric ? 'fabric' : 'material'}`} width={440}>
      <div className="space-y-3">
        {isFabric && (
          <div>
            <div className="text-sm font-medium mb-1.5" style={{ color: THEME.ink }}>Group</div>
            <div className="inline-flex rounded-lg border p-1 bg-white" style={{ borderColor: THEME.line }}>
              {FABRIC_GROUPS.map((g) => (
                <button
                  key={g.key}
                  type="button"
                  onClick={() => setFabricGroup(g.key)}
                  className="px-3 py-1.5 rounded-md text-sm font-medium"
                  style={fabricGroup === g.key ? { backgroundColor: THEME.blue, color: 'white' } : { color: THEME.ink }}
                >
                  {g.label}
                </button>
              ))}
            </div>
          </div>
        )}
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
        {isFabric && (
          <Input label="Composition (optional)" placeholder="e.g. 65% Cotton, 35% Polyester" value={composition} onChange={(e) => setComposition(e.target.value)} />
        )}
        <Select label="Unit" value={unit} onChange={(e) => setUnit(e.target.value)}>
          {purchaseUnitOptionsFor(item.category).map((u) => <option key={u} value={u}>{u}</option>)}
        </Select>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} loading={saving}>Save</Button>
        </div>
      </div>
      <ToastHost />
    </Modal>
  );
}

// ============================================================================
// CHART OF ACCOUNTS — merges what used to be Party Master, the Admin-only
// ledger-account manager, and the Reports page's General Ledger / Trial
// Balance into one screen with four tabs. Parties and system accounts are
// really the same concept (every party has an auto-generated
// chart_of_accounts row) — this screen is where you look up either kind of
// account's ledger, not just parties.
// ============================================================================

const COA_TABS = [
  { key: 'parties', label: 'Parties' },
  { key: 'accounts', label: 'Accounts' },
  { key: 'ledger', label: 'General Ledger' },
  { key: 'trial', label: 'Trial Balance' },
];

function ChartOfAccountsScreen({ initialTab }) {
  const [tab, setTab] = useState(initialTab || 'parties');
  return (
    <div>
      <div className="flex flex-wrap gap-2 mb-5">
        {COA_TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className="px-3 py-1.5 rounded-full text-sm font-medium border"
            style={tab === t.key ? { backgroundColor: THEME.blue, color: 'white', borderColor: THEME.blue } : { borderColor: THEME.line }}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'parties' && <PartiesTab />}
      {tab === 'accounts' && <AccountsTab />}
      {tab === 'ledger' && <GeneralLedgerTab />}
      {tab === 'trial' && <TrialBalanceReport />}
    </div>
  );
}

function PartiesTab() {
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
    return <PartyStatementView party={selected} onBack={() => setSelected(null)} onUpdated={() => setRefreshKey((k) => k + 1)} />;
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
  const [email, setEmail] = useState('');
  const [ntn, setNtn] = useState('');
  const [stn, setStn] = useState('');
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
      await createParty({ name: name.trim(), type, category: categories, contact, address, email, ntn, stn, openingBalance: Number(opening) || 0 });
      setName(''); setContact(''); setAddress(''); setEmail(''); setNtn(''); setStn(''); setOpening('0');
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
        <Input label="Mobile number" value={contact} onChange={(e) => setContact(e.target.value)} />
        <Input label="Email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Input label="Address" value={address} onChange={(e) => setAddress(e.target.value)} />
        <div className="grid grid-cols-2 gap-3">
          <Input label="NTN" value={ntn} onChange={(e) => setNtn(e.target.value)} />
          <Input label="STN" value={stn} onChange={(e) => setStn(e.target.value)} />
        </div>
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

function PartyStatementView({ party: initialParty, onBack, onUpdated }) {
  const [party, setParty] = useState(initialParty);
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showEdit, setShowEdit] = useState(false);

  useEffect(() => {
    let alive = true;
    fetchPartyStatement(party.ledger_account_id).then((rows) => { if (alive) setEntries(rows); }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [party.ledger_account_id]);

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
      <div className="flex items-center justify-between mb-1">
        <h2 className="font-display font-semibold text-lg">{party.name}</h2>
        <Button variant="ghost" onClick={() => setShowEdit(true)}>Edit details</Button>
      </div>
      <div className="text-sm text-gray-500 mb-4 space-y-0.5">
        {party.contact && <div>Mobile: {party.contact}</div>}
        {party.email && <div>Email: {party.email}</div>}
        {party.address && <div>Address: {party.address}</div>}
        {(party.ntn || party.stn) && (
          <div>{party.ntn ? `NTN: ${party.ntn}` : ''}{party.ntn && party.stn ? ' · ' : ''}{party.stn ? `STN: ${party.stn}` : ''}</div>
        )}
      </div>

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

      <EditPartyModal
        open={showEdit}
        party={party}
        onClose={() => setShowEdit(false)}
        onSaved={(updated) => { setParty(updated); setShowEdit(false); onUpdated?.(); }}
      />
    </div>
  );
}

function EditPartyModal({ open, party, onClose, onSaved }) {
  const [name, setName] = useState('');
  const [contact, setContact] = useState('');
  const [address, setAddress] = useState('');
  const [email, setEmail] = useState('');
  const [ntn, setNtn] = useState('');
  const [stn, setStn] = useState('');
  const [saving, setSaving] = useState(false);
  const { show, ToastHost } = useToast();

  useEffect(() => {
    if (!open) return;
    setName(party.name || '');
    setContact(party.contact || '');
    setAddress(party.address || '');
    setEmail(party.email || '');
    setNtn(party.ntn || '');
    setStn(party.stn || '');
  }, [open, party]);

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      await updateParty({ id: party.id, name: name.trim(), contact, address, email, ntn, stn });
      onSaved({ ...party, name: name.trim(), contact, address, email, ntn, stn });
    } catch (e) {
      show(`Could not save: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`Edit ${party.type === 'customer' ? 'customer' : 'vendor'}`} width={440}>
      <div className="space-y-3">
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
        <Input label="Mobile number" value={contact} onChange={(e) => setContact(e.target.value)} />
        <Input label="Email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Input label="Address" value={address} onChange={(e) => setAddress(e.target.value)} />
        <div className="grid grid-cols-2 gap-3">
          <Input label="NTN" value={ntn} onChange={(e) => setNtn(e.target.value)} />
          <Input label="STN" value={stn} onChange={(e) => setStn(e.target.value)} />
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} loading={saving}>Save</Button>
        </div>
      </div>
      <ToastHost />
    </Modal>
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

const ADMIN_TABS = [
  { key: 'profile', label: 'Profile & Alerts' },
  { key: 'users', label: 'Users' },
  { key: 'audit', label: 'Voucher Audit' },
];

function SettingsScreen() {
  const { profile } = useAuth();
  const [tab, setTab] = useState('profile');
  const tabs = profile?.is_admin ? ADMIN_TABS : ADMIN_TABS.filter((t) => t.key === 'profile');

  return (
    <div className="max-w-3xl">
      {tabs.length > 1 && (
        <div className="flex flex-wrap gap-2 mb-5">
          {tabs.map((t) => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className="px-3 py-1.5 rounded-full text-sm font-medium border"
              style={tab === t.key ? { backgroundColor: THEME.blue, color: 'white', borderColor: THEME.blue } : { borderColor: THEME.line }}
            >
              {t.label}
            </button>
          ))}
        </div>
      )}

      {tab === 'profile' && (
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
          {profile?.is_admin && <DashboardAlertSettings />}
        </div>
      )}

      {tab === 'users' && profile?.is_admin && <PermissionsScreen />}
      {tab === 'audit' && profile?.is_admin && <VoucherAuditTab />}
    </div>
  );
}

function VoucherAuditTab() {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let alive = true;
    fetchUnpostedDocuments()
      .then((r) => { if (alive) setRows(r); })
      .catch((e) => { if (alive) setError(e.message); });
    return () => { alive = false; };
  }, []);

  return (
    <div>
      <p className="text-sm text-gray-500 mb-4">
        Every posted Bill, Voucher, and Journal Voucher writes its ledger entries in the same step it's saved —
        this list should normally be empty. Anything shown here didn't hit the General Ledger / Trial Balance
        the way it should and needs a look.
      </p>
      {error && <div className="text-sm mb-4" style={{ color: THEME.danger }}>Could not load: {error}</div>}
      {rows === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : rows.length === 0 ? (
        <Card className="p-6 flex flex-col items-center text-center gap-2">
          <ShieldCheck size={22} style={{ color: THEME.success }} />
          <span className="text-sm text-gray-500">All posted documents are correctly reflected in the ledger.</span>
        </Card>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {rows.map((r, i) => (
            <div key={i} className="px-4 py-3">
              <div className="flex items-center justify-between">
                <div className="font-medium text-sm">{r.doc_type} {r.doc_no}</div>
                <div className="text-sm font-semibold" style={{ color: THEME.danger }}>{formatPkr(r.amount)}</div>
              </div>
              <div className="text-xs text-gray-500">{formatDate(r.doc_date)} &middot; {r.party_name}</div>
              <div className="text-xs mt-1" style={{ color: THEME.danger }}>{r.note} &middot; ledger total {formatPkr(r.ledger_total)}</div>
            </div>
          ))}
        </Card>
      )}
    </div>
  );
}

function AccountsTab() {
  const { profile } = useAuth();
  const [accounts, setAccounts] = useState(null);
  const [name, setName] = useState('');
  const [type, setType] = useState('expense');
  const [cashBankKind, setCashBankKind] = useState('cash');
  const [parentAccount, setParentAccount] = useState(null);
  const [openingBalance, setOpeningBalance] = useState('0');
  const [openingBalanceType, setOpeningBalanceType] = useState('debit');
  const [saving, setSaving] = useState(false);
  const [ledgerAccount, setLedgerAccount] = useState(null);
  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const { show, ToastHost } = useToast();

  function reload() {
    fetchChartOfAccounts().then((rows) => setAccounts(rows.filter((a) => a.type !== 'party')));
  }
  useEffect(() => { reload(); }, []);

  async function submit() {
    if (!name.trim()) return;
    setSaving(true);
    try {
      await createAccount({
        name: name.trim(), type, cashBankKind,
        parentAccountId: parentAccount?.id, openingBalance, openingBalanceType,
      });
      show('Account added.');
      setName(''); setParentAccount(null); setOpeningBalance('0'); setOpeningBalanceType('debit');
      reload();
    } catch (e) {
      show(`Could not add account: ${e.message}`, 'danger');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="max-w-2xl">
      {profile?.is_admin && (
        <Card className="p-4 mb-5 space-y-3" style={{ borderColor: THEME.line }}>
          <div className="flex flex-wrap items-end gap-3">
            <div className="flex-1 min-w-[180px]">
              <Input label="Account name" value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <div className="w-40">
              <Select label="Type" value={type} onChange={(e) => setType(e.target.value)}>
                <option value="expense">Expense</option>
                <option value="cash_bank">Cash / Bank</option>
                <option value="sales">Sales</option>
                <option value="purchase">Purchase</option>
                <option value="drawings">Drawings</option>
                <option value="asset">Asset</option>
                <option value="liability">Liability</option>
                <option value="capital">Capital / Equity</option>
                <option value="income">Income (other)</option>
              </Select>
            </div>
            {type === 'cash_bank' && (
              <div className="w-32">
                <Select label="Kind" value={cashBankKind} onChange={(e) => setCashBankKind(e.target.value)}>
                  <option value="cash">Cash</option>
                  <option value="bank">Bank</option>
                </Select>
              </div>
            )}
          </div>
          <div className="flex flex-wrap items-end gap-3">
            <div className="flex-1 min-w-[180px]">
              <AccountPicker value={parentAccount} onChange={setParentAccount} />
              <p className="text-xs text-gray-500 mt-1">Parent account (optional)</p>
            </div>
            <div className="w-40">
              <Input label="Opening balance" type="number" value={openingBalance} onChange={(e) => setOpeningBalance(e.target.value)} />
            </div>
            <div className="w-32">
              <Select label="Type" value={openingBalanceType} onChange={(e) => setOpeningBalanceType(e.target.value)}>
                <option value="debit">Debit</option>
                <option value="credit">Credit</option>
              </Select>
            </div>
            <Button onClick={submit} loading={saving}>Add account</Button>
          </div>
        </Card>
      )}

      {accounts === null ? (
        <div className="py-20 flex justify-center"><Spinner /></div>
      ) : (
        <Card className="divide-y" style={{ borderColor: THEME.line }}>
          {accounts.map((a) => (
            <button
              key={a.id}
              onClick={() => setLedgerAccount({ id: a.id, name: a.name })}
              className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-gray-50"
            >
              <div>
                <div className="font-medium text-sm">{a.name}</div>
                <div className="text-xs text-gray-500 capitalize">
                  {a.type.replace('_', ' ')}{a.cash_bank_kind ? ` · ${a.cash_bank_kind}` : ''}{a.is_system ? ' · system' : ''}
                </div>
              </div>
              <ChevronRight size={18} className="text-gray-300 flex-shrink-0" />
            </button>
          ))}
        </Card>
      )}

      <AccountLedgerModal account={ledgerAccount} from={from} to={to} onClose={() => setLedgerAccount(null)} />
      <ToastHost />
    </div>
  );
}

function GeneralLedgerTab() {
  const [from, setFrom] = useState(toDateInput(startOfMonth()));
  const [to, setTo] = useState(toDateInput(new Date()));
  const [account, setAccount] = useState(null);
  return (
    <div>
      <div className="flex flex-wrap items-end gap-4 mb-5">
        <div className="max-w-xs w-full">
          <AccountPicker value={account} onChange={setAccount} />
        </div>
        <ReportFilterBar from={from} to={to} onFromChange={setFrom} onToChange={setTo} />
      </div>
      {account ? (
        <AccountLedgerBody account={account} from={from} to={to} />
      ) : (
        <EmptyState>Select an account to view its General Ledger.</EmptyState>
      )}
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
      {onBack && <button onClick={onBack} className="text-sm text-gray-500 mb-4 hover:text-gray-800">&larr; Back to settings</button>}
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
