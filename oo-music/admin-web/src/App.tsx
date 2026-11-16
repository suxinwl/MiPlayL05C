import {
  type FormEvent,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react'
import {
  APIError,
  type AccountType,
  type AdminUser,
  type BoundAccount,
  type CurrentSession,
  type QRStart,
  type QRStatus,
  cancelQRSession,
  clearToken,
  createAccount,
  createAdmin,
  deleteAccount,
  deleteAdmin,
  getCurrentSession,
  getPublicAPIAuthRequired,
  getToken,
  listAccounts,
  listAdmins,
  loadQRImage,
  login,
  logout,
  pollQRSession,
  refreshAccount,
  setToken,
  startQRSession,
  updateAccountCredential,
  updatePublicAPIAuthRequired,
} from './api'

type AuthState = 'checking' | 'anonymous' | 'authenticated'
type Page = 'accounts' | 'admins' | 'settings'

const pageMeta: Record<Page, { eyebrow: string; title: string }> = {
  accounts: { eyebrow: 'ACCOUNT POOL', title: '绑定账户' },
  admins: { eyebrow: 'ACCESS CONTROL', title: '系统用户' },
  settings: { eyebrow: 'API SECURITY', title: '接口安全' },
}

const terminalStatuses = new Set<QRStatus>([
  'completed',
  'expired',
  'rejected',
  'canceled',
  'error',
])

function messageOf(error: unknown): string {
  if (error instanceof APIError) {
    return error.message
  }
  if (error instanceof Error) {
    return error.message
  }
  return '请求失败，请稍后重试'
}

function formatDate(value?: string): string {
  if (!value) {
    return '—'
  }
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    return '—'
  }
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
}

function statusLabel(status: QRStatus): string {
  switch (status) {
    case 'waiting':
      return '等待扫码'
    case 'scanned':
      return '已扫码'
    case 'completed':
      return '绑定成功'
    case 'expired':
      return '二维码已过期'
    case 'rejected':
      return '已拒绝登录'
    case 'canceled':
      return '已取消'
    case 'error':
      return '换票失败'
  }
}

function accountTypeLabel(accountType: AccountType): string {
  return accountType === 'netease' ? '网易云音乐' : 'QQ 音乐'
}

function accountDisplay(account: BoundAccount): string {
  return account.uinMasked || `#${account.id}`
}

function App() {
  const [authState, setAuthState] = useState<AuthState>('checking')
  const [session, setSession] = useState<CurrentSession | null>(null)

  useEffect(() => {
    let active = true
    async function restoreSession() {
      if (!getToken()) {
        if (active) {
          setAuthState('anonymous')
        }
        return
      }
      try {
        const current = await getCurrentSession()
        if (active) {
          setSession(current)
          setAuthState('authenticated')
        }
      } catch {
        if (active) {
          clearToken()
          setSession(null)
          setAuthState('anonymous')
        }
      }
    }
    void restoreSession()
    return () => {
      active = false
    }
  }, [])

  useEffect(() => {
    function handleExpired() {
      setSession(null)
      setAuthState('anonymous')
    }
    window.addEventListener('oo-music-admin-auth-expired', handleExpired)
    return () => window.removeEventListener('oo-music-admin-auth-expired', handleExpired)
  }, [])

  async function handleLogin(username: string, password: string) {
    const result = await login(username, password)
    setToken(result.token)
    setSession({ user: result.user, expiresAt: result.expiresAt })
    setAuthState('authenticated')
  }

  async function handleLogout() {
    try {
      await logout()
    } catch {
      // Local logout must still work if the server session has already expired.
    } finally {
      clearToken()
      setSession(null)
      setAuthState('anonymous')
    }
  }

  if (authState === 'checking') {
    return (
      <div className="boot-screen">
        <div className="boot-mark" aria-hidden="true">♪</div>
        <div className="spinner" />
        <p>正在检查管理会话…</p>
      </div>
    )
  }

  if (authState === 'anonymous' || !session) {
    return <LoginPage onLogin={handleLogin} />
  }

  return <Dashboard session={session} onLogout={handleLogout} />
}

function LoginPage({
  onLogin,
}: {
  onLogin: (username: string, password: string) => Promise<void>
}) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    setSubmitting(true)
    try {
      await onLogin(username.trim(), password)
      setPassword('')
    } catch (requestError) {
      setError(messageOf(requestError))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="login-page">
      <section className="login-visual" aria-hidden="true">
        <div className="brand-lockup brand-lockup--light">
          <span className="brand-icon">♪</span>
          <span>
            <strong>OO Music</strong>
            <small>CONTROL ROOM</small>
          </span>
        </div>
        <div className="login-orbit login-orbit--one" />
        <div className="login-orbit login-orbit--two" />
        <div className="login-note">音乐库<br />管理中枢</div>
        <p>账号状态、会员权益与官方登录态，在同一个安全面板内维护。</p>
      </section>

      <section className="login-panel">
        <div className="login-form-wrap">
          <div className="mobile-brand">
            <span className="brand-icon">♪</span>
            <strong>OO Music</strong>
          </div>
          <p className="eyebrow">ADMIN ACCESS</p>
          <h1>登录管理后台</h1>
          <p className="muted login-intro">使用服务端配置并保存于管理员表中的账号登录。</p>

          <form className="stack-form" onSubmit={submit}>
            <label className="field">
              <span>管理员用户名</span>
              <input
                autoComplete="username"
                autoFocus
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                placeholder="请输入用户名"
                required
              />
            </label>
            <label className="field">
              <span>管理员密码</span>
              <input
                type="password"
                autoComplete="current-password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="请输入密码"
                required
              />
            </label>
            {error ? <div className="alert alert--error" role="alert">{error}</div> : null}
            <button className="button button--primary button--large" disabled={submitting}>
              {submitting ? '正在登录…' : '进入控制台'}
            </button>
          </form>

          <p className="security-note">
            <span aria-hidden="true">◇</span>
            登录令牌只保存在当前浏览器标签页中，关闭标签页后需重新登录。
          </p>
        </div>
      </section>
    </main>
  )
}

function Dashboard({
  session,
  onLogout,
}: {
  session: CurrentSession
  onLogout: () => Promise<void>
}) {
  const [page, setPage] = useState<Page>('accounts')

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand-lockup">
          <span className="brand-icon">♪</span>
          <span>
            <strong>OO Music</strong>
            <small>ADMIN CONSOLE</small>
          </span>
        </div>

        <nav className="side-nav" aria-label="后台功能">
          <button
            className={page === 'accounts' ? 'nav-item is-active' : 'nav-item'}
            onClick={() => setPage('accounts')}
          >
            <span className="nav-icon" aria-hidden="true">◎</span>
            <span>绑定账户</span>
          </button>
          <button
            className={page === 'admins' ? 'nav-item is-active' : 'nav-item'}
            onClick={() => setPage('admins')}
          >
            <span className="nav-icon" aria-hidden="true">◇</span>
            <span>系统用户</span>
          </button>
          <button
            className={page === 'settings' ? 'nav-item is-active' : 'nav-item'}
            onClick={() => setPage('settings')}
          >
            <span className="nav-icon" aria-hidden="true">⌁</span>
            <span>接口安全</span>
          </button>
        </nav>

        <div className="sidebar-footer">
          <div className="admin-chip">
            <span className="avatar">{session.user.username.slice(0, 1).toUpperCase()}</span>
            <span className="admin-chip-text">
              <strong>{session.user.username}</strong>
              <small>会话至 {formatDate(session.expiresAt)}</small>
            </span>
          </div>
          <button className="text-button text-button--sidebar" onClick={() => void onLogout()}>
            退出登录
          </button>
        </div>
      </aside>

      <div className="workspace">
        <header className="topbar">
          <div>
            <p className="eyebrow">{pageMeta[page].eyebrow}</p>
            <h1>{pageMeta[page].title}</h1>
          </div>
          <div className="topbar-status">
            <span className="status-dot" />
            管理接口已鉴权
          </div>
        </header>

        <main className="content">
          {page === 'accounts' ? (
            <AccountsPage />
          ) : page === 'admins' ? (
            <AdminsPage currentUser={session.user} />
          ) : (
            <SettingsPage />
          )}
        </main>
      </div>
    </div>
  )
}

function SettingsPage() {
  const [required, setRequired] = useState(false)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  useEffect(() => {
    let active = true
    async function load() {
      setError('')
      try {
        const setting = await getPublicAPIAuthRequired()
        if (active) {
          setRequired(setting.required)
        }
      } catch (requestError) {
        if (active) {
          setError(messageOf(requestError))
        }
      } finally {
        if (active) {
          setLoading(false)
        }
      }
    }
    void load()
    return () => {
      active = false
    }
  }, [])

  async function toggle() {
    if (loading || saving) {
      return
    }
    setSaving(true)
    setError('')
    setNotice('')
    try {
      const result = await updatePublicAPIAuthRequired(!required)
      setRequired(result.required)
      setNotice(result.required ? '公开业务接口鉴权已开启' : '公开业务接口鉴权已关闭')
    } catch (requestError) {
      setError(messageOf(requestError))
    } finally {
      setSaving(false)
    }
  }

  return (
    <section className="panel settings-panel">
      <div className="panel-heading panel-heading--compact">
        <div>
          <p className="eyebrow">RUNTIME POLICY</p>
          <h2>公开业务接口鉴权</h2>
          <p>控制搜索、播放、歌词、MV 等原公开接口是否要求客户端 UIN 与 accessKey。</p>
        </div>
        <span className={`badge ${required ? 'badge--green' : ''}`}>
          {loading ? '读取中…' : required ? '已开启' : '已关闭'}
        </span>
      </div>

      {error ? <div className="alert alert--error">{error}</div> : null}
      {notice ? <div className="alert alert--success">{notice}</div> : null}

      <div className="settings-grid">
        <article className="settings-card settings-card--primary">
          <div className="settings-card-copy">
            <span className="settings-kicker">PUBLIC API AUTH</span>
            <h3>{required ? '匿名访问已禁用' : '允许匿名访问'}</h3>
            <p>
              {required
                ? '请求搜索、歌曲详情、播放地址、歌词和 MV 时，必须携带有效授权。'
                : '未登录客户端仍可访问搜索、播放等基础能力；携带了错误凭据也不会因此被拒绝。'}
            </p>
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={required}
            aria-label="切换公开业务接口鉴权"
            className={`setting-switch ${required ? 'is-on' : ''}`}
            disabled={loading || saving}
            onClick={() => void toggle()}
          >
            <span className="setting-switch-track"><span className="setting-switch-thumb" /></span>
            <span>{saving ? '保存中…' : required ? '关闭鉴权' : '开启鉴权'}</span>
          </button>
        </article>

        <article className="settings-card">
          <span className="settings-kicker">ALWAYS PROTECTED</span>
          <h3>固定鉴权接口</h3>
          <p>账号资料与远程歌单始终校验平台、账号 ID 和 accessKey，不受上方开关影响。</p>
          <div className="settings-tags">
            <code>GET /api/client/account</code>
            <code>GET /api/client/playlists</code>
          </div>
        </article>

        <article className="settings-card">
          <span className="settings-kicker">ALWAYS PUBLIC</span>
          <h3>登录与探测入口</h3>
          <p>扫码登录会话、二维码、存活探针和后台静态页面始终公开，避免登录链路被锁死。</p>
          <div className="settings-tags">
            <code>/api/client/login/sessions/*</code>
            <code>/healthz</code>
          </div>
        </article>
      </div>
    </section>
  )
}

function AdminsPage({ currentUser }: { currentUser: AdminUser }) {
  const [admins, setAdmins] = useState<AdminUser[]>([])
  const [loading, setLoading] = useState(true)
  const [pageError, setPageError] = useState('')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState('')
  const [notice, setNotice] = useState('')
  const [busyID, setBusyID] = useState<number | null>(null)

  const load = useCallback(async () => {
    setPageError('')
    try {
      setAdmins(await listAdmins())
    } catch (error) {
      setPageError(messageOf(error))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  async function add(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setFormError('')
    setNotice('')
    if (password !== confirmPassword) {
      setFormError('两次输入的密码不一致')
      return
    }
    setSubmitting(true)
    try {
      await createAdmin(username.trim(), password)
      setUsername('')
      setPassword('')
      setConfirmPassword('')
      setNotice('管理员已创建')
      await load()
    } catch (error) {
      setFormError(messageOf(error))
    } finally {
      setSubmitting(false)
    }
  }

  async function remove(admin: AdminUser) {
    if (admin.id === currentUser.id) {
      return
    }
    if (!window.confirm(`确定删除管理员“${admin.username}”吗？该账号的登录会话会立即失效。`)) {
      return
    }
    setBusyID(admin.id)
    setPageError('')
    setNotice('')
    try {
      await deleteAdmin(admin.id)
      setAdmins((items) => items.filter((item) => item.id !== admin.id))
      setNotice(`管理员“${admin.username}”已删除`)
    } catch (error) {
      setPageError(messageOf(error))
    } finally {
      setBusyID(null)
    }
  }

  return (
    <div className="page-grid page-grid--admin">
      <section className="panel panel--wide">
        <div className="panel-heading">
          <div>
            <h2>后台管理员</h2>
            <p>至少保留一个管理员；当前登录账号不能删除自己。</p>
          </div>
          <span className="count-pill">{admins.length} 个账号</span>
        </div>

        {pageError ? <div className="alert alert--error">{pageError}</div> : null}
        {notice ? <div className="alert alert--success">{notice}</div> : null}

        {loading ? (
          <div className="table-loading"><span className="spinner spinner--dark" />正在加载…</div>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>管理员</th>
                  <th>角色</th>
                  <th>创建时间</th>
                  <th className="align-right">操作</th>
                </tr>
              </thead>
              <tbody>
                {admins.map((admin) => {
                  const isCurrent = admin.id === currentUser.id
                  return (
                    <tr key={admin.id}>
                      <td>
                        <div className="identity-cell">
                          <span className="avatar avatar--small">{admin.username.slice(0, 1).toUpperCase()}</span>
                          <span>
                            <strong>{admin.username}</strong>
                            <small>ID {admin.id}</small>
                          </span>
                        </div>
                      </td>
                      <td>
                        {isCurrent ? <span className="badge badge--green">当前会话</span> : <span className="badge">管理员</span>}
                      </td>
                      <td>{formatDate(admin.createdAt)}</td>
                      <td className="align-right">
                        <button
                          className="button button--ghost button--danger-text button--small"
                          disabled={isCurrent || busyID === admin.id}
                          onClick={() => void remove(admin)}
                          title={isCurrent ? '不能删除当前登录账号' : '删除管理员'}
                        >
                          {busyID === admin.id ? '删除中…' : '删除'}
                        </button>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="panel">
        <div className="panel-heading panel-heading--compact">
          <div>
            <h2>添加管理员</h2>
            <p>新账号拥有同等的后台管理权限。</p>
          </div>
        </div>
        <form className="stack-form" onSubmit={add}>
          <label className="field">
            <span>用户名</span>
            <input
              autoComplete="off"
              minLength={3}
              maxLength={64}
              value={username}
              onChange={(event) => setUsername(event.target.value)}
              placeholder="3–64 个非空白字符"
              required
            />
          </label>
          <label className="field">
            <span>初始密码</span>
            <input
              type="password"
              autoComplete="new-password"
              minLength={8}
              maxLength={128}
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              placeholder="至少 8 个字符"
              required
            />
          </label>
          <label className="field">
            <span>确认密码</span>
            <input
              type="password"
              autoComplete="new-password"
              minLength={8}
              maxLength={128}
              value={confirmPassword}
              onChange={(event) => setConfirmPassword(event.target.value)}
              placeholder="再次输入密码"
              required
            />
          </label>
          {formError ? <div className="alert alert--error">{formError}</div> : null}
          <button className="button button--primary" disabled={submitting}>
            {submitting ? '正在创建…' : '创建管理员'}
          </button>
        </form>
      </section>
    </div>
  )
}

function AccountsPage() {
  const [accounts, setAccounts] = useState<BoundAccount[]>([])
  const [loading, setLoading] = useState(true)
  const [pageError, setPageError] = useState('')
  const [notice, setNotice] = useState('')
  const [busyID, setBusyID] = useState<number | null>(null)
  const [qrOpen, setQROpen] = useState(false)
  const [manualOpen, setManualOpen] = useState(false)
  const [editing, setEditing] = useState<BoundAccount | null>(null)

  const load = useCallback(async () => {
    setPageError('')
    try {
      setAccounts(await listAccounts())
    } catch (error) {
      setPageError(messageOf(error))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const replaceAccount = useCallback((account: BoundAccount) => {
    setAccounts((items) => {
      const exists = items.some((item) => item.id === account.id)
      if (!exists) {
        return [...items, account]
      }
      return items.map((item) => (item.id === account.id ? account : item))
    })
  }, [])

  const handleQRSaved = useCallback(async (account: BoundAccount) => {
    replaceAccount(account)
    setNotice(`账户 ${accountDisplay(account)} 已通过${accountTypeLabel(account.accountType)}扫码授权保存`)
    await load()
  }, [load, replaceAccount])

  async function refresh(account: BoundAccount) {
    setBusyID(account.id)
    setPageError('')
    setNotice('')
    try {
      const result = await refreshAccount(account.id)
      replaceAccount(result.account)
      setNotice(result.warning || `账户 ${accountDisplay(account)} 状态已刷新`)
    } catch (error) {
      setPageError(messageOf(error))
    } finally {
      setBusyID(null)
    }
  }

  async function remove(account: BoundAccount) {
    if (!window.confirm(`确定删除绑定账户 ${accountDisplay(account)} 吗？删除后不会再参与账号轮换。`)) {
      return
    }
    setBusyID(account.id)
    setPageError('')
    setNotice('')
    try {
      await deleteAccount(account.id)
      setAccounts((items) => items.filter((item) => item.id !== account.id))
      setNotice('绑定账户已删除')
    } catch (error) {
      setPageError(messageOf(error))
    } finally {
      setBusyID(null)
    }
  }

  function handleCredentialSaved(account: BoundAccount, warning: string) {
    replaceAccount(account)
    setEditing(null)
    setNotice(warning || `账户 ${accountDisplay(account)} 的凭据已更新`)
  }

  function handleManualSaved(account: BoundAccount, warning: string) {
    replaceAccount(account)
    setManualOpen(false)
    setNotice(warning || `账户 ${accountDisplay(account)} 已添加`)
  }

  return (
    <section className="panel">
      <div className="panel-heading panel-heading--accounts">
        <div>
          <h2>账号池</h2>
          <p>支持 QQ 音乐与网易云音乐账号；QQ 账号轮换优先选择会员等级最高、到期最晚的账号。</p>
        </div>
        <div className="header-actions">
          <button className="button button--ghost" onClick={() => setManualOpen(true)}>
            手动添加
          </button>
          <button className="button button--primary" onClick={() => setQROpen(true)}>
            <span aria-hidden="true">＋</span>
            扫码添加 / 更新
          </button>
        </div>
      </div>

      {pageError ? <div className="alert alert--error">{pageError}</div> : null}
      {notice ? <div className="alert alert--success">{notice}</div> : null}

      {loading ? (
        <div className="table-loading"><span className="spinner spinner--dark" />正在加载账号池…</div>
      ) : accounts.length === 0 ? (
        <div className="empty-state">
          <div className="empty-icon" aria-hidden="true">♫</div>
          <h3>还没有绑定账户</h3>
          <p>选择 QQ 音乐或网易云音乐扫码授权，也可以手动填写凭据。</p>
          <div className="header-actions header-actions--center">
            <button className="button button--ghost" onClick={() => setManualOpen(true)}>手动添加</button>
            <button className="button button--primary" onClick={() => setQROpen(true)}>扫码添加账户</button>
          </div>
        </div>
      ) : (
        <div className="table-wrap">
          <table className="accounts-table">
            <thead>
              <tr>
                <th>平台 / 账户</th>
                <th>会员权益</th>
                <th>会员到期</th>
                <th>授权状态</th>
                <th>最近检查</th>
                <th className="align-right">操作</th>
              </tr>
            </thead>
            <tbody>
              {accounts.map((account) => (
                <tr key={account.id}>
                  <td>
                    <div className="identity-cell">
                      <span className={`account-orb account-orb--${account.accountType} ${account.loginValid ? '' : 'is-invalid'}`} aria-hidden="true">
                        {account.accountType === 'netease' ? 'N' : 'Q'}
                      </span>
                      <span>
                        <strong>{account.uinMasked || '已脱敏账号'}</strong>
                        <small>{account.accountTypeName || accountTypeLabel(account.accountType)} · 账户 ID {account.id}</small>
                      </span>
                    </div>
                  </td>
                  <td>
                    <span className={`badge ${account.vipLevel > 0 ? 'badge--vip' : ''}`}>
                      {account.vipLevelName || '普通用户'}
                    </span>
                  </td>
                  <td>{formatDate(account.vipExpiresAt)}</td>
                  <td>
                    <span className={`badge ${account.loginValid ? 'badge--green' : 'badge--red'}`}>
                      <span className="mini-dot" />
                      {account.loginValid ? '有效' : '已失效'}
                    </span>
                    {account.accountType === 'netease' && account.loginExpiresAt ? (
                      <small className="cell-subtext">至 {formatDate(account.loginExpiresAt)}</small>
                    ) : null}
                  </td>
                  <td>{formatDate(account.loginCheckedAt || account.vipCheckedAt)}</td>
                  <td>
                    <div className="row-actions">
                      <button
                        className="button button--ghost button--small"
                        disabled={busyID === account.id}
                        onClick={() => void refresh(account)}
                      >
                        {busyID === account.id ? '检查中…' : account.accountType === 'netease' ? '检测 / 续期' : '刷新'}
                      </button>
                      <button className="button button--ghost button--small" onClick={() => setEditing(account)}>
                        {account.accountType === 'netease' ? '修改 Cookie' : '修改密钥'}
                      </button>
                      <button
                        className="button button--ghost button--small button--danger-text"
                        disabled={busyID === account.id}
                        onClick={() => void remove(account)}
                      >
                        删除
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {qrOpen ? (
        <QRDialog
          onClose={() => setQROpen(false)}
          onSaved={handleQRSaved}
        />
      ) : null}
      {manualOpen ? (
        <ManualAccountDialog
          onClose={() => setManualOpen(false)}
          onSaved={handleManualSaved}
        />
      ) : null}
      {editing ? (
        <ManualKeyDialog
          account={editing}
          onClose={() => setEditing(null)}
          onSaved={handleCredentialSaved}
        />
      ) : null}
    </section>
  )
}

function QRDialog({
  onClose,
  onSaved,
}: {
  onClose: () => void
  onSaved: (account: BoundAccount) => Promise<void>
}) {
  const [accountType, setAccountType] = useState<AccountType>('qq')
  const [session, setSession] = useState<QRStart | null>(null)
  const [status, setStatus] = useState<QRStatus>('waiting')
  const [message, setMessage] = useState('正在获取二维码…')
  const [imageURL, setImageURL] = useState('')
  const [error, setError] = useState('')
  const [starting, setStarting] = useState(true)
  const [savedAccount, setSavedAccount] = useState<BoundAccount | null>(null)
  const sessionRef = useRef('')
  const imageURLRef = useRef('')
  const mountedRef = useRef(true)
  const requestSeqRef = useRef(0)

  const begin = useCallback(async (nextType: AccountType) => {
    const requestSeq = ++requestSeqRef.current
    if (sessionRef.current) {
      void cancelQRSession(sessionRef.current).catch(() => undefined)
      sessionRef.current = ''
    }
    setStarting(true)
    setError('')
    setSavedAccount(null)
    setSession(null)
    setStatus('waiting')
    setMessage('正在获取二维码…')
    if (imageURLRef.current) {
      URL.revokeObjectURL(imageURLRef.current)
      imageURLRef.current = ''
      setImageURL('')
    }
    try {
      const created = await startQRSession(nextType)
      if (!mountedRef.current || requestSeq !== requestSeqRef.current) {
        void cancelQRSession(created.sessionId).catch(() => undefined)
        return
      }
      sessionRef.current = created.sessionId
      setSession(created)
      setStatus(created.status)
      setMessage(created.message)
      const image = await loadQRImage(created.imageUrl)
      if (!mountedRef.current || requestSeq !== requestSeqRef.current) {
        return
      }
      const nextURL = URL.createObjectURL(image)
      imageURLRef.current = nextURL
      setImageURL(nextURL)
    } catch (requestError) {
      if (mountedRef.current) {
        setError(messageOf(requestError))
        setMessage('二维码获取失败')
      }
    } finally {
      if (mountedRef.current && requestSeq === requestSeqRef.current) {
        setStarting(false)
      }
    }
  }, [])

  useEffect(() => {
    mountedRef.current = true
    void begin('qq')
    return () => {
      mountedRef.current = false
      requestSeqRef.current++
      if (imageURLRef.current) {
        URL.revokeObjectURL(imageURLRef.current)
        imageURLRef.current = ''
      }
      if (sessionRef.current) {
        void cancelQRSession(sessionRef.current).catch(() => undefined)
      }
    }
  }, [begin])

  function switchAccountType(nextType: AccountType) {
    if (nextType === accountType) {
      return
    }
    setAccountType(nextType)
    void begin(nextType)
  }

  useEffect(() => {
    if (!session || terminalStatuses.has(status)) {
      return
    }
    let active = true
    let timer: number | undefined

    async function poll() {
      try {
        const result = await pollQRSession(session!.sessionId)
        if (!active) {
          return
        }
        setStatus(result.status)
        setMessage(result.message)
        if (result.status === 'completed' && result.account) {
          setSavedAccount(result.account)
          void onSaved(result.account)
          return
        }
        if (!terminalStatuses.has(result.status)) {
          timer = window.setTimeout(() => void poll(), 1800)
        }
      } catch (requestError) {
        if (active) {
          setError(messageOf(requestError))
          setMessage('轮询扫码状态失败')
        }
      }
    }

    timer = window.setTimeout(() => void poll(), 1200)
    return () => {
      active = false
      if (timer !== undefined) {
        window.clearTimeout(timer)
      }
    }
  }, [onSaved, session, status])

  const terminal = terminalStatuses.has(status)

  return (
    <div className="modal-layer" role="presentation">
      <section className="modal qr-modal" role="dialog" aria-modal="true" aria-labelledby="qr-title">
        <button className="modal-close" onClick={onClose} aria-label="关闭">×</button>
        <div className="modal-heading">
          <p className="eyebrow">OFFICIAL ACCOUNT LOGIN</p>
          <h2 id="qr-title">扫码授权 {accountTypeLabel(accountType)}</h2>
          <p>选择平台后使用对应 App 扫码确认。登录凭据只会保存在服务端数据库中。</p>
        </div>

        <div className="account-type-switch" role="tablist" aria-label="选择账号平台">
          <button
            type="button"
            role="tab"
            aria-selected={accountType === 'qq'}
            className={accountType === 'qq' ? 'is-active' : ''}
            onClick={() => switchAccountType('qq')}
          >
            QQ 音乐
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={accountType === 'netease'}
            className={accountType === 'netease' ? 'is-active' : ''}
            onClick={() => switchAccountType('netease')}
          >
            网易云音乐
          </button>
        </div>

        <div className="qr-stage">
          <div className={`qr-frame ${terminal && status !== 'completed' ? 'is-muted' : ''}`}>
            {imageURL ? <img src={imageURL} alt={`${accountTypeLabel(accountType)}登录二维码`} /> : <div className="qr-placeholder"><span className="spinner spinner--dark" />二维码生成中…</div>}
            {terminal && status !== 'completed' ? (
              <div className="qr-overlay">
                <strong>{statusLabel(status)}</strong>
                <button className="button button--primary button--small" onClick={() => void begin(accountType)}>重新获取</button>
              </div>
            ) : null}
          </div>
          <div className="qr-status-copy">
            <span className={`badge ${status === 'completed' ? 'badge--green' : status === 'scanned' ? 'badge--vip' : status === 'error' || status === 'rejected' ? 'badge--red' : ''}`}>
              <span className="mini-dot" />
              {statusLabel(status)}
            </span>
            <h3>{message}</h3>
            {savedAccount ? (
              <p>已保存 {savedAccount.accountTypeName} 账户 <strong>{accountDisplay(savedAccount)}</strong>，可以直接关闭窗口。</p>
            ) : (
              <p>二维码约 5 分钟有效。扫码成功后会自动换取并验证登录态。</p>
            )}
            {error ? <div className="alert alert--error">{error}</div> : null}
          </div>
        </div>

        <div className="modal-footer">
          <span className="security-note security-note--compact">
            <span aria-hidden="true">◇</span>
            {accountType === 'qq' ? 'qrsig、Cookie 和 qm_keyst' : '网易云 Cookie 与 MUSIC_U'} 不会返回到浏览器。
          </span>
          <div className="modal-actions">
            {terminal || error ? (
              <button className="button button--ghost" disabled={starting} onClick={() => void begin(accountType)}>
                {starting ? '获取中…' : '刷新二维码'}
              </button>
            ) : null}
            <button className="button button--primary" onClick={onClose}>
              {status === 'completed' ? '完成' : '取消'}
            </button>
          </div>
        </div>
      </section>
    </div>
  )
}

function ManualKeyDialog({
  account,
  onClose,
  onSaved,
}: {
  account: BoundAccount
  onClose: () => void
  onSaved: (account: BoundAccount, warning: string) => void
}) {
  const credentialLabel = account.accountType === 'netease' ? 'Cookie' : 'qm_keyst'
  const [credential, setCredential] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    if (!credential.trim()) {
      setError(`请输入新的 ${credentialLabel}`)
      return
    }
    if (credential !== confirm) {
      setError(`两次输入的 ${credentialLabel} 不一致`)
      return
    }
    setSaving(true)
    try {
      const result = await updateAccountCredential(account.id, credential.trim())
      setCredential('')
      setConfirm('')
      onSaved(result.account, result.warning ?? '')
    } catch (requestError) {
      setError(messageOf(requestError))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="modal-layer" role="presentation">
      <section className="modal modal--compact" role="dialog" aria-modal="true" aria-labelledby="key-title">
        <button className="modal-close" onClick={onClose} aria-label="关闭">×</button>
        <div className="modal-heading">
          <p className="eyebrow">MANUAL CREDENTIAL</p>
          <h2 id="key-title">手动修改 {credentialLabel}</h2>
          <p>{account.accountTypeName} 账户 <strong>{accountDisplay(account)}</strong>。新凭据保存后会立即尝试验证登录态。</p>
        </div>
        <form className="stack-form" onSubmit={submit}>
          <label className="field">
            <span>新的 {credentialLabel}</span>
            <input
              type="password"
              autoComplete="new-password"
              value={credential}
              onChange={(event) => setCredential(event.target.value)}
              placeholder={`粘贴新的 ${credentialLabel}`}
              required
            />
          </label>
          <label className="field">
            <span>确认 {credentialLabel}</span>
            <input
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(event) => setConfirm(event.target.value)}
              placeholder={`再次输入 ${credentialLabel}`}
              required
            />
          </label>
          {error ? <div className="alert alert--error">{error}</div> : null}
          <div className="modal-actions modal-actions--end">
            <button type="button" className="button button--ghost" onClick={onClose}>取消</button>
            <button className="button button--primary" disabled={saving}>{saving ? '正在保存…' : '保存并验证'}</button>
          </div>
        </form>
      </section>
    </div>
  )
}

function ManualAccountDialog({
  onClose,
  onSaved,
}: {
  onClose: () => void
  onSaved: (account: BoundAccount, warning: string) => void
}) {
  const [accountType, setAccountType] = useState<AccountType>('qq')
  const [uid, setUID] = useState('')
  const [credential, setCredential] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  const credentialLabel = accountType === 'netease' ? 'Cookie' : 'qm_keyst'

  function switchType(nextType: AccountType) {
    setAccountType(nextType)
    setUID('')
    setCredential('')
    setConfirm('')
    setError('')
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    if (accountType === 'qq' && !uid.trim()) {
      setError('请输入 QQ 号')
      return
    }
    if (!credential.trim()) {
      setError(`请输入 ${credentialLabel}`)
      return
    }
    if (credential !== confirm) {
      setError(`两次输入的 ${credentialLabel} 不一致`)
      return
    }
    setSaving(true)
    try {
      const result = await createAccount(accountType, uid.trim(), credential.trim())
      onSaved(result.account, result.warning ?? '')
    } catch (requestError) {
      setError(messageOf(requestError))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="modal-layer" role="presentation">
      <section className="modal modal--compact" role="dialog" aria-modal="true" aria-labelledby="manual-account-title">
        <button className="modal-close" onClick={onClose} aria-label="关闭">×</button>
        <div className="modal-heading">
          <p className="eyebrow">MANUAL ACCOUNT</p>
          <h2 id="manual-account-title">手动添加账户</h2>
          <p>选择平台并填写已有登录凭据。网易云音乐 Cookie 需要包含 MUSIC_U。</p>
        </div>

        <div className="account-type-switch" role="tablist" aria-label="选择账号平台">
          <button type="button" className={accountType === 'qq' ? 'is-active' : ''} onClick={() => switchType('qq')}>
            QQ 音乐
          </button>
          <button type="button" className={accountType === 'netease' ? 'is-active' : ''} onClick={() => switchType('netease')}>
            网易云音乐
          </button>
        </div>

        <form className="stack-form" onSubmit={submit}>
          <label className="field">
            <span>{accountType === 'netease' ? '网易云音乐账号 ID' : 'QQ 号'}</span>
            <input
              inputMode="numeric"
              value={uid}
              onChange={(event) => setUID(event.target.value)}
              placeholder={accountType === 'netease' ? '可留空，由 Cookie 自动识别' : '请输入 QQ 号'}
              required={accountType === 'qq'}
            />
          </label>
          <label className="field">
            <span>{credentialLabel}</span>
            <input
              type="password"
              autoComplete="new-password"
              value={credential}
              onChange={(event) => setCredential(event.target.value)}
              placeholder={accountType === 'netease' ? '粘贴完整 Cookie 或 MUSIC_U=...' : '粘贴 qm_keyst'}
              required
            />
          </label>
          <label className="field">
            <span>确认 {credentialLabel}</span>
            <input
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(event) => setConfirm(event.target.value)}
              placeholder={`再次输入 ${credentialLabel}`}
              required
            />
          </label>
          {error ? <div className="alert alert--error">{error}</div> : null}
          <div className="modal-actions modal-actions--end">
            <button type="button" className="button button--ghost" onClick={onClose}>取消</button>
            <button className="button button--primary" disabled={saving}>{saving ? '正在验证…' : '保存并验证'}</button>
          </div>
        </form>
      </section>
    </div>
  )
}

export default App
