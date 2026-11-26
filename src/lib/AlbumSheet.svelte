<script lang="ts">
  import { albumTitle, monthPrefix, type Album } from './store.svelte'

  let {
    photoDate,
    oncreate,
    oncancel,
  }: { photoDate: number; oncreate: (album: Album) => void; oncancel: () => void } = $props()

  const DAY = 24 * 60 * 60 * 1000

  function toInput(ms: number): string {
    const d = new Date(ms)
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  }

  function fromInput(value: string): number | undefined {
    if (!value) return undefined
    const [y, m, d] = value.split('-').map(Number)
    return new Date(y, m - 1, d).getTime()
  }

  let dated = $state(true)
  // svelte-ignore state_referenced_locally
  let startInput = $state(toInput(photoDate))
  let endInput = $state('')
  let name = $state('')
  let input: HTMLInputElement

  const start = $derived(dated ? fromInput(startInput) : undefined)
  const prefix = $derived(start === undefined ? '' : monthPrefix(start))
  // The date prefix is added automatically; flag names that start with a year, month or YYYY-MM anyway.
  const DATE_START =
    /^\s*((19|20)\d\d([-/. ]\d{1,2})?|jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)\b[\s,.-]*/i
  const dateTyped = $derived(dated && DATE_START.test(name))
  const valid = $derived(name.trim().length > 0 && (!dated || start !== undefined))

  $effect(() => {
    input?.focus()
  })

  function stripDate() {
    name = name.replace(DATE_START, '')
    input.focus()
  }

  function create() {
    if (!valid) return
    const now = Date.now()
    const end = dated ? fromInput(endInput) : undefined
    oncreate({
      id: crypto.randomUUID(),
      name: name.trim(),
      start,
      end: end === undefined ? undefined : end + DAY - 1,
      createdAt: now,
      // Not "used" until a photo goes in, so creating an album doesn't change the default.
      lastUsedAt: 0,
    })
  }
</script>

<div class="backdrop" onclick={oncancel} role="presentation"></div>
<form
  class="sheet"
  onsubmit={(e) => {
    e.preventDefault()
    create()
  }}
>
  <h3>New album</h3>

  <label class="row">
    <span>Dates</span>
    <input type="checkbox" class="switch" bind:checked={dated} />
  </label>

  {#if dated}
    <div class="dates">
      <label>Start <input type="date" bind:value={startInput} required /></label>
      <label>End <input type="date" bind:value={endInput} min={startInput} /></label>
    </div>
    <p class="muted small">Photos taken between these dates are suggested into this album. Leave End empty while it's ongoing.</p>
  {/if}

  <div class="name">
    {#if prefix}<span class="prefix">{prefix}</span>{/if}
    <input bind:this={input} bind:value={name} placeholder={dated ? 'Hawaii' : 'Kids school'} enterkeyhint="done" />
  </div>
  {#if dateTyped}
    <p class="warn small">
      The date is added for you.
      <button type="button" class="link" onclick={stripDate}>Remove it from the name</button>
    </p>
  {:else}
    <p class="muted small">{dated
        ? 'Name only, the date is added for you.'
        : 'No dates: for things that span years (Kids school). Yearly events like Thanksgiving should keep dates so each year is its own album.'}</p>
  {/if}

  <p class="preview">Album: <b>{name.trim() ? albumTitle({ name: name.trim(), start }) : '…'}</b></p>

  <div class="buttons">
    <button type="button" onclick={oncancel}>Cancel</button>
    <button type="submit" class="primary" disabled={!valid}>Create</button>
  </div>
</form>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgb(0 0 0 / 0.55);
    z-index: 10;
  }

  .sheet {
    position: fixed;
    left: 0;
    right: 0;
    bottom: 0;
    z-index: 11;
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 20px 20px max(env(safe-area-inset-bottom), 20px);
    border-radius: 20px 20px 0 0;
    background: var(--surface);
    border-top: 1px solid var(--line);
  }

  h3,
  p {
    margin: 0;
  }

  .small {
    font-size: 0.85rem;
  }

  .muted {
    color: var(--muted);
  }

  .warn {
    color: #fbbf24;
  }

  .row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .switch {
    width: 22px;
    height: 22px;
    accent-color: var(--accent);
  }

  .dates {
    display: flex;
    gap: 10px;
  }

  .dates label {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 0.85rem;
    color: var(--muted);
  }

  input[type='date'],
  .name input {
    min-height: 44px;
    padding: 0 12px;
    border: 1px solid var(--line);
    border-radius: 10px;
    background: var(--bg);
    color: var(--text);
    font: inherit;
    color-scheme: dark;
  }

  .name {
    display: flex;
    gap: 8px;
    align-items: center;
  }

  .name input {
    flex: 1;
    min-width: 0;
    font-size: 1.05rem;
  }

  .prefix {
    padding: 10px 12px;
    border-radius: 10px;
    background: var(--line);
    color: var(--muted);
    font-variant-numeric: tabular-nums;
    user-select: none;
  }

  .preview {
    font-size: 0.95rem;
  }

  .buttons {
    display: flex;
    gap: 8px;
  }

  .buttons button {
    flex: 1;
    min-height: 48px;
    border: 1px solid var(--line);
    border-radius: 12px;
    background: var(--bg);
    color: var(--text);
    font: inherit;
  }

  .buttons .primary {
    background: var(--accent);
    border-color: var(--accent);
    color: #0b0b0f;
    font-weight: 600;
  }

  .buttons button:disabled {
    opacity: 0.4;
  }

  .link {
    padding: 0;
    border: 0;
    background: none;
    color: var(--accent);
    font: inherit;
    text-decoration: underline;
  }
</style>
