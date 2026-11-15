import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import PairStatus from '../PairStatus.jsx'

describe('PairStatus', () => {
  it('goes under both previews on a narrow screen, two checks a row, leaving the previews the width', () => {
    render(<PairStatus status={null} />)

    const pair = screen.getByRole('list', { name: 'Camera pair' })
    expect(pair.className.split(' ')).toEqual(
      expect.arrayContaining(['max-md:col-span-2', 'max-md:row-start-4', 'max-md:w-full', 'max-md:grid', 'max-md:grid-cols-2'])
    )
  })
})
