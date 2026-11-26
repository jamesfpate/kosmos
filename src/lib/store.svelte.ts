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
}

export function albumTitle(a: Pick<Album, 'name' | 'start'>): string {
  return a.start === undefined ? a.name : `${monthPrefix(a.start)} ${a.name}`
}

export function monthPrefix(ms: number): string {
  const d = new Date(ms)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

const DB = 'kosmos'
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
