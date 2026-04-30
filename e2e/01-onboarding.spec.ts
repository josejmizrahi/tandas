import { test, expect } from '@playwright/test'

test.describe('Onboarding (placeholder)', () => {
  test('login page renders with phone + email tabs', async ({ page }) => {
    await page.goto('/login')
    await expect(page.getByRole('heading', { name: 'Tandas' })).toBeVisible()
    await expect(page.getByRole('tab', { name: 'Teléfono' })).toBeVisible()
    await expect(page.getByRole('tab', { name: 'Email' })).toBeVisible()
  })

  test('redirects unauthenticated user from / to /login', async ({ page }) => {
    await page.goto('/')
    await expect(page).toHaveURL(/\/login/)
  })

  // Real signup → create group → invite flows require Supabase test instance + OTP mock.
  // Wired up in Phase 7 when the auth env is available in CI.
  test.skip('full signup → create group → invite via wa.me', async () => {})
})
