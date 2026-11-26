<script lang="ts">
  import { onMount } from 'svelte'
  import { Media, previewUrl, type Access, type MediaItem } from './lib/media'
  import { decisions, meta, type DecisionRecord } from './lib/store'
  import SwipeCard, { type Direction } from './lib/SwipeCard.svelte'
  import Thumb from './lib/Thumb.svelte'

  const version = __APP_VERSION__
  const DAY = 24 * 60 * 60 * 1000

  type Screen = 'loading' | 'access' | 'start' | 'cull' | 'trash' | 'error'

  let screen = $state<Screen>('loading')
  let access = $state<Access>('prompt')
  let error = $state('')
  let items = $state<MediaItem[]>([])
  let decided = $state(new Map<number, DecisionRecord>())
  let cutoff = $state<number | undefined>(undefined)
  let queue = $state<MediaItem[]>([])
  let undoStack = $state<{ item: MediaItem; prev?: DecisionRecord }[]>([])
  let restore = $state(new Set<number>())
  let busy = $state(false)
  let card = $state<SwipeCard>()

  const current = $derived(queue[0])
  const pendingTrash = $derived(items.filter((i) => decided.get(i.id)?.decision === 'pending_trash'))

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
    const kept = queue.filter((i) => listed.has(i.id) && !map.has(i.id))
    const fresh = all.filter((i) => !map.has(i.id) && !queued.has(i.id) && i.taken >= (cutoff ?? 0))
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

  async function decide(dir: Direction) {
    const item = current
    if (!item) return
    const record: DecisionRecord = {
      id: item.id,
      decision: dir === 'right' ? 'keep' : 'pending_trash',
      decidedAt: Date.now(),
    }
    undoStack = [...undoStack.slice(-49), { item, prev: decided.get(item.id) }]
    decided = new Map(decided).set(item.id, record)
    queue = queue.slice(1)
    for (const next of queue.slice(0, 3)) previewUrl(next).catch(() => {})
    await decisions.put(record)
  }

  async function undo() {
    const last = undoStack.at(-1)
    if (!last) return
    undoStack = undoStack.slice(0, -1)
    const next = new Map(decided)
    if (last.prev) {
      next.set(last.item.id, last.prev)
      await decisions.put(last.prev)
    } else {
      next.delete(last.item.id)
      await decisions.remove(last.item.id)
    }
    decided = next
    queue = [last.item, ...queue.filter((i) => i.id !== last.item.id)]
    screen = 'cull'
  }

  function later() {
    if (queue.length < 2) return
    queue = [...queue.slice(1), queue[0]]
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
    queue = [...back, ...queue]
    restore = new Set()
    undoStack = undoStack.filter((u) => !back.some((b) => b.id === u.item.id))
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
      undoStack = undoStack.filter((u) => !gone.has(u.item.id))
      screen = 'cull'
    } catch (e) {
      error = String(e)
    } finally {
      busy = false
    }
  }

  const fmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })
  const fmtTime = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' })
</script>

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
    <header>
      <div>
        {#if current}
          <b>{fmt.format(current.taken)}</b>
          <span class="muted">{fmtTime.format(current.taken)} · {current.bucket ?? ''}</span>
        {:else}
          <b>Kosmos</b>
        {/if}
      </div>
      <span class="muted">{queue.length} left</span>
      <button class="pill" disabled={!pendingTrash.length} onclick={() => (screen = 'trash')}>
        🗑 {pendingTrash.length}
      </button>
    </header>

    <div class="stage">
      {#if current}
        {#key current.id}
          <SwipeCard
            bind:this={card}
            item={current}
            onswipe={decide}
            onplay={() => Media.open({ id: current.id, type: current.type, mime: current.mime })}
          />
        {/key}
      {:else}
        <div class="center">
          <h2>All caught up</h2>
          {#if pendingTrash.length}
            <button class="primary" onclick={() => (screen = 'trash')}>Review trash ({pendingTrash.length})</button>
          {:else}
            <p class="muted">New photos show up here.</p>
          {/if}
        </div>
      {/if}
    </div>

    <footer>
      <button onclick={undo} disabled={!undoStack.length}>↶ Undo</button>
      <button class="trash" onclick={() => card?.fling('left')} disabled={!current}>Trash</button>
      <button class="keep" onclick={() => card?.fling('right')} disabled={!current}>Keep</button>
      <button onclick={later} disabled={queue.length < 2}>Later</button>
    </footer>
  {:else if screen === 'trash'}
    <header>
      <button class="pill" onclick={() => (screen = 'cull')}>‹ Back</button>
      <b>Trash · {pendingTrash.length}</b>
      <span></span>
    </header>
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
    padding: max(env(safe-area-inset-top), 8px) 12px max(env(safe-area-inset-bottom), 8px);
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

  header div {
    display: flex;
    flex-direction: column;
    font-size: 0.9rem;
  }

  .stage {
    position: relative;
    flex: 1;
    display: flex;
    margin: 8px 0;
    overflow: hidden;
  }

  footer {
    display: flex;
    gap: 8px;
  }

  footer button {
    flex: 1;
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

  button.keep {
    color: var(--keep);
  }

  .pill {
    min-height: 40px;
    border-radius: 999px;
  }

  .hint {
    margin: 4px 0 8px;
    font-size: 0.85rem;
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

  .cell {
    position: relative;
    aspect-ratio: 1;
    padding: 0;
    border: 0;
    border-radius: 0;
    overflow: hidden;
  }

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

  .version {
    position: fixed;
    right: 8px;
    bottom: 2px;
    font-size: 0.65rem;
    color: var(--muted);
    pointer-events: none;
  }
</style>
