<script lang="ts">
  const version = __APP_VERSION__
</script>

<main>
  <h1>Kosmos</h1>
  <p>Nothing to cull yet.</p>
  <p class="version">v{version}</p>
</main>

<style>
  main {
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.25rem;
  }

  h1 {
    margin: 0;
    font-size: 2.5rem;
    letter-spacing: 0.05em;
  }

  p {
    margin: 0;
  }

  .version {
    color: var(--muted);
    font-size: 0.85rem;
  }
</style>
