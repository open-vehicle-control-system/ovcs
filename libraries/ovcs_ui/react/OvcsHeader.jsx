import { cx } from './styles.js'

/** The page's sticky top bar. */
export default function OvcsHeader({ className, children, ...props }) {
  return (
    <header className={cx('ovcs-header', className)} {...props}>
      {children}
    </header>
  )
}
