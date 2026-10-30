import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act, fireEvent } from '@testing-library/react'
import App from '../App.jsx'
import { useParameters } from '../stores/parameters.js'
import * as service from '../services/parameters.js'

vi.mock('../services/parameters.js')
vi.mock('../services/socket.js', () => ({
  dashboardSocket: { channel: () => ({ on: () => {}, join: () => {}, leave: () => {}, push: () => {} }) }
}))

const group = (id, name, position, placement = 'flow') => ({
  id, name, summary: '', kind: 'stage', placement, position, status: null, parameterIds: []
})

const groups = [
  group('preview', 'Preview', 0, 'side'),
  group('stereo.match', 'Match', 2),
  group('cameras', 'Cameras', 1)
]

const initial = useParameters.getState()

describe('App', () => {
  let actions
  beforeEach(() => {
    actions = { startPolling: vi.fn(), stopPolling: vi.fn() }
    useParameters.setState({ ...initial, ...actions, groups: [], parameters: {}, unsaved: 0, selectedGroupId: null })
    window.history.replaceState(null, '', '/')
  })

  it('polls the parameters while mounted', () => {
    const { unmount } = render(<App />)
    expect(actions.startPolling).toHaveBeenCalledTimes(1)
    expect(actions.stopPolling).not.toHaveBeenCalled()

    unmount()
    expect(actions.stopPolling).toHaveBeenCalledTimes(1)
  })

  it('selects the box named in the URL once the groups are loaded', () => {
    window.history.replaceState(null, '', '/?box=stereo.match')
    render(<App />)
    expect(useParameters.getState().selectedGroupId).toBeNull()

    act(() => useParameters.setState({ groups }))
    expect(useParameters.getState().selectedGroupId).toBe('stereo.match')
    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()
  })

  it('selects the first flow box when the URL names none or an unknown one', () => {
    window.history.replaceState(null, '', '/?box=gone')
    useParameters.setState({ groups })
    render(<App />)
    expect(useParameters.getState().selectedGroupId).toBe('cameras')
    expect(window.location.search).toBe('?box=cameras')
  })

  it('keeps the selected box in the URL', () => {
    useParameters.setState({ groups })
    render(<App />)

    act(() => useParameters.getState().select('stereo.match'))
    expect(window.location.search).toBe('?box=stereo.match')
  })

  it('shows the save bar with the unsaved count', () => {
    useParameters.setState({ groups, unsaved: 2 })
    render(<App />)
    expect(screen.getByRole('button', { name: 'Save 2 changes' })).toBeTruthy()
  })

  it('shows a failed save in the save bar and keeps the count', async () => {
    vi.mocked(service.saveParameters).mockRejectedValue(new Error('Saved values unavailable'))
    vi.mocked(service.fetchGroups).mockResolvedValue({ groups, parameters: {}, unsaved: 2 })
    useParameters.setState({ groups, unsaved: 2 })
    render(<App />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' })))

    expect(screen.getByRole('alert').textContent).toContain('Saved values unavailable')
    expect(screen.getByRole('button', { name: 'Save 2 changes' })).toBeTruthy()
  })
})
