import { useEffect, useId, useRef } from 'react'

import { useOvcsMenu } from './menu.js'
import { FOCUS, MENU_HEADING, MENU_SELECTED, classNames } from './styles.js'

// Where the menu shows on each screen, from the shell's state; outside a shell it always shows.
function visibility(menu) {
  if (!menu) return 'flex'
  return classNames(menu.phoneOpen ? 'max-lg:flex' : 'max-lg:hidden', menu.laptopShown ? 'lg:flex' : 'lg:hidden')
}

/**
 * The page's navigation, named by `label`, which the `OvcsTopBar`'s Menu button shows and hides: beside the main
 * content on a laptop, shown until hidden; on a narrower screen under the top bar, hidden until opened, the current
 * entry in view, and closed once an entry is chosen or on Escape.
 */
export default function OvcsMenu({ label, className, children, ...props }) {
  const menu = useOvcsMenu()
  const ref = useRef(null)
  const setPresent = menu?.setPresent
  const phoneOpen = menu?.phoneOpen ?? false

  useEffect(() => {
    setPresent?.(true)
    return () => setPresent?.(false)
  }, [setPresent])

  useEffect(() => {
    if (phoneOpen) ref.current?.querySelector('[aria-current]')?.scrollIntoView?.({ block: 'nearest' })
  }, [phoneOpen])

  return (
    <nav
      ref={ref}
      id={menu?.id}
      aria-label={label}
      onKeyDown={(event) => {
        if (event.key !== 'Escape' || !phoneOpen) return
        menu.closeOnPhone()
        menu.buttonRef.current?.focus()
      }}
      className={classNames(
        'z-20 shrink-0 flex-col gap-5 bg-ovcs-surface px-3 py-4',
        'max-lg:sticky max-lg:top-[var(--ovcs-top-bar-height,0px)] max-lg:max-h-[calc(100dvh_-_var(--ovcs-top-bar-height,0px))] max-lg:overflow-y-auto max-lg:border-b max-lg:border-ovcs-border',
        'lg:w-56 lg:overflow-y-auto lg:border-r lg:border-ovcs-border',
        visibility(menu),
        className
      )}
      {...props}
    >
      {children}
    </nav>
  )
}

/** A group of menu entries under its `title`, which names it. */
export function OvcsMenuSection({ title, className, children, ...props }) {
  const id = useId()
  return (
    <section aria-labelledby={id} className={classNames('flex flex-col gap-1.5', className)} {...props}>
      <h2 id={id} className={MENU_HEADING}>
        {title}
      </h2>
      {children}
    </section>
  )
}

/** A list of `OvcsMenuItem`s, each in its `li`, named by `label`. */
export function OvcsMenuList({ label, className, children, ...props }) {
  return (
    <ul aria-label={label} className={classNames('flex flex-col gap-1', className)} {...props}>
      {children}
    </ul>
  )
}

/** A menu entry; a `selected` one carries the selection bar and is the current page. Choosing it closes the menu on a phone. */
export function OvcsMenuItem({ selected = false, className, onClick, children, ...props }) {
  const menu = useOvcsMenu()
  return (
    <button
      type="button"
      aria-current={selected ? 'page' : undefined}
      onClick={(event) => {
        onClick?.(event)
        menu?.closeOnPhone()
      }}
      className={classNames(
        'flex min-h-11 w-full items-center gap-2 rounded px-3 text-left text-sm lg:min-h-9',
        selected ? `${MENU_SELECTED} font-medium` : 'hover:bg-ovcs-bg',
        FOCUS,
        className
      )}
      {...props}
    >
      {children}
    </button>
  )
}
