import { render } from '@testing-library/react'
import { describe, expect, test } from 'vitest'
import { OvcsBadge, OvcsCard, OvcsDot, OvcsHeader, OvcsRow, OvcsStatus } from './index.js'

const classesOf = (element) => [...element.classList]

describe('OvcsStatus', () => {
  test('renders its label with the tone modifier', () => {
    const { container } = render(<OvcsStatus tone="ok">Connected</OvcsStatus>)
    expect(container.firstChild.textContent).toBe('Connected')
    expect(classesOf(container.firstChild)).toEqual(['ovcs-status', 'ovcs-status--ok'])
  })

  test('is muted without a tone', () => {
    const { container } = render(<OvcsStatus />)
    expect(classesOf(container.firstChild)).toEqual(['ovcs-status'])
  })
})

describe('OvcsBadge', () => {
  test('renders its label with the tone modifier', () => {
    const { container } = render(<OvcsBadge tone="warn">stale</OvcsBadge>)
    expect(container.firstChild.textContent).toBe('stale')
    expect(classesOf(container.firstChild)).toEqual(['ovcs-badge', 'ovcs-badge--warn'])
  })

  test('is neutral without a tone', () => {
    const { container } = render(<OvcsBadge />)
    expect(classesOf(container.firstChild)).toEqual(['ovcs-badge'])
  })
})

describe('OvcsDot', () => {
  test('is on only while `on` is set', () => {
    const { container, rerender } = render(<OvcsDot />)
    expect(classesOf(container.firstChild)).toEqual(['ovcs-dot'])
    rerender(<OvcsDot on />)
    expect(classesOf(container.firstChild)).toEqual(['ovcs-dot', 'ovcs-dot--on'])
  })
})

describe('OvcsCard', () => {
  test('is a div by default and a link with href', () => {
    expect(render(<OvcsCard>x</OvcsCard>).container.firstChild.tagName).toBe('DIV')
    const link = render(<OvcsCard href="#vms" />).container.firstChild
    expect(link.tagName).toBe('A')
    expect(link.getAttribute('href')).toBe('#vms')
    expect(classesOf(link)).toContain('ovcs-card')
  })

  test('renders as another element and keeps extra classes', () => {
    const card = render(<OvcsCard as="section" className="p-0" />).container.firstChild
    expect(card.tagName).toBe('SECTION')
    expect(classesOf(card)).toEqual(['ovcs-card', 'p-0'])
  })
})

describe('OvcsHeader', () => {
  test('renders a header around its content', () => {
    const { container } = render(
      <OvcsHeader>
        <h1>OVCS</h1>
      </OvcsHeader>
    )
    expect(container.firstChild.tagName).toBe('HEADER')
    expect(container.querySelector('h1').textContent).toBe('OVCS')
  })
})

describe('OvcsRow', () => {
  test('lights up while live', () => {
    const { container, rerender } = render(<OvcsRow as="li" />)
    expect(container.firstChild.tagName).toBe('LI')
    expect(classesOf(container.firstChild)).toEqual(['ovcs-row'])
    rerender(<OvcsRow as="li" live />)
    expect(classesOf(container.firstChild)).toEqual(['ovcs-row', 'ovcs-row--live'])
  })
})
