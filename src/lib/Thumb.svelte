<script lang="ts">
  import { previewUrl, type MediaItem } from './media'

  let { item }: { item: MediaItem } = $props()
  let src = $state('')

  $effect(() => {
    previewUrl(item, 384).then((url) => (src = url), () => {})
  })
</script>

{#if src}
  <img {src} alt="" loading="lazy" draggable="false" />
{:else}
  <span class="blank"></span>
{/if}

<style>
  img,
  .blank {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    background: var(--surface);
  }
</style>
