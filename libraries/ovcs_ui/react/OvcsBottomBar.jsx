import { classNames } from './styles.js'

/**
 * The page's bottom bar, under the `OvcsShellBody`: the list of statuses, each an `OvcsBottomBarItem`, spread evenly
 * over its width, in two columns on a narrow screen. On a laptop it stays at the screen's foot; on a narrow screen it ends
 * the page.
 */
export default function OvcsBottomBar({ className, children, ...props }) {
  return (
    <footer className={classNames('ovcs-footer flex min-h-10 shrink-0 items-center px-4 py-2 text-sm lg:px-6', className)} {...props}>
      <ul
        aria-label="Status"
        className="flex flex-1 flex-wrap items-center justify-between gap-x-6 gap-y-1 max-lg:grid max-lg:grid-cols-2 max-lg:items-start max-lg:gap-x-4 max-lg:gap-y-2"
      >
        {children}
      </ul>
    </footer>
  )
}

/** One status: its `label`, saying what it is about, then its value as `children`, such as an `OvcsStatus`; on a narrow screen the label over the value. */
export function OvcsBottomBarItem({ label, className, children, ...props }) {
  return (
    <li
      className={classNames(
        'flex items-center gap-2 whitespace-nowrap max-lg:flex-col max-lg:items-start max-lg:gap-0.5',
        className
      )}
      {...props}
    >
      <span className="flex items-center gap-1 text-ovcs-muted max-lg:text-xs">{label}</span>
      {children}
    </li>
  )
}
