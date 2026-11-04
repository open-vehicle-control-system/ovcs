import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, test, vi } from 'vitest'
import { OvcsButton, OvcsSwitch } from './index.js'

describe('OvcsButton', () => {
  test('is an outlined button that never submits a form', () => {
    render(<OvcsButton>Reset</OvcsButton>)
    const button = screen.getByRole('button', { name: 'Reset' })
    expect(button.getAttribute('type')).toBe('button')
    expect(button.className).toMatch('border-ovcs-border')
    expect(button.className).not.toMatch('font-semibold')
  })

  test('marks the primary action with the accent border and a bold label', () => {
    render(<OvcsButton variant="primary">Save</OvcsButton>)
    const { className } = screen.getByRole('button', { name: 'Save' })
    expect(className).toMatch('enabled:border-ovcs-accent')
    expect(className).toMatch('font-semibold')
  })

  test('adds `className` to its own classes and passes the other props on', () => {
    const onClick = vi.fn()
    render(
      <OvcsButton className="tabular-nums" disabled onClick={onClick}>
        Save
      </OvcsButton>
    )
    const button = screen.getByRole('button', { name: 'Save' })
    expect(button.className).toMatch(/min-h-9 .*tabular-nums$/)
    expect(button.disabled).toBe(true)
  })
})

describe('OvcsSwitch', () => {
  test('is a switch named by `label`, checked while `checked` is set', () => {
    const { rerender } = render(<OvcsSwitch label="Calibrate" checked={false} />)
    expect(screen.getByRole('switch', { name: 'Calibrate' }).getAttribute('aria-checked')).toBe('false')

    rerender(<OvcsSwitch label="Calibrate" checked />)
    expect(screen.getByRole('switch', { name: 'Calibrate' }).getAttribute('aria-checked')).toBe('true')
  })

  test('calls `onClick` and leaves its position to `checked`', () => {
    const onClick = vi.fn()
    render(<OvcsSwitch label="Calibrate" checked={false} onClick={onClick} />)

    fireEvent.click(screen.getByRole('switch'))
    expect(onClick).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('switch').getAttribute('aria-checked')).toBe('false')
  })
})
