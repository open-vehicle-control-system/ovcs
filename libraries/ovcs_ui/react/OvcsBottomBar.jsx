import { classNames } from './styles.js'

/**
 * The page's bottom bar, under the `OvcsShellBody`: the list of statuses, each an `OvcsBottomBarItem`, spread evenly
 * over its width and wrapping on a narrow screen. On a laptop it stays at the screen's foot; on a narrow screen it ends
 * the page.
 */
export default function OvcsBottomBar({ className, children, ...props }) {
  return (
    <footer className={classNames('ovcs-footer flex min-h-10 shrink-0 items-center px-4 py-2 text-sm lg:px-6', className)} {...props}>
      <ul aria-label="Status" className="flex flex-1 flex-wrap items-center justify-between gap-x-6 gap-y-1">
        {children}
      </ul>
    </footer>
  )
}

/** One status: its `label`, saying what it is about, then its value as `children`, such as an `OvcsStatus`. */
export function OvcsBottomBarItem({ label, className, children, ...props }) {
  return (
    <li className={classNames('flex items-center gap-2', className)} {...props}>
      <span className="flex items-center gap-1 text-ovcs-muted">{label}</span>
      {children}
    </li>
  )
}
