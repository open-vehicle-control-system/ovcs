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

  const box = (pipeline, name) => within(screen.getByRole('list', { name: pipeline })).getByRole('button', { name })
  const figure = (pipeline, name) => box(pipeline, name).querySelector('[data-time]')?.textContent ?? null
  const acceleratorFigure = (pipeline, name) => box(pipeline, name).querySelector('[data-accelerator]')?.textContent ?? null

  it("shows each step's time on its name's line, and says it in the box name", () => {
    useStatus.setState({
      snapshot: {
        npu: null,
        pipelines: {
          stereo: { totalMs: 9.87, stages: { match: 7.26, alignment: 2.61, temporal: null }, segments: [] },
          detection: { totalMs: 11.85, stages: { input: 1.52, inference: 10.33 }, segments: [] }
        }
      }
    })
    render(<Pipelines />)

    expect(figure('Stereo', /^Match/)).toBe('7.3 ms')
    expect(figure('Stereo', /^Alignment/)).toBe('2.6 ms')
    expect(figure('Stereo', /^Temporal/)).toBeNull()
    expect(figure('Detection', /^Input/)).toBe('1.5 ms')
    expect(figure('Detection', /^Inference/)).toBe('10.3 ms')
    expect(screen.getByRole('button', { name: /^Match/ }).getAttribute('aria-label')).toBe('Match, on GPU, Elixir Nx, Vulkan, 7.3 ms')

    const time = box('Stereo', /^Match/).querySelector('[data-time]')
    expect(time.parentElement.querySelector('[translate="no"]').textContent).toBe('Match')
    expect(time.className).toContain('ml-auto')
    expect(time.getAttribute('aria-hidden')).toBe('true')
  })

  it("shows the cameras' and the pairing's latencies on their rows, and leaves them out of the total", () => {
    const pairing = group('stereo.pairing', 'Pairing', 1.5, { compute: { runsOn: 'cpu', implementation: 'elixir', backend: null } })
    useParameters.setState({ groups: [...groups, pairing] })
    useStatus.setState({
      snapshot: {
        npu: null,
        latencies: { stereo: { cameras: 4.21, pairing: 1.06 } },
        pipelines: { stereo: { totalMs: 9.87, stages: { match: 7.26, alignment: 2.61 }, segments: [] } }
      }
    })
    render(<Pipelines />)

    const cameras = box('Stereo', /^Cameras/)
    expect(cameras.querySelector('[data-latency]').textContent).toBe('4.2 ms')
    expect(cameras.querySelector('[data-latency]').className).toContain('ml-auto')
    expect(cameras.querySelector('[data-latency]').title).toBe("capture to unit, not in the pipeline's total")
    expect(cameras.textContent).not.toContain('latency')
    expect(cameras.getAttribute('aria-label')).toBe('Cameras, capture to unit 4.2 ms, not in the total')
    expect(figure('Stereo', /^Cameras/)).toBeNull()

    const pairingBox = box('Stereo', /^Pairing/)
    expect(pairingBox.querySelector('[data-latency]').textContent).toBe('1.1 ms')
    expect(pairingBox.getAttribute('aria-label')).toBe('Pairing, on CPU, Elixir, wait to pair 1.1 ms, not in the total')

    expect(screen.getByRole('heading', { name: 'Stereo 9.9 ms' })).toBeTruthy()
    expect(box('Stereo', /^Match/).querySelector('[data-latency]')).toBeNull()
  })

  it('shows no latency the unit has not measured', () => {
    useStatus.setState({ snapshot: { npu: null, latencies: { stereo: { cameras: null, pairing: null } } } })
    render(<Pipelines />)

    expect(document.querySelectorAll('[data-latency]')).toHaveLength(0)
    expect(screen.getByRole('button', { name: 'Cameras' })).toBeTruthy()
  })

  it('shows no time on a source, which has no work to time', () => {
    useStatus.setState({ snapshot: { npu: null, pipelines: { stereo: { totalMs: 1, stages: { cameras: 1 }, segments: [] } } } })
    render(<Pipelines />)

    expect(figure('Stereo', /^Cameras/)).toBeNull()
  })

  const segmented = (segment, stages = {}) =>
    useStatus.setState({ snapshot: { npu: null, pipelines: { stereo: { totalMs: 28.04, stages, segments: [segment] } } } })

  const brackets = () => [...document.querySelectorAll('[data-run]')]

  it('draws steps computed together as one bracket over exactly their rows, with their one time and where they run', () => {
    segmented({ stages: ['match', 'alignment', 'temporal'], ms: 28.04 })
    render(<Pipelines />)

    expect(figure('Stereo', /^Match/)).toBeNull()
    expect(figure('Stereo', /^Alignment/)).toBeNull()
    expect(figure('Stereo', /^Temporal/)).toBeNull()
    expect(screen.getByRole('button', { name: /^Match/ }).getAttribute('aria-label')).toBe('Match, on GPU, Elixir Nx, Vulkan')

    expect(brackets()).toHaveLength(1)
    const bracket = screen.getByRole('img', { name: 'Steps 2 to 4 run as one GPU pass, 28.0 ms' })
    expect(bracket.dataset.firstStep).toBe('2')
    expect(bracket.dataset.lastStep).toBe('4')
    expect(bracket.style.gridRow).toBe('2 / 5')
    expect(bracket.textContent).toBe('28.0 ms · GPU')
    expect(bracket.closest('ol')).toBeNull()
    expect(screen.queryByText(/run as one/)).toBeNull()
  })

  it('names where steps computed together run from their own tags, and nothing without any', () => {
    const onCpu = { runsOn: 'cpu', implementation: 'nx', backend: 'llvm_cpu' }
    useParameters.setState({ groups: groups.map((g) => (g.id === 'stereo.match' ? { ...g, compute: onCpu } : g)) })
    segmented({ stages: ['match', 'alignment'], ms: 28.04 })
    const { unmount } = render(<Pipelines />)
    expect(screen.getByRole('img', { name: 'Steps 2 to 3 run as one CPU pass, 28.0 ms' }).textContent).toBe('28.0 ms · CPU')
    unmount()

    useParameters.setState({ groups: groups.map((g) => (g.id === 'stereo.match' ? { ...g, compute: undefined } : g)) })
    render(<Pipelines />)
    expect(screen.getByRole('img', { name: 'Steps 2 to 3 run as one pass, 28.0 ms' }).textContent).toBe('28.0 ms')
  })

  it('draws no bracket for steps computed together that have no time', () => {
    segmented({ stages: ['match', 'alignment', 'temporal'], ms: null })
    render(<Pipelines />)

    expect(brackets()).toHaveLength(0)
    expect(figure('Stereo', /^Match/)).toBeNull()
  })

  it('keeps the time of a run of one step on that step, which is timed alone, with no bracket', () => {
    segmented({ stages: ['alignment'], ms: 4.21 })
    render(<Pipelines />)

    expect(figure('Stereo', /^Alignment/)).toBe('4.2 ms')
    expect(brackets()).toHaveLength(0)
  })

  it('counts a run as of one step when its other stages are not among the steps', () => {
    segmented({ stages: ['alignment', 'gone'], ms: 4.21 })
    render(<Pipelines />)

    expect(figure('Stereo', /^Alignment/)).toBe('4.2 ms')
    expect(brackets()).toHaveLength(0)
  })

  it('shows no time on a step timed alone in a run that has none', () => {
    segmented({ stages: ['alignment'], ms: null })
    render(<Pipelines />)

    expect(figure('Stereo', /^Alignment/)).toBeNull()
    expect(screen.getByRole('button', { name: /^Alignment/ }).getAttribute('aria-label')).not.toContain('ms')
  })

  it("shows the accelerator's own time under an Inference step's time, on its tags' line", () => {
    const road = group('road.inference', 'Inference', 102, { pipeline: 'road' })
    useParameters.setState({ groups: [...groups, road] })
    useStatus.setState({
      snapshot: {
        npu: { kind: 'Hexagon', state: 'running', loadPercent: 40, pipelines: { detection: { inferenceMs: 2.14 }, road: { inferenceMs: null } } },
        pipelines: {
          detection: { totalMs: 10.3, stages: { inference: 10.33 }, segments: [] },
          road: { totalMs: null, stages: { inference: null }, segments: [] }
        }
      }
    })
    render(<Pipelines />)

    expect(figure('Detection', /^Inference/)).toBe('10.3 ms')
    expect(acceleratorFigure('Detection', /^Inference/)).toBe('NPU 2.1 ms')
    const accelerator = box('Detection', /^Inference/).querySelector('[data-accelerator]')
    expect(accelerator.parentElement.querySelector('[data-tag]').textContent).toBe('NPU')
    expect(accelerator.className).toContain('ml-auto')
    expect(accelerator.className).toContain('text-ovcs-muted')
    expect(box('Detection', /^Inference/).getAttribute('aria-label')).toBe('Inference, on NPU, Rust, 10.3 ms, NPU 2.1 ms')
    expect(figure('Road', /^Inference/)).toBeNull()
    expect(acceleratorFigure('Road', /^Inference/)).toBeNull()
  })

  it("shows the accelerator's time alone while the step has none", () => {
    useStatus.setState({
      snapshot: { npu: { kind: 'Hexagon', state: 'running', loadPercent: 40, pipelines: { detection: { inferenceMs: 21.54 } } } }
    })
    render(<Pipelines />)

    expect(figure('Detection', /^Inference/)).toBeNull()
    expect(acceleratorFigure('Detection', /^Inference/)).toBe('NPU 21.5 ms')
    expect(figure('Stereo', /^Match/)).toBeNull()
  })

  it("shows each pipeline's total at the end of its heading's row, once the unit reports one", () => {
    useStatus.setState({
      snapshot: {
        npu: null,
        pipelines: { stereo: { totalMs: 28.44, stages: {}, segments: [] }, detection: { totalMs: null, stages: {}, segments: [] } }
      }
    })
    render(<Pipelines />)

    const heading = screen.getByRole('heading', { name: 'Stereo 28.4 ms' })
    const total = heading.querySelector('[data-total]')
    expect(total.textContent).toBe('28.4 ms')
    expect(total.className).toContain('ml-auto')
    expect(total.className).toContain('tabular-nums')
    expect(screen.getByRole('heading', { name: 'Detection' }).querySelector('[data-total]')).toBeNull()
    expect(screen.getByRole('list', { name: 'Stereo' })).toBeTruthy()
  })

  it('shows no time without a status', () => {
    useStatus.setState({ snapshot: null })
    render(<Pipelines />)

    expect(document.body.textContent).not.toContain('ms')
    expect(document.querySelectorAll('[data-total], [data-time], [data-accelerator], [data-run], [data-latency]')).toHaveLength(0)
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

  it('lists a camera of its own as a pipeline of one box, and still the greyed detection line without a detector', () => {
    useParameters.setState({
      groups: [
        group('cameras', 'Cameras', 1, { role: 'source' }),
        group('center.camera', 'Camera', 50, { pipeline: 'center', role: 'source' })
      ]
    })
    render(<Pipelines />)

    expect(within(screen.getByRole('list', { name: 'Center' })).getAllByRole('button')).toHaveLength(1)
    expect(screen.getByText('No detector on this unit')).toBeTruthy()
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
