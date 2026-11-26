<script lang="ts">
  import type { Snippet } from 'svelte'

  export type Direction = 'left' | 'right'

  let {
    onswipe,
    ontap,
    ondrag,
    ondrop,
    keepLabel = 'Keep',
    trashLabel = 'Trash',
    children,
  }: {
    onswipe: (dir: Direction) => void
    ontap?: () => void
    /** Pointer position while dragging (for highlighting drop targets), null when the drag ends. */
    ondrag?: (point: { x: number; y: number } | null) => void
    /** Released while dragged upward: return true if it landed on a target (the card flies up and away). */
    ondrop?: (point: { x: number; y: number }) => boolean
    keepLabel?: string
    trashLabel?: string
    children: Snippet
  } = $props()

  let el: HTMLDivElement
  let dx = $state(0)
  let dy = $state(0)
  let dragging = $state(false)
  let leaving = $state(false)
  let startX = 0
  let startY = 0
  let startT = 0
  let moved = false

  // Touches this close to the screen's left/right edge belong to Android's back gesture.
  const EDGE = 28
  // Movement before a touch counts as a swipe (below it, it's a tap).
  const SLOP = 12

  function down(e: PointerEvent) {
    if (leaving || e.button !== 0) return
    if (e.clientX < EDGE || e.clientX > window.innerWidth - EDGE) return
    dragging = true
    moved = false
    startX = e.clientX
    startY = e.clientY
    startT = e.timeStamp
    el.setPointerCapture(e.pointerId)
  }

  function move(e: PointerEvent) {
    if (!dragging) return
    const x = e.clientX - startX
    const y = e.clientY - startY
    if (!moved && Math.hypot(x, y) < SLOP) return
    moved = true
    dx = x
    dy = y
    ondrag?.({ x: e.clientX, y: e.clientY })
  }

  function up(e: PointerEvent) {
    if (!dragging) return
    dragging = false
    ondrag?.(null)
    const elapsed = Math.max(1, e.timeStamp - startT)
    if (!moved) {
      reset()
      ontap?.()
      return
    }
    if (dy < -60 && Math.abs(dy) > Math.abs(dx) && ondrop) {
      if (ondrop({ x: e.clientX, y: e.clientY })) {
        leaving = true
        dy = -window.innerHeight
      } else {
        reset()
      }
      return
    }
    const speed = Math.abs(dx) / elapsed // px per ms
    if (Math.abs(dx) > el.clientWidth * 0.3 || (speed > 0.5 && Math.abs(dx) > 40)) {
      fling(dx > 0 ? 'right' : 'left')
    } else {
      reset()
    }
  }

  /** Animate the card off screen, then report the decision. Also used by the buttons. */
  export function fling(dir: Direction) {
    if (leaving) return
    leaving = true
    dx = (dir === 'right' ? 1 : -1) * window.innerWidth * 1.4
    setTimeout(() => onswipe(dir), 180)
  }

  /** Bring the card back to the middle (e.g. a keep that first needs an album). */
  export function reset() {
    leaving = false
    dx = 0
    dy = 0
  }

  const hint = $derived(Math.abs(dy) > Math.abs(dx) ? 0 : Math.min(1, Math.abs(dx) / 120))
</script>

<div
  class="card"
  class:dragging
  bind:this={el}
  style:transform={`translate(${dx}px, ${dy * (leaving || dy < 0 ? 1 : 0.3)}px) rotate(${dx / 25}deg)`}
  onpointerdown={down}
  onpointermove={move}
  onpointerup={up}
  onpointercancel={up}
  role="presentation"
>
  {@render children()}
  <span class="label trash" style:opacity={dx < 0 ? hint : 0}>{trashLabel}</span>
  <span class="label keep" style:opacity={dx > 0 ? hint : 0}>{keepLabel}</span>
</div>

<style>
  .card {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    touch-action: none;
    user-select: none;
    transition: transform 0.18s ease-out;
    will-change: transform;
  }

  .card.dragging {
    transition: none;
  }

  .label {
    position: absolute;
    top: 24px;
    max-width: 60%;
    padding: 6px 14px;
    border: 3px solid;
    border-radius: 10px;
    background: rgb(0 0 0 / 0.45);
    font-size: 1.2rem;
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
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
