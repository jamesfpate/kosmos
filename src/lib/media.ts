import { Capacitor, registerPlugin } from '@capacitor/core'

// Native side: android/app/src/main/java/net/jamespate/kosmos/MediaPlugin.java

export type MediaType = 'image' | 'video'

export interface MediaItem {
  id: number
  type: MediaType
  mime: string
  /** Date taken, epoch ms (falls back to date added). */
  taken: number
  width: number
  height: number
  size: number
  bucket: string | null
  name: string
  /** Video length in ms, 0 for images. */
  duration: number
}

export type Access = 'granted' | 'limited' | 'prompt' | 'denied'

interface MediaPlugin {
  getAccess(): Promise<{ access: Access }>
  requestAccess(): Promise<{ access: Access }>
  openSettings(): Promise<void>
  list(): Promise<{ items: MediaItem[] }>
  preview(opts: { id: number; type: MediaType; size?: number }): Promise<{ path: string }>
  open(opts: { id: number; type: MediaType; mime?: string }): Promise<void>
  trash(opts: { items: { id: number; type: MediaType }[] }): Promise<{ confirmed: boolean }>
}

// Browser fallback for `npm run dev`: no photos, everything allowed.
const web: MediaPlugin = {
  getAccess: async () => ({ access: 'granted' }),
  requestAccess: async () => ({ access: 'granted' }),
  openSettings: async () => {},
  list: async () => ({ items: [] }),
  preview: async () => ({ path: '' }),
  open: async () => {},
  trash: async () => ({ confirmed: true }),
}

export const Media = registerPlugin<MediaPlugin>('Media', { web: () => web })

const previewCache = new Map<string, Promise<string>>()

/** WebView URL of a cached JPEG preview; requests are shared and remembered. */
export function previewUrl(item: Pick<MediaItem, 'id' | 'type'>, size = 1600): Promise<string> {
  const key = `${item.id}_${size}`
  let p = previewCache.get(key)
  if (!p) {
    p = Media.preview({ id: item.id, type: item.type, size }).then(({ path }) => Capacitor.convertFileSrc(path))
    p.catch(() => previewCache.delete(key))
    previewCache.set(key, p)
  }
  return p
}
