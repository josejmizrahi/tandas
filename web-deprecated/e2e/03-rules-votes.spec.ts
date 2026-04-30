import { test, expect } from '@playwright/test'

test.describe('Rules + votes (placeholder)', () => {
  test('reglas route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/reglas')
    await expect(page).toHaveURL(/\/login/)
  })

  test('reglas/proponer route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/reglas/proponer')
    await expect(page).toHaveURL(/\/login/)
  })

  // Real flow (member proposes → others vote → close → rule activates)
  // requires Supabase test instance + multiple test users. Wired up in Phase 7.
  test.skip('member proposes rule, group votes, rule activates on pass', async () => {})
})
