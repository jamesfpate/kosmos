import { Capacitor, registerPlugin } from '@capacitor/core'

// Native side: android/app/src/main/java/net/jamespate/kosmos/MediaPlugin.java

export type MediaType = 'image' | 'video'

export interface MediaItem {
  id: number
  type: MediaType
  mime: string
  /** Date taken, epoch ms (falls back to date added). */
  taken: number
  /** As displayed (rotation applied); 0 when unknown. */
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

// Browser fallback for `npm run dev`: everything allowed; `?mock` adds fake photos (singles and bursts) to test layout.
function mockItems(): MediaItem[] {
  const out: MediaItem[] = []
  let t = Date.now() - 40 * 24 * 60 * 60 * 1000
  for (let i = 0; i < 120; i++) {
    t += i % 7 < 4 ? 2000 : 3 * 60 * 60 * 1000
    const portrait = i % 3 !== 0
    out.push({
      id: i + 1,
      type: i % 11 === 5 ? 'video' : 'image',
      mime: 'image/jpeg',
      taken: t,
      width: portrait ? 3000 : 4000,
      height: portrait ? 4000 : 3000,
      size: 1,
      bucket: i % 5 === 0 ? 'WhatsApp Images' : 'Camera',
      name: `PXL_${i + 1}.jpg`,
      duration: i % 11 === 5 ? 12000 : 0,
    })
  }
  return out
}

function mockPreview(id: number): string {
  const portrait = (id - 1) % 3 !== 0
  const [w, h] = portrait ? [300, 400] : [400, 300]
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="hsl(${(id * 47) % 360} 55% 45%)"/><text x="50%" y="50%" font-size="64" text-anchor="middle" fill="white">${id}</text></svg>`
  return `data:image/svg+xml,${encodeURIComponent(svg)}`
}

const mock = typeof location !== 'undefined' && location.search.includes('mock')
const web: MediaPlugin = {
  getAccess: async () => ({ access: 'granted' }),
  requestAccess: async () => ({ access: 'granted' }),
  openSettings: async () => {},
  list: async () => ({ items: mock ? mockItems() : [] }),
  preview: async ({ id }) => ({ path: mock ? mockPreview(id) : '' }),
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

/** Display aspect (width / height), clamped so panoramas and odd sizes stay usable in a grid. */
export function aspect(item: Pick<MediaItem, 'width' | 'height'>): number {
  if (!item.width || !item.height) return 3 / 4
  return Math.min(2.5, Math.max(0.4, item.width / item.height))
}
