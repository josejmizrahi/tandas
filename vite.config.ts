import path from 'path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const define: Record<string, string> = {}
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? process.env.SUPABASE_URL
const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? process.env.SUPABASE_ANON_KEY
if (supabaseUrl) define['import.meta.env.VITE_SUPABASE_URL'] = JSON.stringify(supabaseUrl)
if (supabaseKey) define['import.meta.env.VITE_SUPABASE_ANON_KEY'] = JSON.stringify(supabaseKey)

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  define,
})
