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
})
