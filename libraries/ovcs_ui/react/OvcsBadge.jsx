import { cx } from './styles.js'

/** A short label set in capitals; the word "uppercase" stays out of this file, Tailwind's content scan reads it as a class. `tone` is `neutral` (default), `warn` or `error`. */
export default function OvcsBadge({ tone = 'neutral', className, children, ...props }) {
  return (
    <span className={cx('ovcs-badge', tone !== 'neutral' && `ovcs-badge--${tone}`, className)} {...props}>
      {children}
    </span>
  )
}
