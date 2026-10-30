import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ParameterControl, { formatValue } from '../ParameterControl.jsx'

const p1 = {
  id: 'stereo.match.p1',
  name: 'p1',
  type: 'integer',
  constraint: { kind: 'range', min: 0, max: 255, step: null },
  applies: 'live',
  description: 'Penalty for a disparity change of one',
  default: 8,
  value: 8,
  saved: 8,
  state: 'builtin',
  controller: null,
  greaterThan: null
}

const show = (parameter, props = {}) => {
  const handlers = {
    onChange: vi.fn(),
    onReset: vi.fn(),
    onEditStart: vi.fn(),
    onEditEnd: vi.fn()
  }
  render(<ParameterControl parameter={parameter} {...handlers} {...props} />)
  return handlers
}

describe('ParameterControl', () => {
  it('renders a slider for a range, buttons for choices, a switch for a bool', () => {
    show(p1)
    show({ ...p1, id: 'mode', name: 'mode', type: 'string', constraint: { kind: 'choices', values: ['sgbm', 'bm'] }, value: 'bm', default: 'bm' })
    show({ ...p1, id: 'on', name: 'temporal', type: 'bool', constraint: { kind: 'bool' }, value: true, default: true })

    expect(screen.getByRole('slider', { name: 'p1' })).toBeTruthy()
    expect(screen.getByRole('textbox', { name: 'p1 value' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'bm' }).getAttribute('aria-pressed')).toBe('true')
    expect(screen.getByRole('button', { name: 'sgbm' }).getAttribute('aria-pressed')).toBe('false')
    expect(screen.getByRole('switch', { name: 'temporal' }).getAttribute('aria-checked')).toBe('true')
    expect(screen.getAllByText('live')).toHaveLength(3)
  })

  it('changes a choice and toggles a switch', () => {
    const choice = show({ ...p1, name: 'mode', type: 'string', constraint: { kind: 'choices', values: ['sgbm', 'bm'] }, value: 'bm', default: 'bm' })
    fireEvent.click(screen.getByRole('button', { name: 'sgbm' }))
    expect(choice.onChange).toHaveBeenCalledWith('sgbm')

    const toggle = show({ ...p1, name: 'temporal', type: 'bool', constraint: { kind: 'bool' }, value: true, default: true })
    fireEvent.click(screen.getByRole('switch', { name: 'temporal' }))
    expect(toggle.onChange).toHaveBeenCalledWith(false)
  })

  it('narrows the slider to the bounds and states what the constraint allows', () => {
    show(p1, { bounds: { min: 0, max: 63 } })

    const slider = screen.getByRole('slider', { name: 'p1' })
    expect(slider.getAttribute('min')).toBe('0')
    expect(slider.getAttribute('max')).toBe('63')
    expect(slider.getAttribute('step')).toBe('1')
    expect(screen.getByText(/0 to 63/)).toBeTruthy()
  })

  it('steps a double without a step by a hundredth of its range', () => {
    show({ ...p1, name: 'uniqueness', type: 'double', constraint: { kind: 'range', min: 1, max: 3, step: null }, value: 1.2, default: 1.2 })

    expect(screen.getByRole('slider', { name: 'uniqueness' }).getAttribute('step')).toBe('0.02')
  })

  it('commits a dragged value on release, between edit start and end', () => {
    const handlers = show(p1)
    const slider = screen.getByRole('slider', { name: 'p1' })

    fireEvent.pointerDown(slider)
    expect(handlers.onEditStart).toHaveBeenCalledTimes(1)
    fireEvent.change(slider, { target: { value: '20' } })
    fireEvent.change(slider, { target: { value: '30' } })
    expect(handlers.onChange).not.toHaveBeenCalled()
    expect(screen.getByRole('textbox', { name: 'p1 value' }).value).toBe('30')

    fireEvent.pointerUp(slider)
    expect(handlers.onChange).toHaveBeenCalledTimes(1)
    expect(handlers.onChange).toHaveBeenCalledWith(30)
    expect(handlers.onEditEnd).toHaveBeenCalledTimes(1)
    expect(handlers.onChange.mock.invocationCallOrder[0]).toBeLessThan(handlers.onEditEnd.mock.invocationCallOrder[0])
  })

  it('commits once when the pointer is released outside the slider', () => {
    const handlers = show(p1)
    const slider = screen.getByRole('slider', { name: 'p1' })

    fireEvent.pointerDown(slider)
    fireEvent.change(slider, { target: { value: '20' } })
    fireEvent.lostPointerCapture(slider)
    fireEvent.blur(slider)

    expect(handlers.onChange).toHaveBeenCalledTimes(1)
    expect(handlers.onChange).toHaveBeenCalledWith(20)
    expect(handlers.onEditEnd).toHaveBeenCalledTimes(1)
  })

  it('does not write back a polled value on blur when you typed nothing', () => {
    const handlers = { onChange: vi.fn(), onReset: vi.fn() }
    const { rerender } = render(<ParameterControl parameter={p1} {...handlers} />)
    const input = screen.getByRole('textbox', { name: 'p1 value' })

    fireEvent.focus(input)
    rerender(<ParameterControl parameter={{ ...p1, value: 20 }} {...handlers} />)
    expect(input.value).toBe('20')
    fireEvent.blur(input)

    expect(handlers.onChange).not.toHaveBeenCalled()
  })

  it('shows a double without float noise', () => {
    show({ ...p1, name: 'uniqueness', type: 'double', constraint: { kind: 'range', min: 1, max: 3, step: null }, value: 0.1 + 0.2, default: 0.3 })

    expect(screen.getByRole('textbox', { name: 'uniqueness value' }).value).toBe('0.3')
  })

  it('shows a double with at most three decimals and an integer exactly', () => {
    expect(formatValue(1.23456789)).toBe('1.235')
    expect(formatValue(0.5)).toBe('0.5')
    expect(formatValue(123456789)).toBe('123456789')
  })

  it('fills the number field of a double up to its step', () => {
    show({ ...p1, name: 'uniqueness', type: 'double', constraint: { kind: 'range', min: 1, max: 3, step: 0.01 }, value: 1.23456, default: 1.2 })

    expect(screen.getByRole('textbox', { name: 'uniqueness value' }).value).toBe('1.23')
  })

  it('keeps the switch to its own width with the knob on its track', () => {
    show({ ...p1, name: 'auto exposure', type: 'bool', constraint: { kind: 'bool' }, value: false, default: false })

    const toggle = screen.getByRole('switch', { name: 'auto exposure' })
    expect(toggle.className).toContain('self-start')
    expect(toggle.querySelector('[aria-hidden] > span').className).toContain('left-0')
    expect(toggle.textContent).toBe('off')
  })

  it('commits a keyboard change when the key is released', () => {
    const handlers = show(p1)
    const slider = screen.getByRole('slider', { name: 'p1' })

    fireEvent.keyDown(slider, { key: 'ArrowRight' })
    fireEvent.change(slider, { target: { value: '9' } })
    expect(handlers.onChange).not.toHaveBeenCalled()
    fireEvent.keyUp(slider, { key: 'ArrowRight' })

    expect(handlers.onEditStart).toHaveBeenCalledTimes(1)
    expect(handlers.onChange).toHaveBeenCalledWith(9)
    expect(handlers.onEditEnd).toHaveBeenCalledTimes(1)
  })

  it('commits the number input on Enter, clamped to the bounds', () => {
    const handlers = show(p1, { bounds: { min: 0, max: 63 } })
    const input = screen.getByRole('textbox', { name: 'p1 value' })

    fireEvent.focus(input)
    fireEvent.change(input, { target: { value: '100' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(handlers.onChange).toHaveBeenCalledWith(63)
  })

  it('commits the number input on blur and ignores text that is not a number', () => {
    const handlers = show(p1)
    const input = screen.getByRole('textbox', { name: 'p1 value' })

    fireEvent.focus(input)
    fireEvent.change(input, { target: { value: 'abc' } })
    fireEvent.blur(input)
    expect(handlers.onChange).not.toHaveBeenCalled()
    expect(input.value).toBe('8')

    fireEvent.focus(input)
    fireEvent.change(input, { target: { value: '12.6' } })
    fireEvent.blur(input)
    expect(handlers.onChange).toHaveBeenCalledWith(13)
  })

  it('locks a build parameter and shows its badge', () => {
    show({ ...p1, name: 'disparities', applies: 'build', value: 64, default: 64 })

    expect(screen.getByText('build')).toBeTruthy()
    expect(screen.getByText('64')).toBeTruthy()
    expect(screen.queryByRole('slider')).toBeNull()
    expect(screen.queryByRole('textbox')).toBeNull()
    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.queryByText('live')).toBeNull()
    expect(screen.getByText('built-in')).toBeTruthy()
  })

  it('shows an automatic parameter read-only with its controller', () => {
    show({ ...p1, name: 'exposure_us', state: 'automatic', controller: 'cameras.auto_exposure', value: 8000, default: 10000 }, { controllerName: 'auto_exposure' })

    expect(screen.getByText('automatic')).toBeTruthy()
    expect(screen.getByText(/set by auto_exposure/)).toBeTruthy()
    expect(screen.getByText('8000')).toBeTruthy()
    expect(screen.queryByRole('slider')).toBeNull()
    expect(screen.queryByRole('textbox')).toBeNull()
    expect(screen.queryByRole('button')).toBeNull()
  })

  it('shows the default next to a changed value, and a reset button', () => {
    const handlers = show({ ...p1, value: 12, state: 'unsaved' })

    expect(screen.getByText('default 8')).toBeTruthy()
    expect(screen.getByText('unsaved')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Reset p1' }))
    expect(handlers.onReset).toHaveBeenCalled()
  })

  it('shows neither default nor reset for a value at its default', () => {
    show({ ...p1, state: 'saved' })

    expect(screen.queryByText(/default/)).toBeNull()
    expect(screen.queryByRole('button', { name: 'Reset p1' })).toBeNull()
    expect(screen.getByText('saved')).toBeTruthy()
  })

  it('shows a dash and disables the control when the value is null', () => {
    show({ ...p1, value: null })
    expect(screen.getByRole('slider', { name: 'p1' }).disabled).toBe(true)
    const input = screen.getByRole('textbox', { name: 'p1 value' })
    expect(input.disabled).toBe(true)
    expect(input.value).toBe('–')
    expect(screen.queryByRole('button', { name: 'Reset p1' })).toBeNull()

    show({ ...p1, name: 'temporal', type: 'bool', constraint: { kind: 'bool' }, value: null, default: true })
    expect(screen.getByRole('switch', { name: 'temporal' }).disabled).toBe(true)

    show({ ...p1, name: 'mode', type: 'string', constraint: { kind: 'choices', values: ['sgbm', 'bm'] }, value: null, default: 'bm' })
    expect(screen.getByRole('button', { name: 'bm' }).disabled).toBe(true)
    expect(screen.getAllByText('–').length).toBeGreaterThanOrEqual(2)
  })
})
