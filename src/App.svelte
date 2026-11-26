<script lang="ts">
  import { onMount } from 'svelte'
  import { aspect, Media, previewUrl, type Access, type MediaItem } from './lib/media'
  import {
    albums as albumStore,
    albumTitle,
    decisions,
    monthPrefix,
    meta,
    type Album,
    type DecisionRecord,
  } from './lib/store.svelte'
  import SwipeCard, { type Direction } from './lib/SwipeCard.svelte'
  import Thumb from './lib/Thumb.svelte'
  import Preview from './lib/Preview.svelte'
  import AlbumSheet from './lib/AlbumSheet.svelte'

  const version = __APP_VERSION__
  const DAY = 24 * 60 * 60 * 1000
  const GROUP_MAX = 40
  const GAP_CHOICES = [0, 2, 5, 10, 30, 60] // seconds; 0 = never group

  const MONTH_ALBUM = 'month' // chip / drop target id for the month's catch-all album (until it exists)
  const GRID_STEP = 400 // cells rendered per scroll step in the grid

  type Screen = 'loading' | 'access' | 'start' | 'cull' | 'grid' | 'trash' | 'settings' | 'error'
  type UndoEntry = { item: MediaItem; prev?: DecisionRecord }

  let screen = $state<Screen>('loading')
  // The view the mode switch is on; settings and trash return to it.
  let mode = $state<'cull' | 'grid'>('cull')
  let access = $state<Access>('prompt')
  let error = $state('')
  let items = $state<MediaItem[]>([])
  let decided = $state(new Map<number, DecisionRecord>())
  let albums = $state<Album[]>([])
  let cutoff = $state<number | undefined>(undefined)
  let queue = $state<MediaItem[]>([])
  let undoStack = $state<UndoEntry[][]>([])
  let restore = $state(new Set<number>())
  let busy = $state(false)
  let card = $state<SwipeCard>()
  let selected = $state(new Set<number>())
  let focus = $state(0)
  // Photos taken within this many seconds of the previous one are culled together as one card (setting).
  let groupGap = $state(5)
  // Keeping a selection deletes the unselected photos of the burst / between the selected ones in the grid (setting).
  let autoTrash = $state(true)
  // Share of the card the group grid takes (drag the handle to change; remembered).
  let gridFrac = $state(0.4)
  // Album picked from the bar for the card on screen; otherwise the suggestion is used.
  let chosenId = $state<string | null>(null)
  let hover = $state<string | null>(null)
  let sheet = $state<{ fileAfter: boolean; grid?: boolean } | null>(null)
  let albumBar = $state<HTMLElement>()
  // Folders (MediaStore buckets) left out of culling and the grid, e.g. WhatsApp Images (setting).
  let hidden = $state(new Set<string>())
  let gridSel = $state(new Set<number>())
  let gridLimit = $state(GRID_STEP)
  // Thumbnail row height in the burst grid and Grid mode: slider or pinch (remembered).
  let thumbH = $state(150)
  const THUMB_MIN = 72
  const THUMB_MAX = 360
  const ROW_GAP = 3
  // Width available to thumbnail rows (measured; same for the burst grid and Grid mode).
  let rowW = $state(0)
  // Full-size viewer over the grid (index into the backlog), opened by long-press.
  let viewIdx = $state<number | null>(null)
  let viewX: number | null = null
  let held = false

  const bucketOf = (i: MediaItem) => i.bucket ?? ''
  const shown = (i: MediaItem) => !hidden.has(bucketOf(i))
  /** Belongs in the swipe queue: not decided, not before the start point, not in a hidden folder. */
  const inCull = (i: MediaItem) => !decided.has(i.id) && i.taken >= (cutoff ?? 0) && shown(i)

  const group = $derived.by(() => {
    const g: MediaItem[] = []
    for (const item of queue) {
      const last = g.at(-1)
      if (last && (groupGap === 0 || item.taken < last.taken || item.taken - last.taken > groupGap * 1000 || g.length >= GROUP_MAX))
        break
      g.push(item)
    }
    return g
  })
  const current = $derived(group[focus] ?? group[0])
  const isGroup = $derived(group.length > 1)
  const pendingTrash = $derived(items.filter((i) => decided.get(i.id)?.decision === 'pending_trash'))
  // Month albums ("YYYY-MM", the catch-all) count as one recent, shown for the photo's month.
  const monthUsed = $derived(Math.max(0, ...albums.filter((a) => a.monthly).map((a) => a.lastUsedAt)))

  /** That month's catch-all album, or a stand-in (id MONTH_ALBUM) until the first photo is filed into it. */
  function monthChip(t: number): Album {
    const d = new Date(t)
    const start = new Date(d.getFullYear(), d.getMonth(), 1).getTime()
    return (
      albums.find((a) => a.monthly && a.start === start) ?? {
        id: MONTH_ALBUM,
        name: '',
        start,
        createdAt: 0,
        lastUsedAt: monthUsed,
        monthly: true,
      }
    )
  }

  /** Albums by last use; the month album sits wherever its last use puts it (last if never used). */
  function recentFor(t: number | undefined): Album[] {
    const list = albums.filter((a) => !a.monthly)
    if (t !== undefined) list.push({ ...monthChip(t), lastUsedAt: monthUsed })
    return list.sort((a, b) => b.lastUsedAt - a.lastUsedAt)
  }

  /**
   * Default album: a dated album whose range covers the time; else the album used last if it has no dates (an
   * ongoing theme like "Kids school"); else that month's album.
   */
  function suggestFor(t: number | undefined): Album | undefined {
    if (t === undefined) return undefined
    const covering = albums
      .filter((a) => !a.monthly && a.start !== undefined && a.start <= t && (a.end === undefined || t <= a.end))
      .sort((a, b) => b.start! - a.start!)[0]
    const last = recentFor(t)[0]
    const undated = last && !last.monthly && last.start === undefined && last.lastUsedAt ? last : undefined
    return covering ?? undated ?? monthChip(t)
  }

  const recent = $derived(recentFor(group[0]?.taken))
  const suggested = $derived(suggestFor(group[0]?.taken))
  const target = $derived(
    chosenId === MONTH_ALBUM && group[0] ? monthChip(group[0].taken) : (recent.find((a) => a.id === chosenId) ?? suggested),
  )
  const barAlbums = $derived(target ? [target, ...recent.filter((a) => a.id !== target.id)] : recent)
  // In a burst, actions apply to the selected photos, or to the one shown large when none are selected.
  const keepCount = $derived(selected.size || 1)
  const keepLabel = $derived(
    `${selected.size ? `Keep ${keepCount}` : 'Keep'} → ${target ? albumTitle(target) : 'new album'}`,
  )
  const burstDoomed = $derived(autoTrash && selected.size ? group.filter((i) => !selected.has(i.id)) : [])
  const trashLabel = $derived(selected.size ? `Delete ${selected.size}` : 'Delete')


  /** Photos that still need an album: undecided (any date, e.g. before the start point) or kept without one. */
  const backlog = $derived(
    items
      .filter((i) => {
        if (!shown(i)) return false
        const d = decided.get(i.id)
        return !d || (d.decision === 'keep' && !d.albumId)
      })
      .sort((a, b) => b.taken - a.taken),
  )
  const months = $derived.by(() => {
    const out: { key: string; items: MediaItem[] }[] = []
    for (const item of backlog) {
      const key = monthPrefix(item.taken)
      if (out.at(-1)?.key !== key) out.push({ key, items: [] })
      out.at(-1)!.items.push(item)
    }
    return out
  })
  /** Whole months, until about gridLimit cells (more are added on scroll). */
  const gridMonths = $derived.by(() => {
    let n = 0
    const out: typeof months = []
    for (const m of months) {
      if (n >= gridLimit) break
      out.push(m)
      n += m.items.length
    }
    return out
  })
  const viewing = $derived(viewIdx === null ? undefined : backlog[viewIdx])
  const gridChosen = $derived(backlog.filter((i) => gridSel.has(i.id)))
  const gridOldest = $derived(gridChosen.reduce<number | undefined>((t, i) => (t === undefined || i.taken < t ? i.taken : t), undefined))
  // Nothing selected yet: suggest for the first photo in the grid (likely right); the selection takes over after.
  const gridBasis = $derived(gridOldest ?? backlog[0]?.taken)
  const gridSuggested = $derived(suggestFor(gridBasis))
  const gridRecent = $derived(recentFor(gridBasis))
  const gridAlbums = $derived(
    gridSuggested ? [gridSuggested, ...gridRecent.filter((a) => a.id !== gridSuggested.id)] : gridRecent,
  )
  const buckets = $derived.by(() => {
    const counts = new Map<string, number>()
    for (const i of items) counts.set(bucketOf(i), (counts.get(bucketOf(i)) ?? 0) + 1)
    return [...counts].sort((a, b) => b[1] - a[1])
  })

  onMount(() => {
    init()
    // Coming back to the app (e.g. after taking photos): pick up new items.
    const onVisible = () => document.visibilityState === 'visible' && screen === 'cull' && reload()
    document.addEventListener('visibilitychange', onVisible)
    return () => document.removeEventListener('visibilitychange', onVisible)
  })

  async function init() {
    try {
      access = (await Media.getAccess()).access
      if (access !== 'granted') {
        screen = 'access'
        return
      }
      cutoff = await meta.get<number>('cutoff')
      groupGap = (await meta.get<number>('groupGap')) ?? 5
      autoTrash = (await meta.get<boolean>('autoTrash')) ?? true
      gridFrac = (await meta.get<number>('gridFrac')) ?? 0.4
      thumbH = (await meta.get<number>('thumbH')) ?? 150
      hidden = new Set((await meta.get<string[]>('hiddenBuckets')) ?? [])
      albums = await albumStore.all()
      await reload()
      screen = cutoff === undefined ? 'start' : 'cull'
    } catch (e) {
      error = String(e)
      screen = 'error'
    }
  }

  async function requestAccess() {
    access = (await Media.requestAccess()).access
    if (access === 'granted') init()
  }

  async function reload() {
    const [{ items: all }, records] = await Promise.all([Media.list(), decisions.all()])
    // The native query sorts by DATE_TAKEN; items without one get a fallback date, so re-sort by that.
    all.sort((x, y) => x.taken - y.taken)
    const map = new Map(records.map((r) => [r.id, r]))
    // An item marked trashed that is still listed was restored from the system trash: review it again.
    for (const item of all) {
      if (map.get(item.id)?.decision === 'trash') {
        map.delete(item.id)
        await decisions.remove(item.id)
      }
    }
    items = all
    decided = map
    const listed = new Set(all.map((i) => i.id))
    const queued = new Set(queue.map((i) => i.id))
    // Keep the current order (including "Later" moves); new items join at the end in date order.
    const kept = queue.filter((i) => listed.has(i.id) && inCull(i))
    const fresh = all.filter((i) => !queued.has(i.id) && inCull(i))
    queue = [...kept, ...fresh]
    for (const next of queue.slice(0, 3)) previewUrl(next).catch(() => {})
  }

  async function chooseStart(from: number) {
    cutoff = from
    await meta.set('cutoff', from)
    queue = []
    await reload()
    screen = 'cull'
  }

  function countSince(from: number) {
    return items.filter((i) => i.taken >= from).length
  }

  const gridMonthsChosen = $derived(new Set(gridChosen.map((i) => monthPrefix(i.taken))))

  // Bumped on every decision so the swipe card starts fresh even when the burst's first photo stays.
  let cardKey = $state(0)

  function nextCard() {
    selected = new Set()
    focus = 0
    chosenId = null
  }

  /** Swipe right keeps into the target album (or asks for one); left trashes the whole card. */
  function decide(dir: Direction) {
    if (dir === 'right' && !target) {
      card?.reset()
      sheet = { fileAfter: true }
      return
    }
    file(dir, dir === 'right' ? target!.id : undefined)
  }

  /**
   * Records a decision for the selected photos of the burst, or the one shown large when none are selected. The
   * rest of the burst stays on screen (same album target) until every photo is decided.
   */
  async function file(dir: Direction, albumId?: string) {
    const chosen = selected.size ? group.filter((i) => selected.has(i.id)) : current ? [current] : []
    if (!chosen.length) return
    const doomed = dir === 'right' ? burstDoomed : []
    const rest = group.length - chosen.length - doomed.length
    const keepTarget = chosenId
    const at = focus
    const now = Date.now()
    const ids = new Map<number, string | undefined>()
    for (const item of chosen) {
      ids.set(item.id, dir === 'left' ? undefined : albumId === MONTH_ALBUM ? (await monthAlbumFor(item.taken)).id : albumId)
    }
    const records = [...chosen, ...doomed].map((item): DecisionRecord => {
      const id = ids.get(item.id)
      return id
        ? { id: item.id, decision: 'keep', decidedAt: now, albumId: id }
        : { id: item.id, decision: 'pending_trash', decidedAt: now }
    })
    nextCard()
    await commit([...chosen, ...doomed], records)
    cardKey++
    if (rest > 0) {
      // Same burst continues: keep the album choice and show the photo that took this one's place.
      chosenId = keepTarget
      focus = Math.min(at, Math.max(0, group.length - 1))
    }
  }

  /** Grid: files the selected photos into an album, or marks them for trash without one. */
  async function fileGrid(albumId?: string) {
    const chosen = gridChosen
    if (!chosen.length) return
    const doomed = albumId ? gridDoomed : []
    const now = Date.now()
    gridSel = new Set()
    // Month album: each photo goes into its own month's.
    const ids = new Map<number, string | undefined>()
    for (const item of chosen) ids.set(item.id, albumId === MONTH_ALBUM ? (await monthAlbumFor(item.taken)).id : albumId)
    await commit(
      [...chosen, ...doomed],
      [...chosen, ...doomed].map((item): DecisionRecord => {
        const id = ids.get(item.id)
        return id
          ? { id: item.id, decision: 'keep', decidedAt: now, albumId: id }
          : { id: item.id, decision: 'pending_trash', decidedAt: now }
      }),
    )
  }

  /** The catch-all "YYYY-MM" album for the month of `t`, created on first use. */
  async function monthAlbumFor(t: number): Promise<Album> {
    const d = new Date(t)
    const start = new Date(d.getFullYear(), d.getMonth(), 1).getTime()
    const found = albums.find((a) => a.monthly && a.start === start)
    if (found) return found
    const now = Date.now()
    const album: Album = {
      id: crypto.randomUUID(),
      name: '',
      start,
      end: new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime() - 1,
      createdAt: now,
      lastUsedAt: now,
      monthly: true,
    }
    albums = [...albums, album]
    await albumStore.put(album)
    return album
  }

  async function commit(cardItems: MediaItem[], records: DecisionRecord[]) {
    const now = Date.now()
    undoStack = [...undoStack.slice(-49), cardItems.map((item) => ({ item, prev: decided.get(item.id) }))]
    const next = new Map(decided)
    for (const r of records) next.set(r.id, r)
    decided = next
    const done = new Set(cardItems.map((i) => i.id))
    queue = queue.filter((i) => !done.has(i.id))
    for (const n of queue.slice(0, 3)) previewUrl(n).catch(() => {})
    for (const id of new Set(records.map((r) => r.albumId))) {
      const album = albums.find((a) => a.id === id)
      if (album) {
        album.lastUsedAt = now
        await albumStore.put(album)
      }
    }
    for (const r of records) await decisions.put(r)
  }

  function toggleKeep(id: number) {
    const next = new Set(selected)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    selected = next
  }

  function targetAt(point: { x: number; y: number }): string | null {
    for (const el of albumBar?.querySelectorAll<HTMLElement>('[data-target]') ?? []) {
      const r = el.getBoundingClientRect()
      if (point.x >= r.left && point.x <= r.right && point.y >= r.top - 24 && point.y <= r.bottom + 24) {
        return el.dataset.target!
      }
    }
    return null
  }

  function onDrag(point: { x: number; y: number } | null) {
    hover = point ? targetAt(point) : null
  }

  function onDrop(point: { x: number; y: number }): boolean {
    const t = targetAt(point)
    hover = null
    if (t === 'new') {
      sheet = { fileAfter: true }
      return false
    }
    if (t) {
      setTimeout(() => file('right', t), 180)
      return true
    }
    return false
  }

  async function createAlbum(album: Album) {
    const opened = sheet
    sheet = null
    albums = [...albums, album]
    await albumStore.put(album)
    if (opened?.grid) {
      if (opened.fileAfter) await fileGrid(album.id)
      return
    }
    chosenId = album.id
    if (opened?.fileAfter) card?.fling('right')
  }

  async function undo() {
    const last = undoStack.at(-1)
    if (!last) return
    undoStack = undoStack.slice(0, -1)
    const next = new Map(decided)
    for (const { item, prev } of last) {
      if (prev) {
        next.set(item.id, prev)
        await decisions.put(prev)
      } else {
        next.delete(item.id)
        await decisions.remove(item.id)
      }
    }
    decided = next
    // Undecided again and in range: back to the front of the queue (grid-filed backlog photos return to the grid).
    const again = last.map((e) => e.item).filter(inCull)
    const back = new Set(again.map((i) => i.id))
    queue = [...again, ...queue.filter((i) => !back.has(i.id))]
    nextCard()
  }

  function later() {
    if (queue.length <= group.length) return
    const moved = new Set(group.map((i) => i.id))
    queue = [...queue.filter((i) => !moved.has(i.id)), ...group]
    nextCard()
  }

  function resizeGrid(e: PointerEvent) {
    e.stopPropagation()
    const handle = e.currentTarget as HTMLElement
    const box = handle.parentElement!.getBoundingClientRect()
    handle.setPointerCapture(e.pointerId)
    const onMove = (ev: PointerEvent) => {
      // The handle sets how many rows show (cells keep their size); the photo keeps at least ~40%.
      gridFrac = Math.min(0.6, Math.max(0.2, (box.bottom - ev.clientY) / box.height))
    }
    const onUp = () => {
      handle.removeEventListener('pointermove', onMove)
      handle.removeEventListener('pointerup', onUp)
      handle.removeEventListener('pointercancel', onUp)
      meta.set('gridFrac', gridFrac)
    }
    handle.addEventListener('pointermove', onMove)
    handle.addEventListener('pointerup', onUp)
    handle.addEventListener('pointercancel', onUp)
  }

  async function setAutoTrash(on: boolean) {
    autoTrash = on
    await meta.set('autoTrash', on)
  }

  async function setGroupGap(seconds: number) {
    groupGap = seconds
    nextCard()
    await meta.set('groupGap', seconds)
  }

  async function toggleFolder(bucket: string) {
    const next = new Set(hidden)
    if (next.has(bucket)) next.delete(bucket)
    else next.add(bucket)
    hidden = next
    queue = queue.filter(shown)
    nextCard()
    await meta.set('hiddenBuckets', [...next])
    await reload()
  }

  function openGrid() {
    if (screen !== 'grid' && mode !== 'grid') {
      gridSel = new Set()
      gridLimit = GRID_STEP
    }
    mode = 'grid'
    screen = 'grid'
  }

  function openSingle() {
    mode = 'cull'
    screen = 'cull'
  }

  /** Settings and trash toggle: tapping again goes back to the current mode. */
  function toggleScreen(s: 'settings' | 'trash') {
    screen = screen === s ? mode : s
  }

  /** Grid order positions of the first and last selected photo. */
  const selSpan = $derived.by(() => {
    let lo = -1
    let hi = -1
    backlog.forEach((item, i) => {
      if (gridSel.has(item.id)) {
        if (lo < 0) lo = i
        hi = i
      }
    })
    return { lo, hi }
  })
  // Unselected photos between the first and last selected one.
  const gapCount = $derived(selSpan.lo < 0 ? 0 : selSpan.hi - selSpan.lo + 1 - gridSel.size)
  // Deleted along with filing the selection (red border) when the setting is on.
  const gridDoomed = $derived(
    autoTrash && selSpan.lo >= 0 ? backlog.slice(selSpan.lo, selSpan.hi + 1).filter((i) => !gridSel.has(i.id)) : [],
  )
  const gridDoomedIds = $derived(new Set(gridDoomed.map((i) => i.id)))

  /** Range select: tap the first and last photo, then this selects everything between them. */
  function selectBetween() {
    const next = new Set(gridSel)
    for (const item of backlog.slice(selSpan.lo, selSpan.hi + 1)) next.add(item.id)
    gridSel = next
  }

  function toggleGrid(id: number) {
    const next = new Set(gridSel)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    gridSel = next
  }

  /** Selects the whole month, or clears it when it's already fully selected. */
  function toggleMonth(list: MediaItem[]) {
    const next = new Set(gridSel)
    const all = list.every((i) => next.has(i.id))
    for (const i of list) {
      if (all) next.delete(i.id)
      else next.add(i.id)
    }
    gridSel = next
  }

  /**
   * Justified rows: photos keep their real shape. Each full row is scaled to fill the width exactly (height near
   * thumbH); the last row stays at thumbH.
   */
  function justify(list: MediaItem[]): { h: number; items: MediaItem[] }[] {
    const rows: { h: number; items: MediaItem[] }[] = []
    if (!rowW) return rows
    let row: MediaItem[] = []
    let sum = 0
    for (const item of list) {
      row.push(item)
      sum += aspect(item)
      const gaps = (row.length - 1) * ROW_GAP
      if (sum * thumbH + gaps >= rowW) {
        rows.push({ h: (rowW - gaps) / sum, items: row })
        row = []
        sum = 0
      }
    }
    if (row.length) rows.push({ h: thumbH, items: row })
    return rows
  }

  function measureRows(node: HTMLElement) {
    const ro = new ResizeObserver(([e]) => (rowW = Math.floor(e.contentRect.width)))
    ro.observe(node)
    return { destroy: () => ro.disconnect() }
  }

  function setThumbH(h: number, save = true) {
    thumbH = Math.round(Math.min(THUMB_MAX, Math.max(THUMB_MIN, h)))
    if (save) meta.set('thumbH', thumbH)
  }

  /** Two-finger pinch on the grid: spread for bigger thumbnails, pinch for smaller. */
  function pinch(node: HTMLElement) {
    let base = 0
    const dist = (e: TouchEvent) =>
      Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY)
    const start = (e: TouchEvent) => {
      if (e.touches.length === 2) base = dist(e)
    }
    const move = (e: TouchEvent) => {
      if (e.touches.length !== 2 || !base) return
      e.preventDefault()
      const d = dist(e)
      setThumbH((thumbH * d) / base, false)
      base = d
    }
    const end = (e: TouchEvent) => {
      if (e.touches.length < 2 && base) {
        base = 0
        meta.set('thumbH', thumbH)
      }
    }
    node.addEventListener('touchstart', start, { passive: true })
    node.addEventListener('touchmove', move, { passive: false })
    node.addEventListener('touchend', end)
    node.addEventListener('touchcancel', end)
    return {
      destroy() {
        node.removeEventListener('touchstart', start)
        node.removeEventListener('touchmove', move)
        node.removeEventListener('touchend', end)
        node.removeEventListener('touchcancel', end)
      },
    }
  }

  /** Long-press opens the photo full size; the click that follows the press is swallowed. */
  function hold(node: HTMLElement, id: number) {
    let timer: ReturnType<typeof setTimeout> | undefined
    let x = 0
    let y = 0
    const cancel = () => clearTimeout(timer)
    const down = (e: PointerEvent) => {
      x = e.clientX
      y = e.clientY
      held = false
      cancel()
      timer = setTimeout(() => {
        held = true
        openViewer(id)
      }, 450)
    }
    const move = (e: PointerEvent) => Math.hypot(e.clientX - x, e.clientY - y) > 10 && cancel()
    node.addEventListener('pointerdown', down)
    node.addEventListener('pointermove', move)
    node.addEventListener('pointerup', cancel)
    node.addEventListener('pointercancel', cancel)
    node.addEventListener('contextmenu', (e) => e.preventDefault())
    return {
      update: (next: number) => (id = next),
      destroy: cancel,
    }
  }

  /**
   * Opens the viewer while the finger is still down. The lift that ends the long-press (and any click Android
   * synthesises from it) must not reach the viewer, so they're swallowed once.
   */
  function openViewer(id: number) {
    viewIdx = backlog.findIndex((i) => i.id === id)
    viewX = null
    const swallow = (e: Event) => {
      e.stopPropagation()
      e.preventDefault()
    }
    const done = () => {
      window.removeEventListener('pointerup', onUp, true)
      window.removeEventListener('pointercancel', onUp, true)
      window.removeEventListener('click', swallow, true)
    }
    const onUp = (e: Event) => {
      swallow(e)
      setTimeout(done, 400)
    }
    window.addEventListener('pointerup', onUp, true)
    window.addEventListener('pointercancel', onUp, true)
    window.addEventListener('click', swallow, true)
  }

  function viewStep(by: number) {
    if (viewIdx === null) return
    const next = viewIdx + by
    if (next >= 0 && next < backlog.length) viewIdx = next
  }

  /** Only a swipe that started inside the viewer moves to the next/previous photo. */
  function viewUp(e: PointerEvent) {
    if (viewX === null) return
    const dx = e.clientX - viewX
    viewX = null
    if (Math.abs(dx) > 60) viewStep(dx < 0 ? 1 : -1)
  }

  /** Grows the grid when the sentinel at its end scrolls into view. */
  function more(node: HTMLElement) {
    const io = new IntersectionObserver(([e]) => e.isIntersecting && (gridLimit += GRID_STEP), { rootMargin: '800px 0px' })
    io.observe(node)
    return { destroy: () => io.disconnect() }
  }

  const fmtMonth = new Intl.DateTimeFormat(undefined, { month: 'long', year: 'numeric' })

  function changeStart() {
    queue = []
    screen = 'start'
  }

  function toggleRestore(id: number) {
    const next = new Set(restore)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    restore = next
  }

  async function restoreSelected() {
    const back = pendingTrash.filter((i) => restore.has(i.id))
    const next = new Map(decided)
    for (const item of back) {
      next.delete(item.id)
      await decisions.remove(item.id)
    }
    decided = next
    queue = [...back.filter(inCull), ...queue]
    restore = new Set()
    const backIds = new Set(back.map((b) => b.id))
    undoStack = undoStack.filter((entry) => !entry.some((u) => backIds.has(u.item.id)))
  }

  async function deleteTrash() {
    const doomed = pendingTrash.filter((i) => !restore.has(i.id))
    if (!doomed.length) return
    busy = true
    error = ''
    try {
      const { confirmed } = await Media.trash({ items: doomed.map((i) => ({ id: i.id, type: i.type })) })
      if (!confirmed) return
      const next = new Map(decided)
      for (const item of doomed) {
        const record: DecisionRecord = { id: item.id, decision: 'trash', decidedAt: Date.now() }
        next.set(item.id, record)
        await decisions.put(record)
      }
      decided = next
      const gone = new Set(doomed.map((i) => i.id))
      items = items.filter((i) => !gone.has(i.id))
      undoStack = undoStack.filter((entry) => !entry.some((u) => gone.has(u.item.id)))
      screen = mode
    } catch (e) {
      error = String(e)
    } finally {
      busy = false
    }
  }

  const fmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })
  const fmtTime = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' })
</script>

{#snippet topBar()}
  <header>
    <div class="modes" role="group" aria-label="View">
      <button class:on={screen === 'cull'} onclick={openSingle} aria-label="Single photo">▢</button>
      <button class:on={screen === 'grid'} onclick={openGrid} aria-label="Grid">▦</button>
    </div>
    <div class="title">
      {#if screen === 'cull' && current}
        <b>{fmt.format(current.taken)}</b>
        <span class="muted">
          {fmtTime.format(current.taken)} · {queue.length} left
        </span>
      {:else if screen === 'cull'}
        <b>Kosmos</b>
      {:else if screen === 'grid'}
        <b>{gridSel.size ? `${gridSel.size} selected` : 'No album'}</b>
        {#if gridSel.size}
          <span class="title-links">
            {#if gapCount}<button class="link" onclick={selectBetween} aria-label="Select the photos between">↔ Fill {gapCount}</button> ·{/if}
            <button class="link" onclick={() => (gridSel = new Set())}>Clear</button>
          </span>
        {:else}
          <span class="muted">{backlog.length} photos</span>
        {/if}
      {:else if screen === 'settings'}
        <b>Settings</b>
      {:else if screen === 'trash'}
        <b>Trash</b>
      {/if}
    </div>
    <span class="actions">
      <button
        class="pill"
        class:on={screen === 'trash'}
        disabled={!pendingTrash.length && screen !== 'trash'}
        onclick={() => toggleScreen('trash')}
        aria-label="Trash"
      >
        🗑 {pendingTrash.length}
      </button>
      <button class="pill" class:on={screen === 'settings'} onclick={() => toggleScreen('settings')} aria-label="Settings">
        ⚙
      </button>
    </span>
  </header>
{/snippet}

{#snippet sizeSlider()}
  <label class="size">
    <span aria-hidden="true">▫</span>
    <input
      type="range"
      min={THUMB_MIN}
      max={THUMB_MAX}
      step="4"
      value={thumbH}
      oninput={(e) => setThumbH(+e.currentTarget.value, false)}
      onchange={(e) => setThumbH(+e.currentTarget.value)}
      aria-label="Thumbnail size"
    />
    <span aria-hidden="true">◻</span>
  </label>
{/snippet}

<main>
  {#if screen === 'loading'}
    <section class="center"><p class="muted">Loading…</p></section>
  {:else if screen === 'error'}
    <section class="center">
      <h2>Something went wrong</h2>
      <p class="muted">{error}</p>
      <button class="primary" onclick={init}>Try again</button>
    </section>
  {:else if screen === 'access'}
    <section class="center">
      <h1>Kosmos</h1>
      {#if access === 'limited'}
        <p>Kosmos can only see the photos you selected. It needs <b>Allow all</b> to find new photos.</p>
        <button class="primary" onclick={() => Media.openSettings()}>Open settings</button>
        <button onclick={init}>I've changed it</button>
      {:else if access === 'denied'}
        <p>Photo access is off. Turn on <b>Photos and videos → Allow all</b> in settings.</p>
        <button class="primary" onclick={() => Media.openSettings()}>Open settings</button>
        <button onclick={init}>I've changed it</button>
      {:else}
        <p>Kosmos needs access to your photos and videos to cull them. Choose <b>Allow all</b>.</p>
        <button class="primary" onclick={requestAccess}>Allow access</button>
      {/if}
    </section>
  {:else if screen === 'start'}
    <section class="center">
      <h1>Where to start?</h1>
      <p class="muted">Older photos aren't touched. They wait in the backlog for later.</p>
      <button class="primary" onclick={() => chooseStart(Date.now() - DAY)}>
        From today <span>{countSince(Date.now() - DAY)}</span>
      </button>
      <button onclick={() => chooseStart(Date.now() - 30 * DAY)}>
        Last 30 days <span>{countSince(Date.now() - 30 * DAY)}</span>
      </button>
      <button onclick={() => chooseStart(0)}>Everything <span>{items.length}</span></button>
    </section>
  {:else if screen === 'cull'}
    {@render topBar()}

    <nav class="albums" bind:this={albumBar} aria-label="Albums">
      <span class="albums-label">Choose album{selected.size ? ` for ${selected.size}` : ''}</span>
      <div class="chips">
        {#each barAlbums as album (album.id)}
          <button
            class="chip"
            class:target={album.id === target?.id}
            class:hover={hover === album.id}
            data-target={album.id}
            onclick={() => (selected.size ? file('right', album.id) : (chosenId = album.id))}
          >
            {albumTitle(album)}
          </button>
        {/each}
        <button class="chip new" class:hover={hover === 'new'} data-target="new" onclick={() => (sheet = { fileAfter: false })}>
          + New album
        </button>
      </div>
    </nav>

    <div class="stage">
      {#if current}
        {#key cardKey}
          <SwipeCard
            bind:this={card}
            onswipe={decide}
            ontap={isGroup ? () => toggleKeep(current.id) : undefined}
            ondrag={onDrag}
            ondrop={onDrop}
            {keepLabel}
            {trashLabel}
          >
            <div class="photo" class:kept={isGroup && selected.has(current.id)}>
              <Preview item={current} />
              {#if isGroup && selected.has(current.id)}<span class="tick">✓</span>{/if}
              {#if current.type === 'video'}
                <button
                  class="play"
                  onpointerdown={(e) => e.stopPropagation()}
                  onclick={() => Media.open({ id: current.id, type: current.type, mime: current.mime })}
                >
                  ▶ {Math.round(current.duration / 1000)}s
                </button>
              {/if}
            </div>
            {#if isGroup}
              <div class="handle" onpointerdown={resizeGrid} role="separator" aria-orientation="horizontal">
                <span></span>
              </div>
              <div
                class="rows group-grid"
                use:measureRows
                style:height={`${gridFrac * 100}%`}
                onpointerdown={(e) => e.stopPropagation()}
                role="listbox"
                tabindex="-1"
              >
                {#each justify(group) as row, r (r)}
                  <div class="row">
                {#each row.items as item (item.id)}
                  {@const i = group.indexOf(item)}
                  <button
                    class="cell"
                    style:width={`${aspect(item) * row.h}px`}
                    style:height={`${row.h}px`}
                    class:focused={i === focus}
                    class:kept={selected.has(item.id)}
                    class:doomed={autoTrash && selected.size > 0 && !selected.has(item.id)}
                    onclick={() => {
                      focus = i
                      toggleKeep(item.id)
                    }}
                    role="option"
                    aria-selected={selected.has(item.id)}
                  >
                    <Thumb {item} />
                    {#if item.type === 'video'}<span class="badge">▶</span>{/if}
                    {#if selected.has(item.id)}<span class="tick small">✓</span>{/if}
                  </button>
                {/each}
                  </div>
                {/each}
              </div>
            {/if}
          </SwipeCard>
        {/key}
      {:else}
        <div class="center">
          <h2>All caught up</h2>
          {#if pendingTrash.length}
            <button class="primary" onclick={() => (screen = 'trash')}>Review trash ({pendingTrash.length})</button>
          {:else}
            <p class="muted">New photos show up here.</p>
          {/if}
          {#if backlog.length}
            <button onclick={openGrid}>File older photos <span>{backlog.length}</span></button>
          {/if}
        </div>
      {/if}
    </div>

    {#if isGroup}
      {@render sizeSlider()}
      <p class="muted hint">
        {selected.size
          ? `${selected.size} selected · ${burstDoomed.length ? `keeping them deletes the other ${burstDoomed.length}` : 'swipe or tap an album to file them, left to delete'}`
          : 'Swipe files the large photo · tap thumbnails to select several'}
      </p>
    {/if}
    <footer>
      <button onclick={undo} disabled={!undoStack.length}>↶ Undo</button>
      <button class="trash" onclick={() => card?.fling('left')} disabled={!current}>
        <svg class="arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M14 8H3M7 4L3 8l4 4" /></svg>Delete{selected.size ? ` ${selected.size}` : ''}
      </button>
      <button class="put" onclick={() => card?.fling('right')} disabled={!current}>
        <svg class="arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 8h11M9 4l4 4-4 4" /></svg><span class="label">{target ? albumTitle(target) : 'New album'}</span>
      </button>
      <button onclick={later} disabled={queue.length <= group.length}>Later</button>
    </footer>

    {#if sheet && current}
      <AlbumSheet photoDate={group[0].taken} oncreate={createAlbum} oncancel={() => (sheet = null)} />
    {/if}
  {:else if screen === 'settings'}
    {@render topBar()}
    <section class="settings">
      <h3>Group photos taken within</h3>
      <p class="muted">Shots taken this close together are culled as one card.</p>
      <div class="choices">
        {#each GAP_CHOICES as seconds}
          <button class:on={groupGap === seconds} onclick={() => setGroupGap(seconds)}>
            {seconds === 0 ? 'Off' : `${seconds}s`}
          </button>
        {/each}
      </div>

      <h3>Delete the unselected ones</h3>
      <p class="muted">
        Keeping selected photos also deletes the unselected photos of a burst, and in the grid the unselected ones between
        your first and last pick (shown with a red border). They go to Trash for review first.
      </p>
      <div class="choices">
        <button class:on={autoTrash} onclick={() => setAutoTrash(true)}>On</button>
        <button class:on={!autoTrash} onclick={() => setAutoTrash(false)}>Off</button>
      </div>

      <h3>Folders</h3>
      <p class="muted">Unticked folders are skipped when culling and in the grid.</p>
      <div class="folders">
        {#each buckets as [bucket, count] (bucket)}
          <label class="folder">
            <input type="checkbox" checked={!hidden.has(bucket)} onchange={() => toggleFolder(bucket)} />
            <span>{bucket || '(no folder)'}</span>
            <span class="muted">{count}</span>
          </label>
        {/each}
      </div>

      <h3>Start point</h3>
      <p class="muted">
        {cutoff ? `Culling photos from ${fmt.format(cutoff)}.` : 'Culling everything.'} Photos already reviewed stay
        reviewed.
      </p>
      <button onclick={changeStart}>Change start point</button>
    </section>
  {:else if screen === 'grid'}
    {@render topBar()}
    <nav class="albums" aria-label="Albums">
      <span class="albums-label">{gridSel.size
          ? `Choose album for ${gridSel.size}${gridDoomed.length ? ` · deletes ${gridDoomed.length} in red` : ''}`
          : 'Select photos to choose an album or delete'}</span>
      <div class="album-row">
        <div class="chips">
          {#each gridAlbums as album (album.id)}
            <button
              class="chip"
              class:target={album.id === gridSuggested?.id}
              disabled={!gridSel.size}
              onclick={() => fileGrid(album.monthly ? MONTH_ALBUM : album.id)}
            >
              {album.monthly && gridMonthsChosen.size > 1 ? `By month (${gridMonthsChosen.size})` : albumTitle(album)}
            </button>
          {:else}
            <span class="muted none">No albums yet</span>
          {/each}
        </div>
        {#if gridSel.size}
          <button class="chip add" onclick={() => (sheet = { fileAfter: true, grid: true })} aria-label="New album">
            +
          </button>
        {/if}
      </div>
    </nav>
    <div class="backlog" use:pinch>
      {#each gridMonths as month (month.key)}
        <div class="month">
          <b>{fmtMonth.format(month.items[0].taken)}</b>
          <button class="link" onclick={() => toggleMonth(month.items)}>
            {month.items.every((i) => gridSel.has(i.id)) ? 'Clear' : 'Select'}
            {month.items.length}
          </button>
        </div>
        <div class="rows" use:measureRows>
          {#each justify(month.items) as row, r (r)}
            <div class="row">
          {#each row.items as item (item.id)}
            <button
              class="cell"
              style:width={`${aspect(item) * row.h}px`}
              style:height={`${row.h}px`}
              class:kept={gridSel.has(item.id)}
              class:doomed={gridDoomedIds.has(item.id)}
              use:hold={item.id}
              onclick={() => (held ? (held = false) : toggleGrid(item.id))}
            >
              <Thumb {item} />
              {#if item.type === 'video'}<span class="badge">▶</span>{/if}
              {#if gridSel.has(item.id)}<span class="tick small">✓</span>{/if}
            </button>
          {/each}
            </div>
          {/each}
        </div>
      {:else}
        <div class="center">
          <h2>Everything has an album</h2>
        </div>
      {/each}
      {#if gridMonths.length < months.length}<div class="sentinel" use:more></div>{/if}
    </div>
    {@render sizeSlider()}
    <footer>
      <button onclick={undo} disabled={!undoStack.length}>↶ Undo</button>
      <button class="trash" onclick={() => fileGrid()} disabled={!gridSel.size}><svg class="arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M14 8H3M7 4L3 8l4 4" /></svg>Delete {gridSel.size || ''}</button>
      <button
        class="put"
        onclick={() => gridSuggested && fileGrid(gridSuggested.monthly ? MONTH_ALBUM : gridSuggested.id)}
        disabled={!gridSel.size || !gridSuggested}
      >
        <svg class="arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 8h11M9 4l4 4-4 4" /></svg><span class="label">{gridSuggested ? (gridSuggested.monthly && gridMonthsChosen.size > 1 ? `By month (${gridMonthsChosen.size})` : albumTitle(gridSuggested)) : 'Album'}</span>
      </button>
    </footer>
    {#if viewing}
      <div
        class="viewer"
        onpointerdown={(e) => (viewX = e.clientX)}
        onpointerup={viewUp}
        role="dialog"
        tabindex="-1"
        aria-label="Photo"
      >
        <header>
          <span class="when">
            <b>{fmt.format(viewing.taken)}</b>
            <span class="muted">{fmtTime.format(viewing.taken)} · {viewing.bucket ?? ''}</span>
          </span>
          <span class="muted count">{viewIdx! + 1} of {backlog.length}</span>
        </header>
        <div class="photo">
          {#key viewing.id}<Preview item={viewing} />{/key}
          {#if viewing.type === 'video'}
            <button class="play" onclick={() => Media.open({ id: viewing.id, type: viewing.type, mime: viewing.mime })}>
              ▶ {Math.round(viewing.duration / 1000)}s
            </button>
          {/if}
        </div>
        <p class="muted hint">Swipe for the next photo</p>
        <footer>
          <button onclick={() => (viewIdx = null)}>✕ Close</button>
          <button class:selected={gridSel.has(viewing.id)} onclick={() => toggleGrid(viewing.id)}>
            {gridSel.has(viewing.id) ? '✓ Selected' : 'Select'}
          </button>
        </footer>
      </div>
    {/if}
    {#if sheet && gridOldest !== undefined}
      <AlbumSheet photoDate={gridOldest} oncreate={createAlbum} oncancel={() => (sheet = null)} />
    {/if}
  {:else if screen === 'trash'}
    {@render topBar()}
    <p class="muted hint">Tap a photo to keep it out of the delete.</p>
    <div class="grid">
      {#each pendingTrash as item (item.id)}
        <button class="cell" class:restore={restore.has(item.id)} onclick={() => toggleRestore(item.id)}>
          <Thumb {item} />
          {#if item.type === 'video'}<span class="badge">▶</span>{/if}
          {#if restore.has(item.id)}<span class="badge back">↺</span>{/if}
        </button>
      {/each}
    </div>
    <footer>
      <button onclick={restoreSelected} disabled={!restore.size}>Restore {restore.size || ''}</button>
      <button class="trash" onclick={deleteTrash} disabled={busy || pendingTrash.length === restore.size}>
        Delete {pendingTrash.length - restore.size}
      </button>
    </footer>
    {#if error}<p class="muted hint">{error}</p>{/if}
  {/if}
  <p class="version">v{version}</p>
</main>

<style>
  main {
    height: 100%;
    display: flex;
    flex-direction: column;
    padding: max(env(safe-area-inset-top), 8px) 20px max(env(safe-area-inset-bottom), 8px);
    box-sizing: border-box;
  }

  .center {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    text-align: center;
    padding: 0 16px;
  }

  h1,
  h2,
  p {
    margin: 0;
  }

  .muted {
    color: var(--muted);
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-height: 48px;
  }

  .modes {
    display: flex;
    border: 1px solid var(--line);
    border-radius: 999px;
    overflow: hidden;
  }

  .modes button {
    min-height: 40px;
    min-width: 52px;
    padding: 0 14px;
    border: 0;
    border-radius: 0;
    background: var(--surface);
    font-size: 1.15rem;
  }

  .modes button.on,
  .pill.on {
    background: var(--accent);
    border-color: var(--accent);
    color: #0b0b0f;
  }

  .title {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    font-size: 0.85rem;
    line-height: 1.25;
    text-align: center;
  }

  .title > * {
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .title-links {
    color: var(--muted);
  }

  .title .link {
    min-height: 0;
    padding: 0;
    font-size: 0.85rem;
  }

  .when {
    display: flex;
    flex-direction: column;
    min-width: 0;
    font-size: 0.9rem;
  }

  .when span {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .count {
    font-size: 0.85rem;
    white-space: nowrap;
  }

  .actions {
    display: flex;
    gap: 6px;
  }

  .albums {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-top: 6px;
  }

  .albums-label {
    font-size: 0.75rem;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }

  .chips {
    display: flex;
    gap: 6px;
    overflow-x: auto;
    padding-bottom: 2px;
    scrollbar-width: none;
  }

  .chip {
    flex: none;
    min-height: 40px;
    padding: 0 14px;
    border-radius: 999px;
    white-space: nowrap;
  }

  .chip.target:disabled {
    opacity: 0.7;
  }

  .chip.target {
    background: var(--keep);
    border-color: var(--keep);
    color: #0b0b0f;
    font-weight: 600;
  }

  .chip.target::before {
    content: '→ ';
  }

  .chip.new {
    border-style: dashed;
    color: var(--accent);
  }

  .album-row {
    display: flex;
    gap: 6px;
    align-items: center;
  }

  .album-row .chips {
    flex: 1;
    min-width: 0;
  }

  .chip.add {
    flex: none;
    width: 44px;
    padding: 0;
    border-style: dashed;
    color: var(--accent);
    font-size: 1.4rem;
  }

  .none {
    align-self: center;
    font-size: 0.9rem;
  }

  .chip.hover {
    outline: 3px solid var(--accent);
    outline-offset: 1px;
    transform: scale(1.06);
  }

  .stage {
    position: relative;
    flex: 1;
    display: flex;
    margin: 8px 0;
    overflow: hidden;
  }

  .photo {
    position: relative;
    flex: 1;
    min-height: 0;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .photo.kept :global(img) {
    outline: 4px solid var(--keep);
    outline-offset: -4px;
  }

  .tick {
    position: absolute;
    top: 12px;
    left: 12px;
    width: 36px;
    height: 36px;
    display: grid;
    place-items: center;
    border-radius: 50%;
    background: var(--keep);
    color: #0b0b0f;
    font-weight: 700;
  }

  .tick.small {
    top: 4px;
    left: 4px;
    width: 22px;
    height: 22px;
    font-size: 0.75rem;
  }

  .play {
    position: absolute;
    bottom: 16px;
    left: 50%;
    transform: translateX(-50%);
    border: 0;
    border-radius: 999px;
    background: rgb(0 0 0 / 0.6);
    color: white;
  }

  .handle {
    flex: none;
    height: 32px;
    display: grid;
    place-items: center;
    touch-action: none;
    cursor: row-resize;
  }

  .handle span {
    width: 48px;
    height: 5px;
    border-radius: 3px;
    background: var(--line);
  }

  .grid {
    flex: 1;
    overflow-y: auto;
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 3px;
    align-content: start;
    margin-bottom: 8px;
  }

  .group-grid {
    flex: none;
    overflow-y: auto;
    margin: 0;
    touch-action: pan-y;
  }

  .cell {
    position: relative;
    aspect-ratio: 1;
    min-height: 0;
    padding: 0;
    border: 0;
    border-radius: 0;
    overflow: hidden;
  }

  .cell.focused {
    outline: 2px solid var(--text);
    outline-offset: -2px;
  }

  .cell.doomed :global(img) {
    opacity: 0.55;
  }

  /* Drawn over the photo so the dimming doesn't wash it out. */
  .cell.doomed::after {
    content: '';
    position: absolute;
    inset: 0;
    border: 3px solid var(--trash);
    pointer-events: none;
  }

  .cell.kept,
  .cell.restore {
    outline: 3px solid var(--keep);
    outline-offset: -3px;
  }

  .badge {
    position: absolute;
    top: 6px;
    right: 6px;
    padding: 2px 6px;
    border-radius: 6px;
    background: rgb(0 0 0 / 0.6);
    color: white;
    font-size: 0.75rem;
  }

  .badge.back {
    left: 6px;
    right: auto;
    color: var(--keep);
  }

  footer {
    display: flex;
    gap: 8px;
  }

  footer button {
    flex: 1;
    padding: 0 8px;
    white-space: nowrap;
  }

  button {
    min-height: 48px;
    padding: 0 16px;
    border: 1px solid var(--line);
    border-radius: 12px;
    background: var(--surface);
    color: var(--text);
    font: inherit;
  }

  button:disabled {
    opacity: 0.4;
  }

  .center button {
    width: min(100%, 320px);
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .center button span {
    color: var(--muted);
  }

  button.primary {
    background: var(--accent);
    border-color: var(--accent);
    color: #0b0b0f;
    font-weight: 600;
  }

  button.trash {
    color: var(--trash);
  }

  /* Arrows are SVG so they centre the same in every font. */
  footer button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
  }

  .arrow {
    flex: none;
    width: 1.05em;
    height: 1.05em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  footer .label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  footer button.put {
    flex: 2.4;
    padding: 0 10px;
    font-size: 0.95rem;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    background: var(--keep);
    border-color: var(--keep);
    color: #0b0b0f;
    font-weight: 600;
  }


  .pill {
    min-height: 40px;
    padding: 0 12px;
    border-radius: 999px;
  }

  .hint {
    margin: 0 0 8px;
    font-size: 0.8rem;
    text-align: center;
  }

  .settings {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-top: 8px;
    overflow-y: auto;
  }

  .settings h3 {
    margin: 12px 0 0;
    font-size: 1rem;
  }

  .choices {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .choices button {
    min-width: 56px;
    padding: 0 12px;
  }

  .choices button.on {
    background: var(--accent);
    border-color: var(--accent);
    color: #0b0b0f;
    font-weight: 600;
  }

  .backlog {
    flex: 1;
    touch-action: pan-y;
    overflow-y: auto;
    margin: 4px 0 8px;
  }

  .month {
    position: sticky;
    top: 0;
    z-index: 1;
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 2px;
    background: var(--bg);
  }

  /* Justified rows (see justify()): cells get exact sizes inline. */
  .rows {
    display: flex;
    flex-direction: column;
    gap: 3px;
    margin-bottom: 4px;
  }

  .row {
    display: flex;
    gap: 3px;
  }

  .rows .cell {
    flex: none;
    aspect-ratio: auto;
    min-height: 0;
  }

  .size {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 0 4px 6px;
    color: var(--muted);
  }

  .size input {
    flex: 1;
    accent-color: var(--accent);
  }

  .link {
    min-height: 32px;
    padding: 0 8px;
    border: 0;
    background: none;
    color: var(--accent);
  }

  .viewer {
    position: fixed;
    inset: 0;
    z-index: 5;
    display: flex;
    flex-direction: column;
    padding: max(env(safe-area-inset-top), 8px) 12px max(env(safe-area-inset-bottom), 8px);
    background: #000;
    touch-action: none;
  }

  .viewer button.selected {
    background: var(--keep);
    border-color: var(--keep);
    color: #0b0b0f;
    font-weight: 600;
  }

  .sentinel {
    height: 1px;
  }

  .folders {
    display: flex;
    flex-direction: column;
  }

  .folder {
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 44px;
    border-bottom: 1px solid var(--line);
  }

  .folder input {
    width: 20px;
    height: 20px;
    accent-color: var(--accent);
  }

  .folder span:first-of-type {
    flex: 1;
  }

  .version {
    position: fixed;
    right: 8px;
    bottom: 2px;
    font-size: 0.65rem;
    color: var(--muted);
    pointer-events: none;
  }
</style>
