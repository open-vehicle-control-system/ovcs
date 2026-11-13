import { describe, it, expect, vi, beforeEach } from 'vitest'
import { Profiler } from 'react'
import { render, screen, fireEvent, within, act } from '@testing-library/react'
import Pipelines from '../Pipelines.jsx'
import { useParameters } from '../../stores/parameters.js'
import { useNavigation } from '../../stores/navigation.js'
import { useStatus } from '../../stores/status.js'

vi.mock('../../services/parameters.js')

const group = (id, name, position, extra = {}) => ({
  id, name, summary: '', pipeline: 'stereo', role: 'step', position, status: null, parameterIds: [], ...extra
})

const groups = [
  group('detection.inference', 'Inference', 102, { pipeline: 'detection', compute: { runsOn: 'npu', implementation: 'rust', backend: null } }),
  group('detection.input', 'Input', 101, { pipeline: 'detection' }),
  group('stereo.alignment', 'Alignment', 3, {
    status: { level: 'warning', detail: 'rows off by 1.4' },
    parameterIds: ['stereo.alignment.a', 'stereo.alignment.b']
  }),
  group('cameras', 'Cameras', 1, { role: 'source' }),
  group('stereo.temporal', 'Temporal', 4, { status: { level: 'off', detail: 'switched off' } }),
  group('stereo.match', 'Match', 2, { compute: { runsOn: 'gpu', implementation: 'nx', backend: 'vulkan' } })
]

const parameters = {
  'stereo.alignment.a': { id: 'stereo.alignment.a', name: 'a', state: 'unsaved' },
  'stereo.alignment.b': { id: 'stereo.alignment.b', name: 'b', state: 'unsaved' }
}

describe('Pipelines', () => {
  let select
  beforeEach(() => {
    select = vi.fn()
    useParameters.setState({ groups, parameters, selectedGroupId: 'stereo.match', select })
    useNavigation.setState({ page: 'pipeline' })
    useStatus.setState({ snapshot: null })
  })

  it('draws each pipeline as its own numbered flow, in order with arrows, the stereo pipeline first', () => {
    render(<Pipelines />)
    const names = (flow) => within(flow).getAllByRole('button').map((button) => button.querySelector('[translate="no"]').textContent)
    const numbers = (flow) => within(flow).getAllByRole('listitem').map((item) => item.firstElementChild.textContent)

    const stereo = screen.getByRole('list', { name: 'Stereo' })
    expect(names(stereo)).toEqual(['Cameras', 'Match', 'Alignment', 'Temporal'])
    expect(numbers(stereo)).toEqual(['1', '2', '3', '4'])
    expect(stereo.querySelectorAll('[data-arrow]')).toHaveLength(3)

    const detection = screen.getByRole('list', { name: 'Detection' })
    expect(names(detection)).toEqual(['Input', 'Inference'])
    expect(numbers(detection)).toEqual(['1', '2'])
    expect(stereo.compareDocumentPosition(detection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("shows each detection pipeline's inference time in its Inference box, once the unit reports one", () => {
    const road = group('road.inference', 'Inference', 102, { pipeline: 'road' })
    useParameters.setState({ groups: [...groups, road] })
    useStatus.setState({
      snapshot: { npu: { kind: 'Hexagon', state: 'running', loadPercent: 40, pipelines: { detection: { inferenceMs: 21.54 }, road: { inferenceMs: null } } } }
    })
    render(<Pipelines />)

    const inference = (pipeline) => within(screen.getByRole('list', { name: pipeline })).getByRole('button', { name: /^Inference/ })
    expect(inference('Detection').textContent).toContain('21.5 ms')
    expect(inference('Detection').getAttribute('aria-label')).toContain('21.5 ms')
    expect(inference('Road').textContent).not.toContain('ms')
    expect(screen.getByRole('button', { name: /^Match/ }).textContent).not.toContain('ms')
  })

  it('shows no inference time without an NPU status', () => {
    useStatus.setState({ snapshot: null })
    render(<Pipelines />)

    expect(screen.getByRole('list', { name: 'Detection' }).textContent).not.toContain('ms')
  })

  it('shows the detection pipeline as one greyed line on a unit without a detector', () => {
    useParameters.setState({ groups: groups.filter((g) => g.pipeline === 'stereo') })
    render(<Pipelines />)

    expect(screen.getByRole('heading', { name: 'Detection' })).toBeTruthy()
    expect(screen.queryByRole('list', { name: 'Detection' })).toBeNull()
    const line = screen.getByText('No detector on this unit')
    expect(line.closest('button')).toBeNull()
    expect(line.className).toContain('text-ovcs-muted')
  })

  it('shows no greyed detection line on a unit with only a named pipeline', () => {
    useParameters.setState({
      groups: [group('cameras', 'Cameras', 1, { role: 'source' }), group('road_signs.input', 'Input', 101, { pipeline: 'road_signs' })]
    })
    render(<Pipelines />)

    expect(screen.getByRole('list', { name: 'Road signs' })).toBeTruthy()
    expect(screen.queryByRole('heading', { name: 'Detection' })).toBeNull()
    expect(screen.queryByText('No detector on this unit')).toBeNull()
  })

  it('shows no pipeline before the stages have loaded', () => {
    useParameters.setState({ groups: [] })
    render(<Pipelines />)

    expect(screen.queryByRole('heading')).toBeNull()
    expect(screen.queryByText('No detector on this unit')).toBeNull()
  })

  it('marks a box with its unsaved count and its warning status', () => {
    render(<Pipelines />)

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

  it('shows a status dot only when a step is not fine, after its name', () => {
    useParameters.setState({
      groups: groups.map((g) => (g.id === 'stereo.match' ? { ...g, status: { level: 'ok', detail: 'fine' } } : g))
    })
    render(<Pipelines />)

    expect(screen.getByRole('button', { name: /^Match/ }).querySelector('.ovcs-status')).toBeNull()
    const alignment = screen.getByRole('button', { name: /^Alignment/ })
    const dot = alignment.querySelector('.ovcs-status--error')
    expect(dot).not.toBeNull()
    expect(alignment.firstElementChild.textContent).toBe('Alignment')
  })

  it('shows the selection with a left bar, not a frame, a warning item included', () => {
    const borders = (button) => button.className.split(/\s+/).filter((name) => /^border-ovcs-/.test(name))
    const BAR = 'shadow-[inset_3px_0_0_var(--ovcs-accent)]'

    useParameters.setState({ selectedGroupId: 'stereo.match' })
    const { unmount } = render(<Pipelines />)
    const match = screen.getByRole('button', { name: /^Match/ })
    expect(borders(match)).toEqual([])
    expect(match.className).toContain(BAR)
    expect(match.className).not.toMatch(/(^|\s)ring-/)
    unmount()

    useParameters.setState({ selectedGroupId: 'stereo.alignment' })
    render(<Pipelines />)
    const alignment = screen.getByRole('button', { name: /^Alignment/ })
    expect(borders(alignment)).toEqual(['border-ovcs-error'])
    expect(alignment.className).toContain(BAR)
    expect(screen.getByRole('button', { name: 'Cameras' }).className).not.toContain(BAR)
  })

  it('tags each stage with where it runs, under its name, and says it in the box name', () => {
    render(<Pipelines />)

    const match = screen.getByRole('button', { name: /^Match/ })
    expect([...match.querySelectorAll('[data-tag]')].map((tag) => tag.textContent)).toEqual(['GPU', 'Elixir Nx', 'Vulkan'])
    expect(match.getAttribute('aria-label')).toBe('Match, on GPU, Elixir Nx, Vulkan')
    const inference = screen.getByRole('button', { name: /^Inference/ })
    expect([...inference.querySelectorAll('[data-tag]')].map((tag) => tag.textContent)).toEqual(['NPU', 'Rust'])
    expect(screen.getByRole('button', { name: /^Cameras/ }).querySelectorAll('[data-tag]')).toHaveLength(0)
  })

  it('does not render again when a parameter changes without changing any unsaved count', () => {
    const commits = vi.fn()
    render(
      <Profiler id="menu" onRender={commits}>
        <Pipelines />
      </Profiler>
    )
    commits.mockClear()

    act(() =>
      useParameters.setState((state) => ({
        parameters: { ...state.parameters, 'stereo.alignment.a': { ...state.parameters['stereo.alignment.a'], value: 3 } }
      }))
    )
    expect(commits).not.toHaveBeenCalled()

    act(() =>
      useParameters.setState((state) => ({
        parameters: { ...state.parameters, 'stereo.alignment.a': { ...state.parameters['stereo.alignment.a'], state: 'builtin' } }
      }))
    )
    expect(commits).toHaveBeenCalled()
    expect(screen.getByRole('button', { name: /^Alignment/ }).getAttribute('aria-label')).toContain('1 unsaved')
  })

  it('selects a group on click', () => {
    render(<Pipelines />)

    expect(screen.getByRole('button', { name: /^Match/ }).getAttribute('aria-current')).toBe('true')
    expect(screen.getByRole('button', { name: 'Cameras' }).getAttribute('aria-current')).toBeNull()
    expect(screen.getByRole('button', { name: /^Match/ }).className).toContain('bg-[color-mix(')
    expect(screen.getByRole('button', { name: 'Cameras' }).className).not.toContain('bg-[color-mix(')

    fireEvent.click(screen.getByRole('button', { name: 'Cameras' }))
    expect(select).toHaveBeenCalledWith('cameras')
    expect(useNavigation.getState().page).toBe('pipeline')
  })

  it('shows no stage as selected on another page', () => {
    useNavigation.setState({ page: 'ros2' })
    render(<Pipelines />)

    expect(screen.getByRole('button', { name: /^Match/ }).getAttribute('aria-current')).toBeNull()
  })
})
