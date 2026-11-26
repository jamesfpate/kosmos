<script lang="ts">
  import { previewUrl, type MediaItem } from './media'

  export type Direction = 'left' | 'right'

  let { item, onswipe, onplay }: { item: MediaItem; onswipe: (dir: Direction) => void; onplay: () => void } =
    $props()

  let el: HTMLDivElement
  let dx = $state(0)
  let dy = $state(0)
  let dragging = $state(false)
  let leaving = $state<Direction | null>(null)
  let src = $state('')
  let failed = $state(false)
  let startX = 0
  let startY = 0
  let startT = 0

  $effect(() => {
    previewUrl(item).then(
      (url) => (src = url),
      () => (failed = true),
    )
  })

  function down(e: PointerEvent) {
    if (leaving || e.button !== 0) return
    dragging = true
    startX = e.clientX
    startY = e.clientY
    startT = e.timeStamp
    el.setPointerCapture(e.pointerId)
  }

  function move(e: PointerEvent) {
    if (!dragging) return
    dx = e.clientX - startX
    dy = e.clientY - startY
  }

  function up(e: PointerEvent) {
    if (!dragging) return
    dragging = false
    const speed = Math.abs(dx) / Math.max(1, e.timeStamp - startT) // px per ms
    if (Math.abs(dx) > el.clientWidth * 0.3 || (speed > 0.5 && Math.abs(dx) > 40)) {
      fling(dx > 0 ? 'right' : 'left')
    } else {
      dx = 0
      dy = 0
    }
  }

  /** Animate the card off screen, then report the decision. Also used by the buttons. */
  export function fling(dir: Direction) {
    if (leaving) return
    leaving = dir
    dx = (dir === 'right' ? 1 : -1) * window.innerWidth * 1.4
    setTimeout(() => onswipe(dir), 180)
  }

  const hint = $derived(Math.min(1, Math.abs(dx) / 120))
</script>

<div
  class="card"
  class:dragging
  bind:this={el}
  style:transform={`translate(${dx}px, ${dy * 0.3}px) rotate(${dx / 25}deg)`}
  onpointerdown={down}
  onpointermove={move}
  onpointerup={up}
  onpointercancel={up}
  role="img"
  aria-label={item.name}
>
  {#if src}
    <img {src} alt="" draggable="false" />
  {:else if failed}
    <p class="msg">Can't show {item.name}</p>
  {:else}
    <p class="msg">Loading…</p>
  {/if}

  {#if item.type === 'video'}
    <button class="play" onpointerdown={(e) => e.stopPropagation()} onclick={onplay} aria-label="Play video">
      ▶ <span>{Math.round(item.duration / 1000)}s</span>
    </button>
  {/if}

  <span class="label trash" style:opacity={dx < 0 ? hint : 0}>Trash</span>
  <span class="label keep" style:opacity={dx > 0 ? hint : 0}>Keep</span>
</div>

<style>
  .card {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    touch-action: none;
    user-select: none;
    transition: transform 0.18s ease-out;
    will-change: transform;
  }

  .card.dragging {
    transition: none;
  }

  img {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    border-radius: 12px;
    pointer-events: none;
  }

  .msg {
    color: var(--muted);
  }

  .play {
    position: absolute;
    bottom: 16px;
    left: 50%;
    transform: translateX(-50%);
    padding: 10px 18px;
    border: 0;
    border-radius: 999px;
    background: rgb(0 0 0 / 0.6);
    color: white;
    font-size: 1rem;
  }

  .play span {
    color: var(--muted);
    font-size: 0.85rem;
  }

  .label {
    position: absolute;
    top: 24px;
    padding: 6px 14px;
    border: 3px solid;
    border-radius: 10px;
    font-size: 1.4rem;
    font-weight: 700;
    text-transform: uppercase;
    pointer-events: none;
  }

  .trash {
    right: 20px;
    color: var(--trash);
    rotate: 12deg;
  }

  .keep {
    left: 20px;
    color: var(--keep);
    rotate: -12deg;
  }
</style>
