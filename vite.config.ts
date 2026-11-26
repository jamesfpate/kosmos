import { svelte } from '@sveltejs/vite-plugin-svelte'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [svelte()],
  define: {
    // CI sets KOSMOS_VERSION_NAME from the git tag; shown in the app so you can tell which build is installed
    __APP_VERSION__: JSON.stringify(process.env.KOSMOS_VERSION_NAME ?? '0.0.0-dev'),
  },
})
