<script lang="ts">
  import { previewUrl, type MediaItem } from './media'

  let { item }: { item: MediaItem } = $props()
  let el: HTMLSpanElement
  let src = $state('')
  // Only ask for a thumbnail once the cell is near the screen (grids can hold thousands).
  let near = $state(false)

  $effect(() => {
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          near = true
          io.disconnect()
        }
      },
      { rootMargin: '600px 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  })

  $effect(() => {
    if (near) previewUrl(item, 384).then((url) => (src = url), () => {})
  })
</script>

<span class="thumb" bind:this={el}>
  {#if src}<img {src} alt="" draggable="false" />{/if}
</span>

<style>
  .thumb,
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    background: var(--surface);
  }
</style>
