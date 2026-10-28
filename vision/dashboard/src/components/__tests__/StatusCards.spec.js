import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import StatusCards from '../StatusCards.vue'

const snapshot = {
  cameras: { left: { present: true, fps: 29.6, exposure_time_us: 8000, analogue_gain: 2.0 }, right: { present: false } },
  sync: { present: true, offset_median_ms: 0.12, offset_max_ms: 0.4, pairs: 150 },
  hailo: 'absent',
  depth_hz: 12.8,
  zenoh: 'disconnected'
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

  it('waits for the first status', () => {
    const wrapper = mount(StatusCards, { props: { status: null } })

    expect(wrapper.text()).toContain('Waiting')
  })
})
