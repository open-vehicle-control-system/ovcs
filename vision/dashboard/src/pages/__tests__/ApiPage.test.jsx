import { describe, it, expect } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import ApiPage from '../ApiPage.jsx'

describe('ApiPage', () => {
  it('heads the columns of the resources and of the channels', () => {
    render(<ApiPage />)

    const [resources, channels] = screen.getAllByRole('table')
    const headers = (table) => within(table).getAllByRole('columnheader').map((header) => header.textContent)
    expect(headers(resources)).toEqual(['method', 'path', 'answer'])
    expect(headers(channels)).toEqual(['topic', 'carries'])
  })
})
