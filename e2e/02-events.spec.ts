import { test, expect } from '@playwright/test'

test.describe('Events (placeholder)', () => {
  test('eventos route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/eventos')
    await expect(page).toHaveURL(/\/login/)
  })

  test('eventos detail route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/eventos/00000000-0000-0000-0000-000000000000')
    await expect(page).toHaveURL(/\/login/)
  })

  // Real flows (admin creates event → member RSVPs → admin closes →
  // auto-rolled next event appears) require Supabase test instance + test user.
  // Wired up in Phase 7 with proper CI auth env.
  test.skip('admin creates event, member RSVPs, admin closes, next event auto-created', async () => {})
})
