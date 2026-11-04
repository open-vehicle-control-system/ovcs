import { describe, it, expect, beforeEach } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import Menu from '../Menu.jsx'
import { useNavigation } from '../../stores/navigation.js'

const pages = [
  { id: 'status', name: 'Status' },
  { id: 'drive', name: 'Drive' }
]

describe('Menu', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/')
    useNavigation.setState({ path: '/' })
  })

  it("lists the vehicle's pages in Pages, then Network in System", () => {
    render(<Menu pages={pages} />)

    const pagesSection = screen.getByRole('region', { name: 'Pages' })
    expect(within(pagesSection).getAllByRole('button').map((button) => button.textContent)).toEqual(['Status', 'Drive'])
    const system = screen.getByRole('region', { name: 'System' })
    expect(within(system).getAllByRole('button').map((button) => button.textContent)).toEqual(['Network'])
  })

  it('marks the current page', () => {
    render(<Menu pages={pages} />)
    expect(screen.getByRole('button', { name: 'Status' }).getAttribute('aria-current')).toBe('page')
    expect(screen.getByRole('button', { name: 'Drive' }).getAttribute('aria-current')).toBe(null)
  })

  it('opens a page at its path', () => {
    render(<Menu pages={pages} />)

    fireEvent.click(screen.getByRole('button', { name: 'Drive' }))
    expect(window.location.pathname).toBe('/drive')
    expect(screen.getByRole('button', { name: 'Drive' }).getAttribute('aria-current')).toBe('page')

    fireEvent.click(screen.getByRole('button', { name: 'Network' }))
    expect(window.location.pathname).toBe('/network')
  })
})
