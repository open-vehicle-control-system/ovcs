import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import ApiPage from '../ApiPage.jsx'
import { useParameters } from '../../stores/parameters.js'

vi.mock('../../services/parameters.js')

const group = (id, position, parameterIds) => ({ id, name: id, role: 'step', position, parameterIds })

describe('ApiPage', () => {
  beforeEach(() => useParameters.setState({ groups: [] }))

  it("links one parameter, the first of the unit's", () => {
    useParameters.setState({ groups: [group('stereo.match', 2, ['stereo.match.p1']), group('cameras', 1, ['cameras.exposure_us'])] })
    render(<ApiPage />)

    const link = screen.getByRole('link', { name: '/api/parameters/cameras.exposure_us' })
    expect(link.getAttribute('href')).toMatch(/\/api\/parameters\/cameras\.exposure_us$/)
  })

  it('shows the path of one parameter without a link until the parameters are loaded', () => {
    render(<ApiPage />)

    const row = screen.getByRole('row', { name: /One parameter$/ })
    expect(within(row).getByText('/api/parameters/{id}')).toBeTruthy()
    expect(screen.queryByRole('link', { name: /^\/api\/parameters\// })).toBeNull()
  })

  it('heads the columns of the resources and of the channels', () => {
    render(<ApiPage />)

    const [resources, channels] = screen.getAllByRole('table')
    const headers = (table) => within(table).getAllByRole('columnheader').map((header) => header.textContent)
    expect(headers(resources)).toEqual(['method', 'path', 'answer'])
    expect(headers(channels)).toEqual(['topic', 'carries'])
  })

  it('lists the exporters, and says nothing of the unit but how to reach it', () => {
    render(<ApiPage />)

    expect(screen.getByRole('row', { name: /\/api\/exporters/ }).textContent).toContain('status')
    expect(screen.queryByText(/besides ROS 2/)).toBeNull()
  })
})
