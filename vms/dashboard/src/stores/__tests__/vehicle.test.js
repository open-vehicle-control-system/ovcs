import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useVehicle } from '../vehicle.js'
import { fetchPages, fetchVehicle } from '../../services/api.js'

vi.mock('../../services/api.js')

const vehicle = { name: 'Mini', refreshInterval: 70 }
const pages = [{ id: 'status', name: 'Status' }]

describe('vehicle store', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    useVehicle.setState({ vehicle: null, pages: null, error: null })
  })

  it('loads the vehicle and its pages together', async () => {
    let resolveVehicle
    fetchVehicle.mockReturnValue(new Promise((resolve) => (resolveVehicle = resolve)))
    fetchPages.mockResolvedValue(pages)

    const loading = useVehicle.getState().load()
    expect(fetchVehicle).toHaveBeenCalledTimes(1)
    expect(fetchPages).toHaveBeenCalledTimes(1)

    resolveVehicle(vehicle)
    await loading
    expect(useVehicle.getState()).toMatchObject({ vehicle, pages, error: null })
  })

  it('keeps the error until a retry succeeds', async () => {
    fetchVehicle.mockRejectedValueOnce(new Error('Cannot reach the VMS')).mockResolvedValueOnce(vehicle)
    fetchPages.mockResolvedValue(pages)

    await useVehicle.getState().load()
    expect(useVehicle.getState()).toMatchObject({ vehicle: null, pages: null, error: 'Cannot reach the VMS' })

    await useVehicle.getState().load()
    expect(useVehicle.getState()).toMatchObject({ vehicle, pages, error: null })
  })
})
