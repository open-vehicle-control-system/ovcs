import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import StatusCards from '../StatusCards.vue'

const snapshot = {
  cameras: { left: { present: true, fps: 29.6, exposure_time_us: 8000, analogue_gain: 2.0 }, right: { present: false } },
  sync: { present: true, offset_median_ms: 0.12, offset_max_ms: 0.4, pairs: 150 },
  hailo: 'absent',
  depth_hz: 12.8,
  zenoh: 'disconnected',
  cpu_percent: 37.25,
  stereo_segment_percent: 81.5,
  alignment: { offset_rows: -1.43, band_offset_rows: [-1.9, -1.6, -1.2, -1.0] },
  sharpness: { left: 0.0312, right: 0.0218 }
}

describe('StatusCards', () => {
  it('shows Hailo absent', () => {
    const wrapper = mount(StatusCards, { props: { status: snapshot } })

    expect(wrapper.get('[data-card="hailo"]').text()).toContain('absent')
  })

  it('shows each camera, the depth rate and Zenoh', () => {
    const wrapper = mount(StatusCards, { props: { status: snapshot } })

    expect(wrapper.get('[data-card="left"]').text()).toContain('29.6')
    expect(wrapper.get('[data-card="right"]').text()).toContain('absent')
    expect(wrapper.get('[data-card="depth"]').text()).toContain('12.8')
    expect(wrapper.get('[data-card="zenoh"]').text()).toContain('disconnected')
  })

  it('shows the CPU usage and the stereo segment time', () => {
    const wrapper = mount(StatusCards, { props: { status: snapshot } })

    expect(wrapper.get('[data-card="cpu"]').text()).toContain('37 %')
    expect(wrapper.get('[data-card="segment"]').text()).toContain('82 %')
  })

  it('shows the row alignment, overall and from left to right', () => {
    const wrapper = mount(StatusCards, { props: { status: snapshot } })
    const card = wrapper.get('[data-card="alignment"]')

    expect(card.text()).toContain('-1.4 rows')
    expect(card.text()).toContain('-1.9 · -1.6 · -1.2 · -1.0')
    expect(card.find('.text-red-700').exists()).toBe(true)
  })

  it('shows an alignment within half a row as healthy', () => {
    const aligned = { ...snapshot, alignment: { offset_rows: 0.2, band_offset_rows: [0.1, 0.2, 0.2, 0.3] } }
    const card = mount(StatusCards, { props: { status: aligned } }).get('[data-card="alignment"]')

    expect(card.find('.text-green-700').exists()).toBe(true)
  })

  it('shows an alignment not yet measured as a dash', () => {
    const wrapper = mount(StatusCards, { props: { status: { ...snapshot, alignment: null } } })

    expect(wrapper.get('[data-card="alignment"]').text()).toContain('–')
  })

  it("compares the cameras' sharpness, right to left", () => {
    const card = mount(StatusCards, { props: { status: snapshot } }).get('[data-card="sharpness"]')

    expect(card.text()).toContain('0.70')
    expect(card.text()).toContain('left 0.0312 · right 0.0218')
    expect(card.find('.text-red-700').exists()).toBe(true)
  })

  it('shows matching sharpness as healthy', () => {
    const matched = { ...snapshot, sharpness: { left: 0.03, right: 0.028 } }
    const card = mount(StatusCards, { props: { status: matched } }).get('[data-card="sharpness"]')

    expect(card.find('.text-green-700').exists()).toBe(true)
  })

  it('shows an unknown CPU usage as a dash', () => {
    const wrapper = mount(StatusCards, { props: { status: { ...snapshot, cpu_percent: null } } })

    expect(wrapper.get('[data-card="cpu"]').text()).toContain('–')
  })

  it('waits for the first status', () => {
    const wrapper = mount(StatusCards, { props: { status: null } })

    expect(wrapper.text()).toContain('Waiting')
  })
})
