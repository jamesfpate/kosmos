<script lang="ts">
  import { fileUrl, Media, previewUrl, type MediaItem } from './media'

  let { item, play = false, onstop }: { item: MediaItem; play?: boolean; onstop?: () => void } = $props()
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

  const video = $derived(play && item.type === 'video' ? fileUrl(item) : null)

  /** The WebView can't play this file (codec, or no path): hand it to the system player instead. */
  function fallback() {
    onstop?.()
    Media.open({ id: item.id, type: item.type, mime: item.mime })
  }

  $effect(() => {
    if (play && item.type === 'video' && !video) fallback()
  })
</script>

{#if video}
  <!-- Touches on the player work its controls instead of swiping the card. Phone videos have no caption tracks. -->
  <!-- svelte-ignore a11y_media_has_caption -->
  <video
    src={video}
    poster={src || undefined}
    controls
    autoplay
    playsinline
    onerror={fallback}
    onended={onstop}
    onpointerdown={(e) => e.stopPropagation()}
  ></video>
{:else if src}
  <img {src} alt="" draggable="false" />
{:else if failed}
  <p>Can't show {item.name}<br /><small>{failed}</small></p>
{:else}
  <p>Loading…</p>
{/if}

<style>
  img,
  video {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    border-radius: 12px;
  }

  img {
    pointer-events: none;
  }

  video {
    width: 100%;
    background: #000;
  }

  p {
    margin: 0;
    padding: 0 16px;
    text-align: center;
    overflow-wrap: anywhere;
    color: var(--muted);
  }
</style>
