// Local state in IndexedDB (inside the WebView's app data; survives updates, cleared on uninstall).
// One record per reviewed photo/video, keyed by MediaStore id, plus a small key/value store.

export type Decision = 'keep' | 'pending_trash' | 'trash'

export interface DecisionRecord {
  id: number
  decision: Decision
  decidedAt: number
}

const DB = 'kosmos'
let dbp: Promise<IDBDatabase> | undefined

function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1)
    req.onupgradeneeded = () => {
      req.result.createObjectStore('decisions', { keyPath: 'id' })
      req.result.createObjectStore('meta')
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
  put: (r: DecisionRecord) => run('decisions', 'readwrite', (s) => s.put(r)),
  remove: (id: number) => run('decisions', 'readwrite', (s) => s.delete(id)),
}

export const meta = {
  get: <T>(key: string) => run<T | undefined>('meta', 'readonly', (s) => s.get(key)),
  set: (key: string, value: unknown) => run('meta', 'readwrite', (s) => s.put(value, key)),
}
