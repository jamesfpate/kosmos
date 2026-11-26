<script lang="ts">
  import { onMount } from 'svelte'
  import { Media, previewUrl, type Access, type MediaItem } from './lib/media'
  import { decisions, meta, type DecisionRecord } from './lib/store'
  import SwipeCard, { type Direction } from './lib/SwipeCard.svelte'
  import Thumb from './lib/Thumb.svelte'
  import Preview from './lib/Preview.svelte'

  const version = __APP_VERSION__
  const DAY = 24 * 60 * 60 * 1000
  const GROUP_MAX = 40
  const GAP_CHOICES = [0, 2, 5, 10, 30, 60] // seconds; 0 = never group

  type Screen = 'loading' | 'access' | 'start' | 'cull' | 'trash' | 'settings' | 'error'

  let screen = $state<Screen>('loading')
  let access = $state<Access>('prompt')
  let error = $state('')
  let items = $state<MediaItem[]>([])
  let decided = $state(new Map<number, DecisionRecord>())
  let cutoff = $state<number | undefined>(undefined)
  let queue = $state<MediaItem[]>([])
  type UndoEntry = { item: MediaItem; prev?: DecisionRecord }
  let undoStack = $state<UndoEntry[][]>([])
  let restore = $state(new Set<number>())
  let busy = $state(false)
  let card = $state<SwipeCard>()
  let selected = $state(new Set<number>())
  let focus = $state(0)
  // Photos taken within this many seconds of the previous one are culled together as one card (setting).
  let groupGap = $state(5)

  // The card on screen: the next item plus any taken right after it (a burst / quick series).
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
  const keepCount = $derived(selected.size || group.length)
  const keepLabel = $derived(
    !isGroup ? 'Keep' : selected.size && selected.size < group.length ? `Keep ${selected.size}` : `Keep all ${group.length}`,
  )
  const trashLabel = $derived(isGroup ? `Trash all ${group.length}` : 'Trash')
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
      groupGap = (await meta.get<number>('groupGap')) ?? 5
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

  /**
   * Swipe left trashes the whole card. Swipe right keeps it; in a group with photos ticked, only the ticked
   * ones are kept and the rest go to trash.
   */
  async function decide(dir: Direction) {
    const items = group
    if (!items.length) return
    const now = Date.now()
    const records = items.map(
      (item): DecisionRecord => ({
        id: item.id,
        decision: dir === 'right' && (!selected.size || selected.has(item.id)) ? 'keep' : 'pending_trash',
        decidedAt: now,
      }),
    )
    undoStack = [...undoStack.slice(-49), items.map((item) => ({ item, prev: decided.get(item.id) }))]
    const next = new Map(decided)
    for (const r of records) next.set(r.id, r)
    decided = next
    const done = new Set(items.map((i) => i.id))
    queue = queue.filter((i) => !done.has(i.id))
    selected = new Set()
    focus = 0
    for (const n of queue.slice(0, 3)) previewUrl(n).catch(() => {})
    for (const r of records) await decisions.put(r)
  }

  function toggleKeep(id: number) {
    const next = new Set(selected)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    selected = next
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
    const back = new Set(last.map((e) => e.item.id))
    queue = [...last.map((e) => e.item), ...queue.filter((i) => !back.has(i.id))]
    selected = new Set()
    focus = 0
    screen = 'cull'
  }

  function later() {
    if (queue.length <= group.length) return
    const moved = new Set(group.map((i) => i.id))
    queue = [...queue.filter((i) => !moved.has(i.id)), ...group]
    selected = new Set()
    focus = 0
  }

  async function setGroupGap(seconds: number) {
    groupGap = seconds
    selected = new Set()
    focus = 0
    await meta.set('groupGap', seconds)
  }

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
    queue = [...back, ...queue]
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
      <span class="muted">{isGroup ? `${group.length} in a row · ` : ''}{queue.length} left</span>
      <span class="actions">
        <button class="pill" disabled={!pendingTrash.length} onclick={() => (screen = 'trash')}>
          🗑 {pendingTrash.length}
        </button>
        <button class="pill" onclick={() => (screen = 'settings')} aria-label="Settings">⚙</button>
      </span>
    </header>

    <div class="stage">
      {#if current}
        {#key group[0].id}
          <SwipeCard
            bind:this={card}
            onswipe={decide}
            ontap={isGroup ? () => toggleKeep(current.id) : undefined}
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
              <div class="strip" onpointerdown={(e) => e.stopPropagation()} role="listbox" tabindex="-1">
                {#each group as item, i (item.id)}
                  <button
                    class="frame"
                    class:focused={i === focus}
                    class:kept={selected.has(item.id)}
                    onclick={() => (i === focus ? toggleKeep(item.id) : (focus = i))}
                    role="option"
                    aria-selected={selected.has(item.id)}
                  >
                    <Thumb {item} />
                    {#if selected.has(item.id)}<span class="tick small">✓</span>{/if}
                  </button>
                {/each}
              </div>
              <p class="muted hint">
                Tap the photo to keep it · swipe right keeps {selected.size ? 'the ✓ ones' : 'all'}, left trashes all
              </p>
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
        </div>
      {/if}
    </div>

    <footer>
      <button onclick={undo} disabled={!undoStack.length}>↶ Undo</button>
      <button class="trash" onclick={() => card?.fling('left')} disabled={!current}>Trash</button>
      <button class="keep" onclick={() => card?.fling('right')} disabled={!current}>
        Keep{isGroup ? ` ${keepCount}` : ''}
      </button>
      <button onclick={later} disabled={queue.length <= group.length}>Later</button>
    </footer>
  {:else if screen === 'settings'}
    <header>
      <button class="pill" onclick={() => (screen = 'cull')}>‹ Back</button>
      <b>Settings</b>
      <span></span>
    </header>
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

      <h3>Start point</h3>
      <p class="muted">
        {cutoff ? `Culling photos from ${fmt.format(cutoff)}.` : 'Culling everything.'} Photos already reviewed stay
        reviewed.
      </p>
      <button onclick={changeStart}>Change start point</button>
    </section>
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
    width: 20px;
    height: 20px;
    font-size: 0.7rem;
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

  .strip {
    display: flex;
    gap: 4px;
    width: 100%;
    overflow-x: auto;
    padding: 8px 0 0;
    touch-action: pan-x;
  }

  .frame {
    position: relative;
    flex: 0 0 64px;
    height: 64px;
    min-height: 0;
    padding: 0;
    border: 2px solid transparent;
    border-radius: 8px;
    overflow: hidden;
  }

  .frame.focused {
    border-color: var(--text);
  }

  .frame.kept {
    border-color: var(--keep);
  }

  .actions {
    display: flex;
    gap: 6px;
  }

  .settings {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-top: 8px;
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

  .version {
    position: fixed;
    right: 8px;
    bottom: 2px;
    font-size: 0.65rem;
    color: var(--muted);
    pointer-events: none;
  }
</style>
