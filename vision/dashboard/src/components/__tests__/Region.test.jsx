import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import Region from '../Region.jsx'
import { reloadPage } from '../../services/page.js'

vi.mock('../../services/page.js', () => ({ reloadPage: vi.fn() }))

function Broken() {
  throw new Error('no such field')
}

describe('Region', () => {
  // React logs each error a boundary catches.
  beforeEach(() => vi.spyOn(console, 'error').mockImplementation(() => {}))
  afterEach(() => vi.restoreAllMocks())

  it('shows what it holds', () => {
    render(<Region name="The menu">content</Region>)

    expect(screen.getByText('content')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('says it cannot be shown, and why, in place of content that throws, and leaves the rest of the page', () => {
    render(
      <>
        <Region name="The menu">
          <Broken />
        </Region>
        <Region name="This page">beside</Region>
      </>
    )

    expect(screen.getByRole('alert').textContent).toContain('The menu cannot be shown: no such field')
    expect(screen.getByText('beside')).toBeTruthy()
  })

  it('reloads the page from its button', () => {
    render(
      <Region name="The menu">
        <Broken />
      </Region>
    )

    fireEvent.click(screen.getByRole('button', { name: 'Reload' }))

    expect(reloadPage).toHaveBeenCalledTimes(1)
  })

  it('shows what it holds again once resetOn changes, and not while it stays', () => {
    const { rerender } = render(
      <Region name="This page" resetOn="overview">
        <Broken />
      </Region>
    )

    rerender(<Region name="This page" resetOn="overview">mended</Region>)
    expect(screen.getByRole('alert')).toBeTruthy()

    rerender(<Region name="This page" resetOn="api">mended</Region>)
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByText('mended')).toBeTruthy()
  })
})
