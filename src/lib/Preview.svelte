<script lang="ts">
  import { previewUrl, type MediaItem } from './media'

  let { item }: { item: MediaItem } = $props()
  let src = $state('')
  let failed = $state(false)

  $effect(() => {
    const id = item.id
    src = ''
    failed = false
    previewUrl(item).then(
      (url) => id === item.id && (src = url),
      () => id === item.id && (failed = true),
    )
  })
</script>

{#if src}
  <img {src} alt="" draggable="false" />
{:else if failed}
  <p>Can't show {item.name}</p>
{:else}
  <p>Loading…</p>
{/if}

<style>
  img {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    border-radius: 12px;
    pointer-events: none;
  }

  p {
    margin: 0;
    color: var(--muted);
  }
</style>
