// Local state in IndexedDB (inside the WebView's app data; survives updates, cleared on uninstall).

export type Decision = 'keep' | 'pending_trash' | 'trash'

export interface DecisionRecord {
  id: number
  decision: Decision
  decidedAt: number
  /** Album a kept photo was filed into (kept before v0.5 have none). */
  albumId?: string
}

/** One concept: an album, optionally with dates. Dated albums are named "YYYY-MM <name>". */
export interface Album {
  id: string
  name: string
  /** Start of the first day (local), for dated albums. */
  start?: number
  /** End of the last day (local); open-ended while undefined. */
  end?: number
  createdAt: number
  lastUsedAt: number
  /** The month's catch-all album, named just "YYYY-MM" (empty name; created on first use). */
  monthly?: boolean
}

export function albumTitle(a: Pick<Album, 'name' | 'start'>): string {
  if (a.start === undefined) return a.name
  return a.name ? `${monthPrefix(a.start)} ${a.name}` : monthPrefix(a.start)
}

/** Immich tag for an album: Albums/2026/11/Thanksgiving; undated Albums/Kids school; month albums Albums/2026/11. */
export function albumTag(a: Pick<Album, 'name' | 'start'>): string {
  if (a.start === undefined) return `Albums/${a.name}`
  const d = new Date(a.start)
  const y = String(d.getFullYear())
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const parts = ['Albums', y, m]
  if (a.name) parts.push(a.name)
  return parts.join('/')
}

export function monthPrefix(ms: number): string {
  const d = new Date(ms)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

const DB = 'winnow'
let dbp: Promise<IDBDatabase> | undefined

function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 2)
    req.onupgradeneeded = () => {
      const d = req.result
      if (!d.objectStoreNames.contains('decisions')) d.createObjectStore('decisions', { keyPath: 'id' })
      if (!d.objectStoreNames.contains('meta')) d.createObjectStore('meta')
      if (!d.objectStoreNames.contains('albums')) d.createObjectStore('albums', { keyPath: 'id' })
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
  return dbp
}

function run<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return db().then(
    (d) =>
      new Promise<T>((resolve, reject) => {
        const req = fn(d.transaction(store, mode).objectStore(store))
        req.onsuccess = () => resolve(req.result)
        req.onerror = () => reject(req.error)
      }),
  )
}

export const decisions = {
  all: () => run<DecisionRecord[]>('decisions', 'readonly', (s) => s.getAll()),
  put: (r: DecisionRecord) => run('decisions', 'readwrite', (s) => s.put($state.snapshot(r))),
  remove: (id: number) => run('decisions', 'readwrite', (s) => s.delete(id)),
}

export const albums = {
  all: () => run<Album[]>('albums', 'readonly', (s) => s.getAll()),
  put: (a: Album) => run('albums', 'readwrite', (s) => s.put($state.snapshot(a))),
}

export const meta = {
  get: <T>(key: string) => run<T | undefined>('meta', 'readonly', (s) => s.get(key)),
  set: (key: string, value: unknown) => run('meta', 'readwrite', (s) => s.put(value, key)),
}

/** Everything Winnow stores, as one JSON-able object (backup, or moving to a reinstalled / renamed app). */
export interface Backup {
  app: 'winnow'
  version: 1
  exportedAt: number
  decisions: DecisionRecord[]
  albums: Album[]
  meta: [string, unknown][]
}

export async function exportAll(): Promise<Backup> {
  const [d, a, keys, values] = await Promise.all([
    decisions.all(),
    albums.all(),
    run<IDBValidKey[]>('meta', 'readonly', (s) => s.getAllKeys()),
    run<unknown[]>('meta', 'readonly', (s) => s.getAll()),
  ])
  return {
    app: 'winnow',
    version: 1,
    exportedAt: Date.now(),
    decisions: d,
    albums: a,
    meta: keys.map((k, i) => [String(k), values[i]]),
  }
}

/** Merges a backup in (same ids are overwritten). Photo ids are MediaStore ids, so they hold on the same phone. */
export async function importAll(b: Backup): Promise<void> {
  // 'kosmos' = backups from before the rename.
  const app = (b as { app?: string })?.app
  if ((app !== 'winnow' && app !== 'kosmos') || !Array.isArray(b.decisions) || !Array.isArray(b.albums)) {
    throw new Error('Not a Winnow backup')
  }
  for (const r of b.decisions) await decisions.put(r)
  for (const a of b.albums) await albums.put(a)
  for (const [k, v] of b.meta ?? []) await meta.set(k, v)
}
