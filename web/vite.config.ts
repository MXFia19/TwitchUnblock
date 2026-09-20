import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// `VITE_BASE` sert aux hébergements en sous-chemin : GitHub Pages publie sur
// /<depot>/, alors que Cloudflare Pages, Vercel et Netlify servent à la racine.
export default defineConfig({
  base: process.env.VITE_BASE ?? '/',
  plugins: [react()],
  build: { outDir: 'dist', sourcemap: true },
})
