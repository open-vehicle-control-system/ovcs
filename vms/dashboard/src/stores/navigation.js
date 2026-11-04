import { create } from 'zustand'

/** The route of the dashboard's own Network page, which shadows a vehicle page of the same id. */
export const NETWORK = 'network'

/** The route a path shows: the Network page, a page by its id, the first page for `/` or an unknown path. */
export function routeOf(pathname, pages) {
  if (!pages?.length) return null
  if (pathname === `/${NETWORK}`) return NETWORK
  const id = decoded(pathname.slice(1))
  return pages.some((page) => page.id === id) ? id : pages[0].id
}

// A malformed escape matches no page.
function decoded(segment) {
  try {
    return decodeURIComponent(segment)
  } catch {
    return null
  }
}

/** The path a route lives at: `/` for the first page. */
export function pathOf(route, pages) {
  if (route === NETWORK) return `/${NETWORK}`
  return route === pages?.[0]?.id ? '/' : `/${encodeURIComponent(route)}`
}

export const useNavigation = create((set) => ({
  path: window.location.pathname,
  go(path) {
    window.history.pushState(null, '', path)
    set({ path })
  }
}))

/** Follows the browser's back and forward buttons until the returned function is called. */
export function listenToHistory() {
  const follow = () => useNavigation.setState({ path: window.location.pathname })
  window.addEventListener('popstate', follow)
  return () => window.removeEventListener('popstate', follow)
}
