import { CapacitorHttp } from '@capacitor/core'
import { Media, type MediaItem } from './media'
import { albumTag, albumTitle, uploads, type Album, type DecisionRecord, type UploadRecord } from './store.svelte'

// Immich v3 API: POST /assets (native, streamed), albums, tags. Calls go through CapacitorHttp (native), so the
// server needs no CORS setup for the app.

export interface ImmichConfig {
  server: string
  key: string
  enabled: boolean
}

/** What the API key must be allowed to do (Immich → Account settings → API keys). */
export const PERMISSIONS = ['asset.upload', 'album.read', 'album.create', 'albumAsset.create', 'tag.create', 'tag.asset']

export function cleanServer(url: string): string {
  const s = url.trim().replace(/\/+$/, '').replace(/\/api$/, '')
  return s && !/^https?:\/\//.test(s) ? `https://${s}` : s
}

async function api<T>(cfg: ImmichConfig, method: string, path: string, data?: unknown): Promise<T> {
  const r = await CapacitorHttp.request({
    url: `${cleanServer(cfg.server)}/api${path}`,
    method,
    headers: { 'x-api-key': cfg.key, Accept: 'application/json', 'Content-Type': 'application/json' },
    data,
  })
  if (r.status >= 400) {
    const msg = typeof r.data === 'object' && r.data?.message ? r.data.message : JSON.stringify(r.data)
    throw new Error(`Immich ${r.status}: ${String(msg).slice(0, 200)}`)
  }
  return r.data as T
}

/** Checks the server and key; returns the key's name and any missing permissions. */
export async function testConnection(cfg: ImmichConfig): Promise<{ name: string; missing: string[] }> {
  const key = await api<{ name: string; permissions: string[] }>(cfg, 'GET', '/api-keys/me')
  const all = key.permissions.includes('all')
  return { name: key.name, missing: all ? [] : PERMISSIONS.filter((p) => !key.permissions.includes(p)) }
}

export interface SyncStatus {
  running: boolean
  /** Kept photos not yet in Immich (or not yet in their album there). */
  pending: number
  done: number
  error: string
}

export interface SyncContext {
  cfg: ImmichConfig
  items: MediaItem[]
  decided: Map<number, DecisionRecord>
  albums: Album[]
  saveAlbum: (a: Album) => Promise<unknown>
  onStatus: (s: SyncStatus) => void
}

/** Kept photos (with an album) that still need uploading or filing into their Immich album. */
export function pendingUploads(ctx: Pick<SyncContext, 'items' | 'decided'>, records: Map<number, UploadRecord>) {
  return ctx.items.filter((i) => {
    const d = ctx.decided.get(i.id)
    return d?.decision === 'keep' && d.albumId && records.get(i.id)?.syncedAlbumId !== d.albumId
  })
}

let running = false
let again = false

/**
 * Uploads kept photos, then adds them to their Immich album (created on first use, same name as in Winnow) and tag
 * (Albums/YYYY/MM/name). One run at a time; a call during a run schedules another pass.
 */
export async function syncImmich(ctx: SyncContext): Promise<void> {
  if (!ctx.cfg.enabled || !ctx.cfg.server || !ctx.cfg.key) return
  if (running) {
    again = true
    return
  }
  running = true
  let done = 0
  try {
    do {
      again = false
      const records = new Map((await uploads.all()).map((r) => [r.id, r]))
      const todo = pendingUploads(ctx, records)
      const status = (error = '') => ctx.onStatus({ running: true, pending: todo.length - done, done, error })
      status()

      // 1. Upload whatever isn't in Immich yet (Immich itself also skips exact duplicates).
      for (const item of todo) {
        if (records.has(item.id)) continue
        const when = new Date(item.taken).toISOString()
        const res = await Media.upload({
          id: item.id,
          type: item.type,
          mime: item.mime,
          name: item.name,
          server: cleanServer(ctx.cfg.server),
          key: ctx.cfg.key,
          created: when,
          modified: when,
          duration: item.type === 'video' ? item.duration : undefined,
        })
        const rec: UploadRecord = { id: item.id, assetId: res.id, uploadedAt: Date.now() }
        records.set(item.id, rec)
        await uploads.put(rec)
      }

      // 2. File them into their Immich album and tag, one album at a time.
      const byAlbum = new Map<string, UploadRecord[]>()
      for (const item of todo) {
        const albumId = ctx.decided.get(item.id)!.albumId!
        const list = byAlbum.get(albumId) ?? []
        list.push(records.get(item.id)!)
        byAlbum.set(albumId, list)
      }
      for (const [albumId, recs] of byAlbum) {
        const album = ctx.albums.find((a) => a.id === albumId)
        if (!album) continue
        const immichId = await ensureAlbum(ctx, album)
        const assetIds = recs.map((r) => r.assetId)
        for (let i = 0; i < assetIds.length; i += 500) {
          await api(ctx.cfg, 'PUT', `/albums/${immichId}/assets`, { ids: assetIds.slice(i, i + 500) })
        }
        const tagId = await ensureTag(ctx.cfg, albumTag(album))
        for (let i = 0; i < assetIds.length; i += 500) {
          await api(ctx.cfg, 'PUT', '/tags/assets', { tagIds: [tagId], assetIds: assetIds.slice(i, i + 500) })
        }
        for (const r of recs) {
          r.syncedAlbumId = albumId
          await uploads.put(r)
          done++
        }
        status()
      }
    } while (again)
    ctx.onStatus({ running: false, pending: 0, done, error: '' })
  } catch (e) {
    const records = new Map((await uploads.all()).map((r) => [r.id, r]))
    ctx.onStatus({
      running: false,
      pending: pendingUploads(ctx, records).length,
      done,
      error: e instanceof Error ? e.message : String(e),
    })
  } finally {
    running = false
  }
}

/** The Immich album for a Winnow album: remembered id, else one with the same name, else a new one. */
async function ensureAlbum(ctx: SyncContext, album: Album): Promise<string> {
  const name = albumTitle(album)
  if (album.immichAlbumId) {
    const found = await api<{ id: string }[]>(ctx.cfg, 'GET', `/albums?id=${album.immichAlbumId}`).catch(() => [])
    if (found.some((a) => a.id === album.immichAlbumId)) return album.immichAlbumId
  }
  const same = await api<{ id: string; albumName: string }[]>(ctx.cfg, 'GET', `/albums?name=${encodeURIComponent(name)}`)
  const id = same.find((a) => a.albumName === name)?.id ?? (await api<{ id: string }>(ctx.cfg, 'POST', '/albums', { albumName: name })).id
  album.immichAlbumId = id
  await ctx.saveAlbum(album)
  return id
}

const tagIds = new Map<string, string>()

/** Creates the tag path if needed (Immich makes the parents) and returns the leaf tag's id. */
async function ensureTag(cfg: ImmichConfig, path: string): Promise<string> {
  const cached = tagIds.get(path)
  if (cached) return cached
  const tags = await api<{ id: string; value: string }[]>(cfg, 'PUT', '/tags', { tags: [path] })
  const tag = tags.find((t) => t.value === path) ?? tags.at(-1)
  if (!tag) throw new Error(`Immich did not return the tag ${path}`)
  tagIds.set(path, tag.id)
  return tag.id
}
