import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

// The theme store reads the browser's choice when it loads, so each test loads it afresh.
async function showSwitch() {
  vi.resetModules()
  const { default: ThemeSwitch } = await import('../ThemeSwitch.jsx')
  render(<ThemeSwitch />)
  return screen.getByRole('switch', { name: 'Dark mode' })
}

describe('ThemeSwitch', () => {
  beforeEach(() => {
    window.localStorage.clear()
    delete document.documentElement.dataset.theme
  })

  afterEach(() => {
    vi.restoreAllMocks()
    delete window.matchMedia
  })

  it('switches to dark and back, and remembers the choice on this browser', async () => {
    const toggle = await showSwitch()
    expect(toggle.getAttribute('aria-checked')).toBe('false')

    fireEvent.click(toggle)
    expect(toggle.getAttribute('aria-checked')).toBe('true')
    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(window.localStorage.getItem('ovcs-theme')).toBe('dark')

    fireEvent.click(toggle)
    expect(toggle.getAttribute('aria-checked')).toBe('false')
    expect(document.documentElement.dataset.theme).toBe('light')
    expect(window.localStorage.getItem('ovcs-theme')).toBe('light')
  })

  it('starts from the theme chosen on this browser', async () => {
    window.localStorage.setItem('ovcs-theme', 'dark')

    expect((await showSwitch()).getAttribute('aria-checked')).toBe('true')
  })

  it("starts from the system's theme without a choice", async () => {
    window.matchMedia = vi.fn(() => ({ matches: true, addEventListener: vi.fn() }))

    expect((await showSwitch()).getAttribute('aria-checked')).toBe('true')
  })

  it('still switches when the browser keeps no storage', async () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    const toggle = await showSwitch()

    fireEvent.click(toggle)
    expect(toggle.getAttribute('aria-checked')).toBe('true')
    expect(document.documentElement.dataset.theme).toBe('dark')
  })
})
