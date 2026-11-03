import OvcsHeader from './OvcsHeader.jsx'
import { classNames } from './styles.js'

/** The page's sticky top bar: an `OvcsTopBarTitle`, then an `OvcsTopBarEnd`; its content wraps on a narrow screen. */
export default function OvcsTopBar({ className, children, ...props }) {
  return (
    <OvcsHeader
      className={classNames('flex min-h-14 shrink-0 flex-wrap items-center gap-x-8 gap-y-2 px-4 py-2 lg:px-6', className)}
      {...props}
    >
      {children}
    </OvcsHeader>
  )
}

/** "OVCS" and the `product`'s name as the page's heading, followed by `children`, such as the firmware's revision. */
export function OvcsTopBarTitle({ product, children }) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-3">
      <h1 className="text-lg font-semibold text-ovcs-text">
        OVCS <span className="font-normal text-ovcs-muted">{product}</span>
      </h1>
      {children}
    </div>
  )
}

/** The top bar's end: its status and controls, such as the `OvcsThemeSwitch`. */
export function OvcsTopBarEnd({ className, children, ...props }) {
  return (
    <div className={classNames('ml-auto flex items-center gap-5', className)} {...props}>
      {children}
    </div>
  )
}
