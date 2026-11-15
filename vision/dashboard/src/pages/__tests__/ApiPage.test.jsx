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

  it("lists a camera of its own's preview channel, and each pipeline's channel", () => {
    render(<ApiPage />)

    const topics = within(screen.getAllByRole('table')[1]).getAllByRole('row').slice(1).map((row) => row.cells[0].textContent)
    expect(topics).toEqual([
      'status',
      'preview:<prefix>/left, preview:<prefix>/right',
      'preview:<name>',
      'preview:<prefix>/depth',
      'detections:<name>',
      'segmentation:<name>'
    ])
    expect(screen.getByRole('row', { name: /^detections:<name> / }).textContent).not.toContain('left image')
  })

  it('says the status channel carries what the status bar shows', () => {
    render(<ApiPage />)

    const status = screen.getByRole('row', { name: /^status / })
    expect(status.textContent).toContain('status bar')
    expect(status.textContent).not.toContain('top bar')
  })

  it('lists every route the API serves', () => {
    render(<ApiPage />)

    const routes = within(screen.getAllByRole('table')[0])
      .getAllByRole('row')
      .slice(1)
      .map((row) => `${row.cells[0].textContent} ${row.cells[1].textContent}`)
    expect(routes).toEqual(
      expect.arrayContaining([
        'GET /api/board',
        'GET /api/calibrations/{id}',
        'GET /api/saved-calibrations?filter[calibration]={id}',
        'PATCH /api/saved-calibrations/{id}',
        'DELETE /api/saved-calibrations/{id}',
        'POST /api/exporters/{id}/actions/{name}',
        'POST /api/recordings',
        'PATCH /api/recordings/{id}',
        'DELETE /api/recordings/{id}',
        'PATCH /api/disks/{id}'
      ])
    )
  })

  it('lists the exporters, and says nothing of the unit but how to reach it', () => {
    render(<ApiPage />)

    expect(screen.getByRole('row', { name: /^GET \/api\/exporters What/ }).textContent).toContain('outputs')
    expect(screen.getByRole('row', { name: /^GET \/api\/recordings\?include=parts / }).textContent).toContain('parts')
    expect(screen.getByRole('row', { name: /^GET \/api\/disks / }).textContent).toContain('order')
    expect(screen.queryByText(/besides ROS 2/)).toBeNull()
  })
})
