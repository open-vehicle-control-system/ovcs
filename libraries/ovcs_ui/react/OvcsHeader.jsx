import { classNames } from './styles.js'

/** The page's sticky top bar. */
export default function OvcsHeader({ className, children, ...props }) {
  return (
    <header className={classNames('ovcs-header', className)} {...props}>
      {children}
    </header>
  )
}
