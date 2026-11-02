import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import Menu from '../Menu.jsx'
import { useParameters } from '../../stores/parameters.js'
import { useNavigation } from '../../stores/navigation.js'

vi.mock('../../services/parameters.js')

const group = (id, name, position, pipeline, role = 'step') => ({
  id, name, summary: '', pipeline, role, position, status: null, parameterIds: []
})

describe('Menu', () => {
  beforeEach(() => {
    useParameters.setState({
      groups: [group('detection.input', 'Input', 101, 'detection'), group('cameras', 'Cameras', 0, 'stereo', 'source')],
      parameters: {},
      selectedGroupId: null
    })
    useNavigation.setState({ page: 'overview' })
  })

  it("lists the unit's pages in Main, each pipeline's steps in Pipelines and the exporters last", () => {
    render(<Menu />)

    const main = screen.getByRole('region', { name: 'Main' })
    expect(within(main).getAllByRole('button').map((button) => button.textContent)).toEqual(['Overview', 'Calibration'])

    const pipelines = screen.getByRole('region', { name: 'Pipelines' })
    expect(within(within(pipelines).getByRole('list', { name: 'Stereo' })).getByRole('button', { name: 'Cameras' })).toBeTruthy()
    expect(within(within(pipelines).getByRole('list', { name: 'Detection' })).getByRole('button', { name: /^Input/ })).toBeTruthy()

    const exporters = screen.getByRole('region', { name: 'Exporters' })
    expect(within(exporters).getAllByRole('button').map((button) => button.textContent)).toEqual(['ROS 2', 'API'])
  })

  it('shows the detection pipeline greyed, with nothing to select, on a unit without a detector', () => {
    useParameters.setState({ groups: [group('cameras', 'Cameras', 0, 'stereo', 'source')] })
    render(<Menu />)

    const pipelines = screen.getByRole('region', { name: 'Pipelines' })
    expect(within(pipelines).getByText('No detector on this unit')).toBeTruthy()
    expect(within(pipelines).queryByRole('button', { name: /Detection/ })).toBeNull()
  })
})
