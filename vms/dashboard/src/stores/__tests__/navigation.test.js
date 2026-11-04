import { describe, it, expect, beforeEach } from 'vitest'
import { listenToHistory, pathOf, routeOf, useNavigation } from '../navigation.js'

const pages = [
  { id: 'status', name: 'Status' },
  { id: 'drive', name: 'Drive' }
]

describe('navigation', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/')
    useNavigation.setState({ path: '/' })
  })

  it('routes / to the first page, /<id> to that page and /network to the network page', () => {
    expect(routeOf('/', pages)).toBe('status')
    expect(routeOf('/drive', pages)).toBe('drive')
    expect(routeOf('/network', pages)).toBe('network')
  })

  it('routes an unknown path to the first page', () => {
    expect(routeOf('/nope', pages)).toBe('status')
  })

  it('routes a malformed path to the first page', () => {
    expect(routeOf('/%E0%A4%A', pages)).toBe('status')
  })

  it('has no route without pages, but the network page', () => {
    expect(routeOf('/', [])).toBe(null)
    expect(routeOf('/drive', null)).toBe(null)
    expect(routeOf('/network', [])).toBe('network')
  })

  it('routes a path with a trailing slash to its page', () => {
    expect(routeOf('/drive/', pages)).toBe('drive')
    expect(routeOf('/network/', pages)).toBe('network')
  })

  it('serves the first page at / and the others at /<id>', () => {
    expect(pathOf('status', pages)).toBe('/')
    expect(pathOf('drive', pages)).toBe('/drive')
    expect(pathOf('network', pages)).toBe('/network')
  })

  it('pushes a new history entry when going to a page', () => {
    const before = window.history.length
    useNavigation.getState().go('/drive')
    expect(window.location.pathname).toBe('/drive')
    expect(window.history.length).toBe(before + 1)
    expect(useNavigation.getState().path).toBe('/drive')
  })

  it('follows the browser back and forward buttons', () => {
    const stop = listenToHistory()
    window.history.replaceState(null, '', '/drive')
    window.dispatchEvent(new PopStateEvent('popstate'))
    expect(useNavigation.getState().path).toBe('/drive')

    stop()
    window.history.replaceState(null, '', '/network')
    window.dispatchEvent(new PopStateEvent('popstate'))
    expect(useNavigation.getState().path).toBe('/drive')
  })
})
