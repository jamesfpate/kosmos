<script lang="ts">
  import { previewUrl, type MediaItem } from './media'

  let { item }: { item: MediaItem } = $props()
  let src = $state('')
  let failed = $state('')

  $effect(() => {
    const id = item.id
    src = ''
    failed = ''
    previewUrl(item).then(
      (url) => id === item.id && (src = url),
      (e) => id === item.id && (failed = e instanceof Error ? e.message : String(e)),
    )
  })
</script>

{#if src}
  <img {src} alt="" draggable="false" />
{:else if failed}
  <p>Can't show {item.name}<br /><small>{failed}</small></p>
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
    padding: 0 16px;
    text-align: center;
    overflow-wrap: anywhere;
    color: var(--muted);
  }
</style>
