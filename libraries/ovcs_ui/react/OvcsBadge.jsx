import { cx } from './styles.js'

/** A short label set in capitals; `tone` is `neutral` (default), `warn` or `error`. */
export default function OvcsBadge({ tone = 'neutral', className, children, ...props }) {
  return (
    <span className={cx('ovcs-badge', tone !== 'neutral' && `ovcs-badge--${tone}`, className)} {...props}>
      {children}
    </span>
  )
}
