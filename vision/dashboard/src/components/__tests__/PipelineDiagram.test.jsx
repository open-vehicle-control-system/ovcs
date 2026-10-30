import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import PipelineDiagram from '../PipelineDiagram.jsx'
import { useParameters } from '../../stores/parameters.js'

vi.mock('../../services/parameters.js')

const group = (id, name, position, extra = {}) => ({
  id, name, summary: '', kind: 'stage', placement: 'flow', position, status: null, parameterIds: [], ...extra
})

const groups = [
  group('preview', 'Preview', 10, { kind: 'component', placement: 'side' }),
  group('stereo.alignment', 'Alignment', 3, {
    status: { level: 'warning', detail: 'rows off by 1.4' },
    parameterIds: ['stereo.alignment.a', 'stereo.alignment.b']
  }),
  group('cameras', 'Cameras', 1, { kind: 'component' }),
  group('stereo.temporal', 'Temporal', 4, { status: { level: 'off', detail: 'switched off' } }),
  group('stereo.match', 'Match', 2)
]

const parameters = {
  'stereo.alignment.a': { id: 'stereo.alignment.a', name: 'a', state: 'unsaved' },
  'stereo.alignment.b': { id: 'stereo.alignment.b', name: 'b', state: 'unsaved' }
}

describe('PipelineDiagram', () => {
  let select
  beforeEach(() => {
    select = vi.fn()
    useParameters.setState({ groups, parameters, selectedGroupId: 'stereo.match', select })
  })

  it('draws flow groups in order with arrows, and side groups apart', () => {
    render(<PipelineDiagram />)

    const flow = screen.getByRole('list', { name: 'Pipeline' })
    const names = within(flow).getAllByRole('button').map((button) => button.textContent)
    expect(names.map((name) => name.split(/\d/)[0].trim())).toEqual(['Cameras', 'Match', 'Alignment', 'Temporal'])
    expect(flow.querySelectorAll('[data-arrow]')).toHaveLength(3)

    const side = screen.getByRole('list', { name: 'Beside the pipeline' })
    expect(within(side).getAllByRole('button')).toHaveLength(1)
    expect(within(side).getByRole('button').textContent).toContain('Preview')
  })

  it('marks a box with its unsaved count and its warning status', () => {
    render(<PipelineDiagram />)

    const alignment = screen.getByRole('button', { name: /^Alignment/ })
    expect(alignment.textContent).toContain('2')
    expect(alignment.getAttribute('aria-label')).toBe('Alignment, 2 unsaved, warning: rows off by 1.4')
    expect(alignment.getAttribute('title')).toBe('rows off by 1.4')
    expect(alignment.className).toContain('border-ovcs-error')

    const temporal = screen.getByRole('button', { name: /^Temporal/ })
    expect(temporal.getAttribute('aria-label')).toBe('Temporal, off: switched off')
    expect(temporal.getAttribute('title')).toBe('switched off')
    expect(temporal.className).toContain('text-ovcs-muted')

    expect(screen.getByRole('button', { name: 'Cameras' })).toBeTruthy()
  })

  it('selects a group on click', () => {
    render(<PipelineDiagram />)

    expect(screen.getByRole('button', { name: 'Match' }).getAttribute('aria-current')).toBe('true')
    expect(screen.getByRole('button', { name: 'Cameras' }).getAttribute('aria-current')).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Cameras' }))
    expect(select).toHaveBeenCalledWith('cameras')
  })
})
