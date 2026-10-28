import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import Preview from '../Preview.vue'

function fakeSocket() {
  const handlers = {}
  const channel = {
    on: vi.fn((event, handler) => { handlers[event] = handler }),
    join: vi.fn(() => ({ receive: vi.fn() })),
    push: vi.fn(),
    leave: vi.fn()
  }
  return { channel: vi.fn(() => channel), handlers, fakeChannel: channel }
}

describe('Preview', () => {
  it('renders the latest frame', async () => {
    const socket = fakeSocket()
    const wrapper = mount(Preview, { props: { stream: 'left', socket } })

    expect(socket.channel).toHaveBeenCalledWith('preview:left', {})
    socket.handlers.frame({ jpeg: 'Zmlyc3Q=' })
    socket.handlers.frame({ jpeg: 'bGF0ZXN0' })
    await nextTick()

    expect(wrapper.get('img').attributes('src')).toBe('data:image/jpeg;base64,bGF0ZXN0')
  })

  it('acks a frame once the image has loaded or failed', async () => {
    const socket = fakeSocket()
    const wrapper = mount(Preview, { props: { stream: 'left', socket } })

    socket.handlers.frame({ jpeg: 'Zmlyc3Q=' })
    await nextTick()
    expect(socket.fakeChannel.push).not.toHaveBeenCalled()

    await wrapper.get('img').trigger('load')
    expect(socket.fakeChannel.push).toHaveBeenCalledWith('ack', {})

    socket.handlers.frame({ jpeg: 'bGF0ZXN0' })
    await nextTick()
    await wrapper.get('img').trigger('error')
    expect(socket.fakeChannel.push).toHaveBeenCalledTimes(2)
  })

  it('leaves its channel when unmounted', () => {
    const socket = fakeSocket()
    const wrapper = mount(Preview, { props: { stream: 'depth', socket } })

    wrapper.unmount()

    expect(socket.fakeChannel.leave).toHaveBeenCalled()
  })
})
