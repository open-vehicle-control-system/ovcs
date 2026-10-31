import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import Menu from '../Menu.jsx'
import { useParameters } from '../../stores/parameters.js'
import { useNavigation } from '../../stores/navigation.js'

vi.mock('../../services/parameters.js')

const group = (id, name, position, role) => ({ id, name, summary: '', role, position, status: null, parameterIds: [] })

describe('Menu', () => {
  beforeEach(() => {
    useParameters.setState({
      groups: [group('detection', 'Detection', 101, 'branch'), group('cameras', 'Cameras', 0, 'source')],
      parameters: {},
      selectedGroupId: null
    })
    useNavigation.setState({ page: 'overview' })
  })

  it('lists the components beside the pipeline in the Main section, under its pages', () => {
    render(<Menu />)

    const main = screen.getByRole('region', { name: 'Main' })
    expect(within(main).getByRole('button', { name: /^Detection/ })).toBeTruthy()
    expect(within(main).getByRole('button', { name: 'Overview' })).toBeTruthy()

    const pipeline = screen.getByRole('region', { name: 'Pipeline' })
    expect(within(pipeline).queryByRole('button', { name: /^Detection/ })).toBeNull()
    expect(screen.queryByText('Beside the pipeline')).toBeNull()
  })
})
