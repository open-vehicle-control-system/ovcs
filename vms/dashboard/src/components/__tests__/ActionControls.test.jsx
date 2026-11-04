import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import RealTimeTable from '../RealTimeTable.jsx'
import { useMetrics } from '../../stores/metrics.js'
import { postAction } from '../../services/api.js'

vi.mock('../../services/api.js')

const steering = 'Elixir.SteeringColumn'
const throttle = 'Elixir.ThrottlePedal'

const button = { type: 'action', name: 'Reset status', inputType: 'button', inputName: 'Reset', module: steering, action: 'reset', extraParameters: {} }
const kp = {
  type: 'action',
  name: 'Kp',
  inputType: 'number',
  inputName: 'Set',
  module: steering,
  action: 'set_pid_parameter',
  extraParameters: { parameter: 'kp' },
  statusMetricKey: 'kp',
  step: '0.01'
}
const calibrate = {
  type: 'action',
  name: 'Calibrate throttle boundaries',
  inputType: 'toggle',
  inputName: 'Set',
  module: throttle,
  action: 'calibrate_boundaries',
  extraParameters: {},
  statusMetricKey: 'throttle_calibration_ongoing'
}

const table = (rows) => <RealTimeTable block={{ id: 'b', name: 'B', subtype: 'table', rows }} />
const publish = (data) => act(() => useMetrics.setState({ data }))

describe('action rows', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    postAction.mockResolvedValue(null)
    useMetrics.setState({ data: {}, units: {} })
  })

  it('posts a button action', async () => {
    render(table([button]))
    fireEvent.click(screen.getByRole('button', { name: 'Reset' }))
    expect(postAction).toHaveBeenCalledWith(button, undefined)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Reset' }).disabled).toBe(false))
  })

  it('disables the button while the action is in flight', async () => {
    let settle
    postAction.mockReturnValue(new Promise((resolve) => (settle = resolve)))
    render(table([button]))

    fireEvent.click(screen.getByRole('button', { name: 'Reset' }))
    expect(screen.getByRole('button', { name: 'Reset' }).disabled).toBe(true)

    await act(async () => settle(null))
    expect(screen.getByRole('button', { name: 'Reset' }).disabled).toBe(false)
  })

  it('shows a refused action under the row and clears it on the next attempt', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {})
    postAction.mockRejectedValueOnce(new Error('not_calibrating'))
    render(table([button]))

    fireEvent.click(screen.getByRole('button', { name: 'Reset' }))
    expect(await screen.findByText('not_calibrating')).toBeTruthy()
    expect(consoleError).toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Reset' }))
    expect(screen.queryByText('not_calibrating')).toBe(null)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Reset' }).disabled).toBe(false))
    consoleError.mockRestore()
  })

  it('seeds the number field once with the live value', () => {
    render(table([kp]))
    const field = screen.getByRole('spinbutton', { name: 'Kp' })
    expect(field.value).toBe('')

    publish({ [steering]: { kp: 0.1 } })
    expect(field.value).toBe('0.1')
    expect(screen.getByText('now 0.1')).toBeTruthy()

    publish({ [steering]: { kp: 0.2 } })
    expect(field.value).toBe('0.1')
    expect(screen.getByText('now 0.2')).toBeTruthy()
  })

  it('keeps what the operator typed while the live value moves', () => {
    render(table([kp]))
    publish({ [steering]: { kp: 0.1 } })
    const field = screen.getByRole('spinbutton', { name: 'Kp' })

    fireEvent.change(field, { target: { value: '0.5' } })
    publish({ [steering]: { kp: 0.3 } })
    expect(field.value).toBe('0.5')
  })

  it('posts the typed number on Enter and with its button', async () => {
    render(table([kp]))
    const field = screen.getByRole('spinbutton', { name: 'Kp' })
    fireEvent.change(field, { target: { value: '0.5' } })

    fireEvent.keyDown(field, { key: 'Enter' })
    expect(postAction).toHaveBeenLastCalledWith(kp, '0.5')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Set' }).disabled).toBe(false))

    fireEvent.click(screen.getByRole('button', { name: 'Set' }))
    expect(postAction).toHaveBeenCalledTimes(2)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Set' }).disabled).toBe(false))
  })

  it('posts nothing for an empty number field', () => {
    render(table([kp]))
    fireEvent.click(screen.getByRole('button', { name: 'Set' }))
    fireEvent.keyDown(screen.getByRole('spinbutton', { name: 'Kp' }), { key: 'Enter' })
    expect(postAction).not.toHaveBeenCalled()
  })

  it('shows no switch until its module publishes', () => {
    render(table([calibrate]))
    expect(screen.queryByRole('switch')).toBe(null)
  })

  it('shows the switch on while its status metric is true', () => {
    render(table([calibrate]))
    publish({ [throttle]: { throttle_calibration_ongoing: true } })
    expect(screen.getByRole('switch', { name: 'Calibrate throttle boundaries' }).getAttribute('aria-checked')).toBe('true')

    publish({ [throttle]: { throttle_calibration_ongoing: false } })
    expect(screen.getByRole('switch').getAttribute('aria-checked')).toBe('false')
  })

  it('posts the toggle action on click without moving the switch', async () => {
    render(table([calibrate]))
    publish({ [throttle]: { throttle_calibration_ongoing: false } })

    fireEvent.click(screen.getByRole('switch'))
    expect(postAction).toHaveBeenCalledWith(calibrate, undefined)
    expect(screen.getByRole('switch').getAttribute('aria-checked')).toBe('false')
    await waitFor(() => expect(screen.getByRole('switch').disabled).toBe(false))
  })
})
