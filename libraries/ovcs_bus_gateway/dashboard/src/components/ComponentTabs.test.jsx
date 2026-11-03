import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, test, vi } from 'vitest'

import { shortNames } from '../signals'
import ComponentTabs from './ComponentTabs.jsx'

const NOW = 100_000

const node = {
  node: 'vms',
  sources: [
    { source: 'VmsCore.Managers.Gear', signals: [{ name: 'gear', changeSeenAt: NOW - 500 }] },
    { source: 'OvcsMini.Vms.MainController', signals: [{ name: 'a', changeSeenAt: null }, { name: 'b', changeSeenAt: null }] }
  ]
}

const names = shortNames(node.sources.map((source) => source.source))

describe('ComponentTabs', () => {
  test('lists All, then each component by its short name, with its signal count', () => {
    render(<ComponentTabs node={node} names={names} selected={null} onSelect={vi.fn()} now={NOW} />)
    expect(screen.getAllByRole('button').map((tab) => tab.textContent)).toEqual(['All3', 'Gear1', 'MainController2'])
    expect(screen.getByRole('button', { name: /^All/ }).getAttribute('aria-current')).toBe('true')
    expect(screen.getByRole('button', { name: /^Gear/ }).getAttribute('title')).toBe('VmsCore.Managers.Gear')
  })

  test('lights a component whose value just changed', () => {
    render(<ComponentTabs node={node} names={names} selected={null} onSelect={vi.fn()} now={NOW} />)
    expect(screen.getByRole('button', { name: /^Gear/ }).querySelector('.ovcs-dot--on')).not.toBeNull()
    expect(screen.getByRole('button', { name: /^MainController/ }).querySelector('.ovcs-dot--on')).toBeNull()
  })

  test('selects a component, and All again', () => {
    const onSelect = vi.fn()
    render(<ComponentTabs node={node} names={names} selected="VmsCore.Managers.Gear" onSelect={onSelect} now={NOW} />)
    expect(screen.getByRole('button', { name: /^Gear/ }).getAttribute('aria-current')).toBe('true')
    fireEvent.click(screen.getByRole('button', { name: /^MainController/ }))
    expect(onSelect).toHaveBeenLastCalledWith('OvcsMini.Vms.MainController')
    fireEvent.click(screen.getByRole('button', { name: /^All/ }))
    expect(onSelect).toHaveBeenLastCalledWith(null)
  })
})
