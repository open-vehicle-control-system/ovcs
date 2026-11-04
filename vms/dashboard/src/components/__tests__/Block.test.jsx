import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import Block from '../Block.jsx'

describe('Block', () => {
  afterEach(() => vi.restoreAllMocks())

  it('shows a block that fails to render as an error in its own card', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    render(
      <>
        <Block block={{ id: 'broken', name: 'Broken', subtype: 'table', rows: null }} />
        <Block block={{ id: 'fine', name: 'Fine', subtype: 'table', rows: [] }} />
      </>
    )

    const card = screen.getByRole('heading', { level: 3, name: 'Broken' }).closest('.ovcs-card')
    expect(card.querySelector('[role="alert"]').textContent).toMatch('This block could not be shown')
    expect(screen.getByRole('heading', { level: 3, name: 'Fine' })).toBeTruthy()
  })

  it('tries the block again on Retry', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const block = { id: 'broken', name: 'Broken', subtype: 'table', rows: null }
    render(<Block block={block} />)

    block.rows = []
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(screen.queryByRole('alert')).toBe(null)
  })
})
