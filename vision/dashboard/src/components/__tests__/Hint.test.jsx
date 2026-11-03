import { describe, it, expect } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import Hint from '../Hint.jsx'

const hint = { title: 'Jitter', text: "How much a pixel's disparity changes." }

describe('Hint', () => {
  it('explains its subject in a card on hover, and hides it on leave', () => {
    render(<Hint hint={hint} />)
    const button = screen.getByRole('button', { name: 'About Jitter' })
    expect(screen.queryByRole('tooltip')).toBeNull()

    fireEvent.mouseEnter(button)
    const card = screen.getByRole('tooltip')
    expect(card.textContent).toBe(`Jitter${hint.text}`)
    expect(button.getAttribute('aria-describedby')).toBe(card.id)

    fireEvent.mouseLeave(button)
    expect(screen.queryByRole('tooltip')).toBeNull()
  })

  it('opens on keyboard focus and closes on Escape', () => {
    render(<Hint hint={hint} />)
    const button = screen.getByRole('button', { name: 'About Jitter' })

    fireEvent.focus(button)
    expect(screen.getByRole('tooltip')).toBeTruthy()
    fireEvent.keyDown(button, { key: 'Escape' })
    expect(screen.queryByRole('tooltip')).toBeNull()
  })

  it('stays open while the pointer moves onto the card, and closes once it leaves both', () => {
    render(<Hint hint={hint} />)
    const button = screen.getByRole('button', { name: 'About Jitter' })
    button.getBoundingClientRect = () => ({ top: 100, bottom: 116, left: 50, width: 16 })

    fireEvent.mouseEnter(button)
    const card = screen.getByRole('tooltip')
    expect(card.style.top).toBe('116px')
    fireEvent.mouseLeave(button, { relatedTarget: card })
    expect(screen.getByRole('tooltip')).toBe(card)

    fireEvent.mouseLeave(card, { relatedTarget: document.body })
    expect(screen.queryByRole('tooltip')).toBeNull()
  })

  it('closes on Escape wherever the focus is, as when opened by the pointer', () => {
    render(<Hint hint={hint} />)

    fireEvent.mouseEnter(screen.getByRole('button', { name: 'About Jitter' }))
    fireEvent.keyDown(document.body, { key: 'Escape' })

    expect(screen.queryByRole('tooltip')).toBeNull()
  })
})
