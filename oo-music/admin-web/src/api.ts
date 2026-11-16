const TOKEN_KEY = 'oo-music-admin-token'
const API_BASE = (import.meta.env.VITE_API_BASE || '/api/admin').replace(/\/$/, '')

export interface AdminUser {
  id: number
  username: string
  createdAt: string
  updatedAt: string
}

export interface LoginResult {
  token: string
  expiresAt: string
  user: AdminUser
}

export interface CurrentSession {
  user: AdminUser
  expiresAt: string
}

export type AccountType = 'qq' | 'netease'

export interface BoundAccount {
  id: number
  accountType: AccountType
  accountTypeName: string
  available: boolean
  loggedIn: boolean
  uinMasked?: string
  vipLevel: number
  vipLevelName: string
  vipExpiresAt?: string
  vipCheckedAt?: string
  loginValid: boolean
  loginCheckedAt?: string
  loginExpiresAt?: string
}

export type QRStatus =
  | 'waiting'
  | 'scanned'
  | 'completed'
  | 'expired'
  | 'rejected'
  | 'canceled'
  | 'error'

export interface QRStart {
  sessionId: string
  status: QRStatus
  message: string
  expiresAt: string
  imageUrl: string
}

export interface QRPoll {
  sessionId: string
  status: QRStatus
  message: string
  expiresAt: string
  account?: BoundAccount
}

export interface PublicAPIAuthSetting {
  required: boolean
}

interface APIErrorPayload {
  error?: {
    code?: string
    message?: string
  }
}

export class APIError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'APIError'
    this.status = status
    this.code = code
  }
}

export function getToken(): string {
  return sessionStorage.getItem(TOKEN_KEY) ?? ''
}

export function setToken(token: string): void {
  sessionStorage.setItem(TOKEN_KEY, token)
}

export function clearToken(): void {
  sessionStorage.removeItem(TOKEN_KEY)
}

function notifyExpired(): void {
  clearToken()
  window.dispatchEvent(new Event('oo-music-admin-auth-expired'))
}

async function apiFetch(path: string, init: RequestInit = {}, authenticated = true): Promise<Response> {
  const headers = new Headers(init.headers)
  if (init.body !== undefined && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }
  if (authenticated) {
    const token = getToken()
    if (!token) {
      notifyExpired()
      throw new APIError(401, 'unauthorized', '请先登录管理后台')
    }
    headers.set('Authorization', `Bearer ${token}`)
  }
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers,
    cache: 'no-store',
  })
  if (response.status === 401 && authenticated) {
    notifyExpired()
  }
  return response
}

async function parseError(response: Response): Promise<APIError> {
  let payload: APIErrorPayload = {}
  try {
    payload = (await response.json()) as APIErrorPayload
  } catch {
    // Keep the status-based fallback when the server does not return JSON.
  }
  return new APIError(
    response.status,
    payload.error?.code ?? 'request_failed',
    payload.error?.message ?? `请求失败（HTTP ${response.status}）`,
  )
}

async function request<T>(path: string, init: RequestInit = {}, authenticated = true): Promise<T> {
  const response = await apiFetch(path, init, authenticated)
  if (!response.ok) {
    throw await parseError(response)
  }
  if (response.status === 204) {
    return undefined as T
  }
  return (await response.json()) as T
}

function jsonBody(value: unknown): string {
  return JSON.stringify(value)
}

export async function login(username: string, password: string): Promise<LoginResult> {
  return request<LoginResult>(
    '/login',
    { method: 'POST', body: jsonBody({ username, password }) },
    false,
  )
}

export async function logout(): Promise<void> {
  await request<void>('/logout', { method: 'POST' })
}

export async function getCurrentSession(): Promise<CurrentSession> {
  return request<CurrentSession>('/me')
}

export async function listAdmins(): Promise<AdminUser[]> {
  const result = await request<{ items: AdminUser[] }>('/users')
  return result.items ?? []
}

export async function createAdmin(username: string, password: string): Promise<AdminUser> {
  const result = await request<{ user: AdminUser }>('/users', {
    method: 'POST',
    body: jsonBody({ username, password }),
  })
  return result.user
}

export async function deleteAdmin(id: number): Promise<void> {
  await request<void>(`/users/${id}`, { method: 'DELETE' })
}

export async function getPublicAPIAuthRequired(): Promise<PublicAPIAuthSetting> {
  return request<PublicAPIAuthSetting>('/settings/public-api-auth')
}

export async function updatePublicAPIAuthRequired(required: boolean): Promise<PublicAPIAuthSetting> {
  return request<PublicAPIAuthSetting>('/settings/public-api-auth', {
    method: 'PUT',
    body: jsonBody({ required }),
  })
}

export async function listAccounts(): Promise<BoundAccount[]> {
  const result = await request<{ items: BoundAccount[] }>('/accounts')
  return result.items ?? []
}

export async function createAccount(
  accountType: AccountType,
  uid: string,
  credential: string,
): Promise<{ account: BoundAccount; warning?: string }> {
  return request<{ account: BoundAccount; warning?: string }>('/accounts', {
    method: 'POST',
    body: jsonBody({ accountType, uid, credential }),
  })
}

export async function updateAccountCredential(
  id: number,
  credential: string,
): Promise<{ account: BoundAccount; warning?: string }> {
  return request<{ account: BoundAccount; warning?: string }>(`/accounts/${id}/credential`, {
    method: 'PATCH',
    body: jsonBody({ credential }),
  })
}

export async function refreshAccount(id: number): Promise<{ account: BoundAccount; warning?: string }> {
  return request<{ account: BoundAccount; warning?: string }>(`/accounts/${id}/refresh`, {
    method: 'POST',
  })
}

export async function deleteAccount(id: number): Promise<void> {
  await request<void>(`/accounts/${id}`, { method: 'DELETE' })
}

export async function startQRSession(accountType: AccountType): Promise<QRStart> {
  return request<QRStart>(`/qr-sessions?type=${encodeURIComponent(accountType)}`, { method: 'POST' })
}

export async function pollQRSession(id: string): Promise<QRPoll> {
  return request<QRPoll>(`/qr-sessions/${encodeURIComponent(id)}`)
}

export async function cancelQRSession(id: string): Promise<void> {
  await request<void>(`/qr-sessions/${encodeURIComponent(id)}`, { method: 'DELETE' })
}

export async function loadQRImage(path: string): Promise<Blob> {
  const response = await apiFetch(path)
  if (!response.ok) {
    throw await parseError(response)
  }
  return response.blob()
}
