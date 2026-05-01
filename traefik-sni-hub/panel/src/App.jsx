import { useState, useCallback, useEffect, useRef } from 'react'
import QRCodeStyling from 'qr-code-styling'
import './App.css'

// ─── API ──────────────────────────────────────────────────────────────────────
const api = {
  async _fetch(path, opts = {}) {
    const r = await fetch(path, { credentials: 'include', ...opts })
    if (r.status === 401) {
      window.location.href = '/'
      return null
    }
    if (r.status === 204) return null
    const body = await r.json().catch(() => ({}))
    if (!r.ok) throw new Error(body.detail || `HTTP ${r.status}`)
    return body
  },
  getConfig:  ()           => api._fetch('/api/v1/config'),
  getUsers:   ()           => api._fetch('/api/v1/users'),
  createUser: (name, maxConn) => api._fetch('/api/v1/users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, maxConn }),
  }),
  updateUser: (id, data)   => api._fetch(`/api/v1/users/${id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  }),
  deleteUser: (id)         => api._fetch(`/api/v1/users/${id}`, { method: 'DELETE' }),
  logout:     ()           => api._fetch('/api/v1/auth/logout', { method: 'POST' }),
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
function buildTgLink(secret, serverIp) {
  return `tg://proxy?server=${serverIp}&port=443&secret=${secret}`
}

function formatLastSeen(value) {
  if (!value || value === 'never') return 'never'
  const dt = new Date(value.replace(' ', 'T') + 'Z')
  if (isNaN(dt.getTime())) return value
  return dt.toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' })
}

function initials(name) {
  return name.slice(0, 2).toUpperCase()
}

function avatarColor(name) {
  const colors = ['#3b82f6', '#8b5cf6', '#10b981', '#f59e0b', '#ef4444', '#06b6d4', '#ec4899']
  let h = 0
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0
  return colors[h % colors.length]
}

// ─── Icons ────────────────────────────────────────────────────────────────────
const IconCopy    = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
const IconCheck   = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"/></svg>
const IconEye     = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>
const IconEyeOff  = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg>
const IconPlus    = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
const IconTrash   = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>
const IconPower   = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>
const IconQR      = () => <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="5" y="5" width="3" height="3" fill="currentColor" stroke="none"/><rect x="16" y="5" width="3" height="3" fill="currentColor" stroke="none"/><rect x="5" y="16" width="3" height="3" fill="currentColor" stroke="none"/><line x1="14" y1="14" x2="14" y2="14"/><line x1="17" y1="14" x2="17" y2="14"/><line x1="20" y1="14" x2="20" y2="14"/><line x1="14" y1="17" x2="14" y2="17"/><line x1="17" y1="17" x2="20" y2="17"/><line x1="20" y1="20" x2="20" y2="20"/><line x1="14" y1="20" x2="17" y2="20"/></svg>
const IconNode    = () => <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 2L13 5V11L8 14L3 11V5L8 2Z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round"/><circle cx="8" cy="8" r="1.5" fill="currentColor"/></svg>
const IconArrowLeft = () => <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>
const IconUsers   = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
const IconLink    = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>
const IconLogout  = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
const IconEdit    = () => <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>

// ─── useCopyFeedback ──────────────────────────────────────────────────────────
function useCopyFeedback() {
  const [copied, setCopied] = useState(null)
  const copy = useCallback((text, key) => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(key)
      setTimeout(() => setCopied(null), 1800)
    })
  }, [])
  return [copied, copy]
}

// ─── ErrorToast ───────────────────────────────────────────────────────────────
function ErrorToast({ message, onDismiss }) {
  useEffect(() => {
    if (!message) return
    const t = setTimeout(onDismiss, 5000)
    return () => clearTimeout(t)
  }, [message, onDismiss])

  if (!message) return null
  return (
    <div className="error-toast" onClick={onDismiss}>
      {message}
    </div>
  )
}

// ─── Modal ────────────────────────────────────────────────────────────────────
function Modal({ title, onClose, children }) {
  return (
    <div className="modal-overlay" onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="modal">
        <div className="modal-header">
          <span className="modal-title">{title}</span>
          <button className="modal-close" onClick={onClose}>✕</button>
        </div>
        {children}
      </div>
    </div>
  )
}

// ─── AddUserModal ─────────────────────────────────────────────────────────────
function AddUserModal({ onAdd, onClose }) {
  const [name, setName]       = useState('')
  const [maxConn, setMaxConn] = useState('15')
  const [error, setError]     = useState('')
  const [busy, setBusy]       = useState(false)

  async function submit(e) {
    e.preventDefault()
    const trimmed = name.trim()
    if (!trimmed) { setError('Name is required'); return }
    if (!/^[a-z0-9_-]+$/i.test(trimmed)) { setError('Only letters, digits, - and _ allowed'); return }
    const n = parseInt(maxConn, 10)
    if (!n || n < 1 || n > 100) { setError('Connections: 1–100'); return }
    setBusy(true)
    try {
      await onAdd(trimmed, n)
    } catch (err) {
      setError(err.message)
      setBusy(false)
    }
  }

  return (
    <Modal title="New user" onClose={onClose}>
      <form onSubmit={submit} className="modal-body">
        <label className="form-label">
          Name
          <input
            className="form-input"
            placeholder="e.g. alice"
            value={name}
            onChange={e => { setName(e.target.value); setError('') }}
            autoFocus
          />
        </label>
        <label className="form-label">
          Max connections
          <input
            className="form-input"
            type="number"
            min="1"
            max="100"
            value={maxConn}
            onChange={e => { setMaxConn(e.target.value); setError('') }}
          />
        </label>
        {error && <p className="form-error">{error}</p>}
        <div className="modal-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="btn btn-primary" disabled={busy}>
            {busy ? <span className="btn-spinner" /> : 'Create'}
          </button>
        </div>
      </form>
    </Modal>
  )
}

// ─── DeleteModal ──────────────────────────────────────────────────────────────
function DeleteModal({ user, onConfirm, onClose, busy }) {
  return (
    <Modal title="Delete user" onClose={onClose}>
      <div className="modal-body">
        <p className="modal-text">
          Remove <strong style={{ color: 'var(--text-primary)' }}>{user.name}</strong>?
          All connections using this secret will be terminated immediately.
        </p>
        <div className="modal-actions">
          <button className="btn btn-ghost" onClick={onClose} disabled={busy}>Cancel</button>
          <button className="btn btn-danger" onClick={onConfirm} disabled={busy}>
            {busy ? <span className="btn-spinner" /> : 'Delete'}
          </button>
        </div>
      </div>
    </Modal>
  )
}

// ─── StatusDot ────────────────────────────────────────────────────────────────
function StatusDot({ active }) {
  return <span className={`status-dot ${active ? 'status-dot--on' : 'status-dot--off'}`} />
}

// ─── StatCard ─────────────────────────────────────────────────────────────────
function StatCard({ icon, label, value }) {
  return (
    <div className="stat-card">
      <div className="stat-icon">{icon}</div>
      <div>
        <div className="stat-value">{value}</div>
        <div className="stat-label">{label}</div>
      </div>
    </div>
  )
}

// ─── UserRow ──────────────────────────────────────────────────────────────────
function UserRow({ user, selected, onClick }) {
  const pct = user.maxConn > 0 ? (user.conn / user.maxConn) * 100 : 0
  return (
    <button className={`user-row ${selected ? 'user-row--active' : ''}`} onClick={onClick}>
      <div className="user-row-avatar" style={{ background: avatarColor(user.name) }}>
        {initials(user.name)}
      </div>
      <div className="user-row-info">
        <div className="user-row-name">
          <StatusDot active={user.active} />
          {user.name}
        </div>
        <div className="user-row-bar">
          <div className="mini-bar">
            <div className="mini-bar-fill" style={{ width: `${pct}%`, background: user.active ? 'var(--accent)' : 'var(--text-muted)' }} />
          </div>
          <span className="user-row-conn">{user.conn}/{user.maxConn}</span>
        </div>
      </div>
    </button>
  )
}

// ─── DetailItem ───────────────────────────────────────────────────────────────
function DetailItem({ label, value, accent }) {
  return (
    <div className="detail-item">
      <div className="detail-label">{label}</div>
      <div className="detail-value" style={accent ? { color: accent } : {}}>{value}</div>
    </div>
  )
}

// ─── CopyField ────────────────────────────────────────────────────────────────
function CopyField({ label, value, display, copiedKey, onCopy, mono, actions }) {
  return (
    <div className="copy-field">
      <div className="copy-field-label">{label}</div>
      <div className="copy-field-row">
        <div className={`copy-field-value ${mono ? 'mono' : ''}`}>{display ?? value}</div>
        <div className="copy-field-actions">
          {actions}
          <button
            className={`icon-btn ${copiedKey ? 'icon-btn--ok' : ''}`}
            onClick={() => onCopy(value, label)}
            title="Copy"
          >
            {copiedKey ? <IconCheck /> : <IconCopy />}
          </button>
        </div>
      </div>
    </div>
  )
}

// ─── QRImage ──────────────────────────────────────────────────────────────────
function QRImage({ value }) {
  const [src, setSrc] = useState(null)

  useEffect(() => {
    if (!value) return
    new QRCodeStyling({
      width: 120, height: 120,
      type: 'svg',
      data: value,
      qrOptions:            { errorCorrectionLevel: 'M' },
      dotsOptions:          { color: '#2AABEE', type: 'dots' },
      backgroundOptions:    { color: '#0f1318' },
      cornersSquareOptions: { type: 'extra-rounded', color: '#2AABEE' },
      cornersDotOptions:    { color: '#2AABEE', type: 'dot' },
    }).getRawData('svg').then(blob => {
      if (!blob) return
      const reader = new FileReader()
      reader.onload = () => setSrc(reader.result)
      reader.readAsDataURL(blob)
    }).catch(() => {})
    return () => {}
  }, [value])

  return (
    <div className="qr-wrap" title="Scan in Telegram">
      {src && <img src={src} width="120" height="120" style={{ display: 'block' }} alt="" />}
      <span className="qr-logo">
        <svg viewBox="0 0 240 240" xmlns="http://www.w3.org/2000/svg">
          <circle cx="120" cy="120" r="120" fill="#2AABEE"/>
          <path fill="white" d="M97.9 167.3c-4 0-3.3-1.5-4.7-5.3L82 128.5 168.4 78"/>
          <path fill="#C8DAEA" d="M97.9 167.3c3.1 0 4.4-1.4 6.1-3l16.3-15.9-20.4-12.3"/>
          <path fill="white" d="M99.9 136.1l49.4 36.5c5.6 3.1 9.7 1.5 11.1-5.2l20.1-94.8c2-8.2-3.1-12-8.5-9.5L52.2 107c-8 3.2-8 7.7-1.5 9.7l30.3 9.5 70.2-44.3c3.3-2 6.3-.9 3.8 1.3"/>
        </svg>
      </span>
    </div>
  )
}

// ─── UserDetail ───────────────────────────────────────────────────────────────
function UserDetail({ user, serverIp, domain, onToggle, onDelete, onBack, copiedKey, onCopy, toggling, onUpdate }) {
  const [revealed,     setRevealed]     = useState(false)
  const [editingConn,  setEditingConn]  = useState(false)
  const [connInput,    setConnInput]    = useState(user.maxConn)
  const [connBusy,     setConnBusy]     = useState(false)
  const [editingName, setEditingName] = useState(false)
  const [nameInput,   setNameInput]   = useState(user.name)
  const [nameBusy,    setNameBusy]    = useState(false)
  const link     = buildTgLink(user.secret, serverIp)
  const pct      = user.maxConn > 0 ? Math.round((user.conn / user.maxConn) * 100) : 0
  const barColor = pct > 80 ? 'var(--red)' : pct > 55 ? 'var(--yellow)' : 'var(--accent)'

  async function saveMaxConn() {
    const n = Math.max(1, Math.min(100, connInput || 1))
    setConnBusy(true)
    try {
      await onUpdate(user.id, { maxConn: n })
      setEditingConn(false)
    } finally {
      setConnBusy(false)
    }
  }

  async function saveName() {
    const trimmed = nameInput.trim()
    if (!trimmed || !/^[a-z0-9_-]+$/i.test(trimmed)) return
    setNameBusy(true)
    try {
      await onUpdate(user.id, { name: trimmed })
      setEditingName(false)
    } finally {
      setNameBusy(false)
    }
  }

  return (
    <div className="user-detail">
      {/* header */}
      <div className="detail-header">
        <button className="detail-back-btn" onClick={onBack} title="Back to users">
          <IconArrowLeft />
        </button>
        <div className="detail-avatar" style={{ background: avatarColor(user.name) }}>
          {initials(user.name)}
        </div>
        <div className="detail-title">
          {editingName
            ? <div className="label-edit-row">
                <input className="label-edit-input" value={nameInput} autoFocus
                       onChange={e => setNameInput(e.target.value)}
                       onKeyDown={e => { if (e.key === 'Enter') saveName(); if (e.key === 'Escape') setEditingName(false) }} />
                <button className="btn btn-sm btn-primary" disabled={nameBusy} onClick={saveName}>
                  {nameBusy ? <span className="btn-spinner" /> : 'Save'}
                </button>
                <button className="btn btn-sm btn-ghost" disabled={nameBusy} onClick={() => setEditingName(false)}>✕</button>
              </div>
            : <h2 className="detail-name">
                {user.name}
                <button className="icon-btn" style={{ width: 22, height: 22, marginLeft: 6 }} title="Rename"
                  onClick={() => { setNameInput(user.name); setEditingName(true) }}>
                  <IconEdit />
                </button>
              </h2>
          }
          <span className="detail-created">Created {user.created}</span>
        </div>
        <div className="detail-header-actions">
          <button
            className={`btn btn-sm ${user.active ? 'btn-warning-ghost' : 'btn-success'}`}
            onClick={onToggle}
            disabled={toggling}
          >
            <IconPower />
            {toggling ? '…' : user.active ? 'Disable' : 'Enable'}
          </button>
          <button className="btn btn-sm btn-danger-ghost" onClick={onDelete}>
            <IconTrash />
            Delete
          </button>
        </div>
      </div>

      {/* link + secret + QR */}
      <div className="detail-section">
        <div className="secret-section-header">
          <span className="detail-label" style={{ margin: 0 }}>Connection</span>
          <button className="reveal-btn" onClick={() => setRevealed(v => !v)}>
            {revealed ? <><IconEyeOff /> Hide</> : <><IconEye /> Reveal</>}
          </button>
        </div>
        <div className="detail-secret-row">
          <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 12 }}>
            <CopyField
              label="Telegram link"
              value={link}
              display={<span className="link-display"><IconLink /><span className={revealed ? '' : 'blurred'}>{link}</span></span>}
              copiedKey={copiedKey === 'Telegram link'}
              onCopy={onCopy}
            />
            <CopyField
              label="Secret"
              value={user.secret}
              display={<span className={revealed ? '' : 'blurred'}>{user.secret}</span>}
              copiedKey={copiedKey === 'Secret'}
              onCopy={onCopy}
              mono
            />
          </div>
          <div className="qr-block">
            <div className={revealed ? '' : 'blurred'} style={{ lineHeight: 0 }}>
              <QRImage value={link} />
            </div>
            <span className="qr-caption">Connect via QR</span>
          </div>
        </div>
      </div>

      {/* details grid */}
      <div className="detail-section">
        <div className="detail-grid">
          <DetailItem
            label="Status"
            value={user.active ? 'Active' : 'Disabled'}
            accent={user.active ? 'var(--green)' : 'var(--text-muted)'}
          />
          <DetailItem label="SNI domain" value={<span>🌐 <span className={revealed ? '' : 'blurred'}>{domain || '—'}</span></span>} />
          <DetailItem label="Last activity" value={formatLastSeen(user.lastSeen)} />
        </div>
      </div>

      {/* connection limit */}
      <div className="detail-section">
        <div className="detail-label" style={{ marginBottom: 8 }}>
          Connection limit
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span className="conn-fraction">{user.conn} of {user.maxConn} connections</span>
            {!editingConn && (
              <button className="icon-btn" style={{ width: 22, height: 22 }} title="Edit limit"
                onClick={() => { setConnInput(user.maxConn); setEditingConn(true) }}>
                <IconEdit />
              </button>
            )}
          </div>
        </div>
        {editingConn && (
          <div className="conn-edit-row">
            <input type="number" min="1" max="100" value={connInput} autoFocus
                   className="conn-edit-input"
                   onChange={e => setConnInput(Number(e.target.value))}
                   onKeyDown={e => { if (e.key === 'Enter') saveMaxConn(); if (e.key === 'Escape') setEditingConn(false) }} />
            <button className="btn btn-sm btn-primary" disabled={connBusy} onClick={saveMaxConn}>
              {connBusy ? <span className="btn-spinner" /> : 'Save'}
            </button>
            <button className="btn btn-sm btn-ghost" disabled={connBusy} onClick={() => setEditingConn(false)}>Cancel</button>
          </div>
        )}
        <div className="progress-track">
          <div className="progress-fill" style={{ width: `${pct}%`, background: barColor }} />
        </div>
        <div className="progress-labels">
          <span>{pct}% used</span>
          <span>{user.maxConn - user.conn} free</span>
        </div>
      </div>
    </div>
  )
}

// ─── EmptyState ───────────────────────────────────────────────────────────────
function EmptyState() {
  return (
    <div className="empty-state">
      <div className="empty-icon"><IconNode /></div>
      <p className="empty-title">Select a user</p>
      <p className="empty-sub">Choose a user from the list to view their connection details</p>
    </div>
  )
}

// ─── Skeleton ─────────────────────────────────────────────────────────────────
function Skeleton() {
  return (
    <div className="user-list">
      {[1, 2, 3].map(i => (
        <div key={i} className="user-row skeleton-row">
          <div className="skeleton skeleton-avatar" />
          <div className="skeleton-lines">
            <div className="skeleton skeleton-line" style={{ width: '60%' }} />
            <div className="skeleton skeleton-line" style={{ width: '80%', marginTop: 6 }} />
          </div>
        </div>
      ))}
    </div>
  )
}

// ─── App ──────────────────────────────────────────────────────────────────────
export default function App() {
  const [users,      setUsers]      = useState([])
  const [config,     setConfig]     = useState({ serverIp: '', domain: '', maxUsers: null })
  const [loading,    setLoading]    = useState(true)
  const [selected,   setSelected]   = useState(null)
  const [showAdd,    setShowAdd]    = useState(false)
  const [deleteUser, setDeleteUser] = useState(null)
  const [deleteBusy, setDeleteBusy] = useState(false)
  const [toggling,   setToggling]   = useState(false)
  const [toast,      setToast]      = useState('')
  const [copiedKey,  onCopy]        = useCopyFeedback()

  const showError    = useCallback((msg) => setToast(msg), [])
  const dismissToast = useCallback(() => setToast(''), [])

  // ── initial load ─────────────────────────────────────────────────────────
  useEffect(() => {
    Promise.all([api.getConfig(), api.getUsers()])
      .then(([cfg, list]) => {
        if (cfg)  setConfig(cfg)
        if (list) setUsers(list)
      })
      .catch(err => showError(err.message))
      .finally(() => setLoading(false))
  }, [])

  // ── auto-refresh conn stats every 5s ─────────────────────────────────────
  useEffect(() => {
    const id = setInterval(() => {
      api.getUsers()
        .then(list => { if (list) setUsers(list) })
        .catch(() => {})
    }, 5000)
    return () => clearInterval(id)
  }, [])

  const activeCount = users.filter(u => u.active).length
  const totalConn   = users.reduce((s, u) => s + u.conn, 0)
  const selectedUser = users.find(u => u.id === selected) ?? null

  // ── handlers ─────────────────────────────────────────────────────────────
  async function handleAdd(name, maxConn) {
    const created = await api.createUser(name, maxConn)
    if (!created) return
    setUsers(prev => [...prev, created])
    setSelected(created.id)
    setShowAdd(false)
  }

  async function handleToggle() {
    if (!selectedUser || toggling) return
    setToggling(true)
    try {
      const updated = await api.updateUser(selectedUser.id, { active: !selectedUser.active })
      if (updated) setUsers(prev => prev.map(u => u.id === updated.id ? updated : u))
    } catch (err) {
      showError(err.message)
    } finally {
      setToggling(false)
    }
  }

  async function handleDelete() {
    if (!deleteUser) return
    setDeleteBusy(true)
    try {
      await api.deleteUser(deleteUser.id)
      setUsers(prev => prev.filter(u => u.id !== deleteUser.id))
      if (selected === deleteUser.id) setSelected(null)
      setDeleteUser(null)
    } catch (err) {
      showError(err.message)
    } finally {
      setDeleteBusy(false)
    }
  }

  async function handleUpdate(id, data) {
    try {
      const updated = await api.updateUser(id, data)
      if (updated) setUsers(prev => prev.map(u => u.id === updated.id ? updated : u))
    } catch (err) {
      showError(err.message)
    }
  }

  async function handleLogout() {
    await api.logout()
    window.location.href = '/'
  }

  return (
    <div className="layout">
      <ErrorToast message={toast} onDismiss={dismissToast} />

      {/* ── sidebar ─────────────────────────────────────────── */}
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-icon"><IconNode /></div>
          <div>
            <div className="brand-name">Meridian Node</div>
            <div className="brand-sub">Proxy Panel</div>
          </div>
          <button className="icon-btn logout-btn" onClick={handleLogout} title="Sign out">
            <IconLogout />
          </button>
        </div>

        <div className="stats-row">
          <StatCard icon={<IconUsers />} label="Active users"  value={loading ? '—' : activeCount} />
          <StatCard icon={<IconLink />}  label="Connections"   value={loading ? '—' : totalConn} />
        </div>

        <div className="user-list-header">
          <span className="user-list-title">
            Users <span className="user-count">{users.length}{config.maxUsers != null ? ` / ${config.maxUsers}` : ''}</span>
          </span>
          <button
            className="btn btn-primary btn-sm"
            onClick={() => setShowAdd(true)}
            disabled={loading || (config.maxUsers != null && users.length >= config.maxUsers)}
          >
            <IconPlus /> Add
          </button>
        </div>

        {loading
          ? <Skeleton />
          : <div className="user-list">
              {users.map(u => (
                <UserRow
                  key={u.id}
                  user={u}
                  selected={selected === u.id}
                  onClick={() => setSelected(u.id)}
                />
              ))}
            </div>
        }
      </aside>

      {/* ── main ─────────────────────────────────────────────── */}
      <main className="main">
        {selectedUser
          ? <UserDetail
              key={selectedUser.id}
              user={selectedUser}
              serverIp={config.serverIp}
              domain={config.domain}
              onToggle={handleToggle}
              onDelete={() => setDeleteUser(selectedUser)}
              onBack={() => setSelected(null)}
              copiedKey={copiedKey}
              onCopy={onCopy}
              toggling={toggling}
              onUpdate={handleUpdate}
            />
          : <EmptyState />
        }
      </main>

      {/* ── modals ───────────────────────────────────────────── */}
      {showAdd    && <AddUserModal onAdd={handleAdd} onClose={() => setShowAdd(false)} />}
      {deleteUser && <DeleteModal user={deleteUser} onConfirm={handleDelete} onClose={() => setDeleteUser(null)} busy={deleteBusy} />}
    </div>
  )
}
