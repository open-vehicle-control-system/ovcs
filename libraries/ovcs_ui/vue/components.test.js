import { mount } from '@vue/test-utils'
import { describe, expect, test } from 'vitest'
import { OvcsBadge, OvcsCard, OvcsDot, OvcsHeader, OvcsRow, OvcsStatus } from './index.js'

describe('OvcsStatus', () => {
  test('renders its label with the tone modifier', () => {
    const status = mount(OvcsStatus, { props: { tone: 'ok' }, slots: { default: 'Connected' } })
    expect(status.text()).toBe('Connected')
    expect(status.classes()).toEqual(['ovcs-status', 'ovcs-status--ok'])
  })

  test('is muted without a tone', () => {
    expect(mount(OvcsStatus).classes()).toEqual(['ovcs-status'])
  })

  test('rejects an unknown tone', () => {
    expect(OvcsStatus.props.tone.validator('blue')).toBe(false)
  })
})

describe('OvcsBadge', () => {
  test('renders its label with the tone modifier', () => {
    const badge = mount(OvcsBadge, { props: { tone: 'warn' }, slots: { default: 'stale' } })
    expect(badge.text()).toBe('stale')
    expect(badge.classes()).toEqual(['ovcs-badge', 'ovcs-badge--warn'])
  })

  test('is neutral without a tone', () => {
    expect(mount(OvcsBadge).classes()).toEqual(['ovcs-badge'])
  })
})

describe('OvcsDot', () => {
  test('is on only while `on` is set', async () => {
    const dot = mount(OvcsDot)
    expect(dot.classes()).toEqual(['ovcs-dot'])
    await dot.setProps({ on: true })
    expect(dot.classes()).toEqual(['ovcs-dot', 'ovcs-dot--on'])
  })
})

describe('OvcsCard', () => {
  test('is a div by default and a link with href', () => {
    expect(mount(OvcsCard, { slots: { default: 'x' } }).element.tagName).toBe('DIV')
    const link = mount(OvcsCard, { props: { href: '#vms' } })
    expect(link.element.tagName).toBe('A')
    expect(link.attributes('href')).toBe('#vms')
    expect(link.classes()).toContain('ovcs-card')
  })

  test('renders as another element and keeps extra classes', () => {
    const card = mount(OvcsCard, { props: { as: 'section' }, attrs: { class: 'p-0' } })
    expect(card.element.tagName).toBe('SECTION')
    expect(card.classes()).toEqual(['ovcs-card', 'p-0'])
  })
})

describe('OvcsHeader', () => {
  test('renders a header around its content', () => {
    const header = mount(OvcsHeader, { slots: { default: '<h1>OVCS</h1>' } })
    expect(header.element.tagName).toBe('HEADER')
    expect(header.find('h1').text()).toBe('OVCS')
  })
})

describe('OvcsRow', () => {
  test('lights up while live', async () => {
    const row = mount(OvcsRow, { props: { as: 'li' } })
    expect(row.element.tagName).toBe('LI')
    expect(row.classes()).toEqual(['ovcs-row'])
    await row.setProps({ live: true })
    expect(row.classes()).toEqual(['ovcs-row', 'ovcs-row--live'])
  })
})
