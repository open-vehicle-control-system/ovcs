import { cx } from './styles.js'

/** A coloured dot followed by its label; `tone` is `ok`, `warn`, `error` or `muted` (default). */
export default function OvcsStatus({ tone = 'muted', className, children, ...props }) {
  return (
    <span className={cx('ovcs-status', tone !== 'muted' && `ovcs-status--${tone}`, className)} {...props}>
      {children}
    </span>
  )
}
