import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import Parameters from '../Parameters.vue'

const parameters = [
  { name: 'stereo.p1', type: 'integer', value: 8, read_only: false, range: [0, 78], description: 'Penalty' },
  { name: 'stereo.uniqueness', type: 'double', value: 1.05, read_only: false, range: [1, 3] },
  { name: 'stereo.left.auto_exposure', type: 'bool', value: true, read_only: false },
  { name: 'stereo.width', type: 'integer', value: 480, read_only: true }
]

describe('Parameters', () => {
  it('shows the writable parameters within their range, grouped by prefix', () => {
    const wrapper = mount(Parameters, { props: { parameters, save: vi.fn() } })
    const p1 = wrapper.get('[data-parameter="stereo.p1"] input')

    expect(p1.attributes('min')).toBe('0')
    expect(p1.attributes('max')).toBe('78')
    expect(p1.element.value).toBe('8')
    expect(wrapper.find('[data-parameter="stereo.width"]').exists()).toBe(false)
    expect(wrapper.get('[data-group="stereo.left"]').text()).toContain('auto_exposure')
  })

  it('saves a changed value with its type', async () => {
    const save = vi.fn().mockResolvedValue(5)
    const wrapper = mount(Parameters, { props: { parameters, save } })

    await wrapper.get('[data-parameter="stereo.p1"] input').setValue('5')
    await wrapper.get('[data-parameter="stereo.left.auto_exposure"] input').setValue(false)

    expect(save).toHaveBeenCalledWith('stereo.p1', 5)
    expect(save).toHaveBeenCalledWith('stereo.left.auto_exposure', false)
  })

  it('shows why a value was refused and puts the value in force back', async () => {
    const save = vi.fn().mockRejectedValue(new Error('p2 must exceed p1, got 70 and 64'))
    const wrapper = mount(Parameters, { props: { parameters, save } })
    const input = wrapper.get('[data-parameter="stereo.p1"] input')

    await input.setValue('70')
    await flushPromises()

    expect(wrapper.get('[data-parameter="stereo.p1"]').text()).toContain('p2 must exceed p1')
    expect(input.element.value).toBe('8')
  })
})
