<script lang="ts">
  import type { Snippet } from 'svelte'

  export type Direction = 'left' | 'right'

  let {
    onswipe,
    ontap,
    keepLabel = 'Keep',
    trashLabel = 'Trash',
    children,
  }: {
    onswipe: (dir: Direction) => void
    ontap?: () => void
    keepLabel?: string
    trashLabel?: string
    children: Snippet
  } = $props()

  let el: HTMLDivElement
  let dx = $state(0)
  let dy = $state(0)
  let dragging = $state(false)
  let leaving = $state<Direction | null>(null)
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
  }

  function up(e: PointerEvent) {
    if (!dragging) return
    dragging = false
    const elapsed = Math.max(1, e.timeStamp - startT)
    if (!moved) {
      dx = 0
      dy = 0
      ontap?.()
      return
    }
    const speed = Math.abs(dx) / elapsed // px per ms
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

  .label {
    position: absolute;
    top: 24px;
    padding: 6px 14px;
    border: 3px solid;
    border-radius: 10px;
    background: rgb(0 0 0 / 0.35);
    font-size: 1.3rem;
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
