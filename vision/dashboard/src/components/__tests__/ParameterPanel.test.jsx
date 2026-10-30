import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ParameterPanel from '../ParameterPanel.jsx'
import { useParameters } from '../../stores/parameters.js'

vi.mock('../../services/parameters.js')

const range = (min, max) => ({ kind: 'range', min, max, step: null })

const parameter = (id, extra = {}) => ({
  id,
  name: id.split('.').pop(),
  type: 'integer',
  constraint: range(0, 255),
  applies: 'live',
  description: '',
  default: 8,
  value: 8,
  saved: 8,
  state: 'builtin',
  group: 'stereo.match',
  controller: null,
  greaterThan: null,
  ...extra
})

const parameters = {
  'stereo.match.p1': parameter('stereo.match.p1'),
  'stereo.match.p2': parameter('stereo.match.p2', { constraint: range(1, 256), value: 64, default: 64, greaterThan: 'stereo.match.p1' }),
  'stereo.match.uniqueness': parameter('stereo.match.uniqueness', { type: 'double', constraint: range(1, 3), value: 1.2, default: 1.2 }),
  'cameras.auto_exposure': parameter('cameras.auto_exposure', { name: 'auto exposure', type: 'bool', constraint: { kind: 'bool' }, value: true, default: true, group: 'cameras' }),
  'cameras.exposure_us': parameter('cameras.exposure_us', { name: 'exposure', state: 'automatic', controller: 'cameras.auto_exposure', value: 8000, default: 10000, group: 'cameras' })
}

const groups = [
  { id: 'cameras', name: 'Cameras', summary: 'Capture both images', kind: 'component', placement: 'flow', position: 1, status: null, parameterIds: ['cameras.auto_exposure', 'cameras.exposure_us'] },
  { id: 'stereo.match', name: 'Match', summary: 'Find each pixel in the other image', kind: 'stage', placement: 'flow', position: 3, status: null, parameterIds: ['stereo.match.p1', 'stereo.match.p2', 'stereo.match.uniqueness'] }
]

const actions = () => ({ set: vi.fn(), reset: vi.fn(), beginEdit: vi.fn(), endEdit: vi.fn() })

describe('ParameterPanel', () => {
  let stubs
  beforeEach(() => {
    stubs = actions()
    useParameters.setState({ groups, parameters, ...stubs })
  })

  it("shows the group's name, summary and a control per parameter", () => {
    render(<ParameterPanel groupId="stereo.match" />)

    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()
    expect(screen.getByText('Find each pixel in the other image')).toBeTruthy()
    expect(screen.getAllByRole('slider')).toHaveLength(3)
  })

  it('bounds p2 below by p1 and p1 above by p2', () => {
    render(<ParameterPanel groupId="stereo.match" />)

    expect(screen.getByRole('slider', { name: 'p2' }).getAttribute('min')).toBe('9')
    expect(screen.getByRole('slider', { name: 'p1' }).getAttribute('max')).toBe('63')
    expect(screen.getByRole('slider', { name: 'uniqueness' }).getAttribute('max')).toBe('3')
  })

  it('bounds doubles by their step', () => {
    useParameters.setState({
      parameters: {
        ...parameters,
        'stereo.match.p1': parameter('stereo.match.p1', { type: 'double', constraint: range(0, 10), value: 2 }),
        'stereo.match.p2': parameter('stereo.match.p2', { type: 'double', constraint: range(0, 10), value: 5, greaterThan: 'stereo.match.p1' })
      }
    })
    render(<ParameterPanel groupId="stereo.match" />)

    expect(screen.getByRole('slider', { name: 'p2' }).getAttribute('min')).toBe('2.1')
    expect(screen.getByRole('slider', { name: 'p1' }).getAttribute('max')).toBe('4.9')
  })

  it('sets a value, wrapping the drag in an edit', () => {
    render(<ParameterPanel groupId="stereo.match" />)
    const slider = screen.getByRole('slider', { name: 'p1' })

    fireEvent.pointerDown(slider)
    fireEvent.change(slider, { target: { value: '10' } })
    fireEvent.pointerUp(slider)

    expect(stubs.beginEdit).toHaveBeenCalledWith('stereo.match.p1')
    expect(stubs.set).toHaveBeenCalledWith('stereo.match.p1', 10)
    expect(stubs.endEdit).toHaveBeenCalledWith('stereo.match.p1')
  })

  it('resets a parameter and the group', () => {
    useParameters.setState({ parameters: { ...parameters, 'stereo.match.p1': parameter('stereo.match.p1', { value: 12, state: 'unsaved' }) } })
    render(<ParameterPanel groupId="stereo.match" />)

    fireEvent.click(screen.getByRole('button', { name: 'Reset p1' }))
    expect(stubs.reset).toHaveBeenCalledWith({ type: 'parameters', id: 'stereo.match.p1' })

    fireEvent.click(screen.getByRole('button', { name: 'Reset Match' }))
    expect(stubs.reset).toHaveBeenCalledWith({ type: 'parameter-groups', id: 'stereo.match' })
  })

  it('names the controller of an automatic parameter', () => {
    render(<ParameterPanel groupId="cameras" />)

    expect(screen.getByText(/set by auto exposure/)).toBeTruthy()
  })

  it('summarises the values in one polite live region', () => {
    const { container } = render(<ParameterPanel groupId="stereo.match" />)

    const regions = container.querySelectorAll('[aria-live]')
    expect(regions).toHaveLength(1)
    expect(regions[0].getAttribute('aria-live')).toBe('polite')
    expect(regions[0].textContent).toBe('p1 8, p2 64, uniqueness 1.2')
  })

  it('asks you to choose a box when none is selected', () => {
    render(<ParameterPanel groupId={null} />)

    expect(screen.getByText(/Choose a box/)).toBeTruthy()
  })
})
