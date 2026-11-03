import { useId } from 'react'

import { FOCUS, MENU_HEADING, MENU_SELECTED, classNames } from './styles.js'

/** The page's navigation, named by `label`: beside the main content on a laptop, above it on a narrow screen. */
export default function OvcsMenu({ label, className, children, ...props }) {
  return (
    <nav
      aria-label={label}
      className={classNames(
        'flex shrink-0 flex-col gap-5 border-b border-ovcs-border bg-ovcs-surface px-3 py-4 lg:w-56 lg:overflow-y-auto lg:border-b-0 lg:border-r',
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

/** A menu entry; a `selected` one carries the selection bar and is the current page. */
export function OvcsMenuItem({ selected = false, className, children, ...props }) {
  return (
    <button
      type="button"
      aria-current={selected ? 'page' : undefined}
      className={classNames(
        'flex min-h-9 w-full items-center gap-2 rounded px-3 text-left text-sm',
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
