import { test, expect } from '@playwright/test'

test.describe('Fines (placeholder)', () => {
  test('plata route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/plata')
    await expect(page).toHaveURL(/\/login/)
  })

  test('fine detail route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/plata/multas/00000000-0000-0000-0000-000000000000')
    await expect(page).toHaveURL(/\/login/)
  })

  // Real flow (admin closes event → fines auto-generated → user pays / appeals)
  // requires Supabase test instance + multiple users + seeded rules.
  // Wired up in Phase 7.
  test.skip('admin closes event → fines auto-generated → member pays', async () => {})
})
