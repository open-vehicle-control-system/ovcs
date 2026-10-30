import { cx } from './styles.js'

/** A small accent dot, shown while `on`; it keeps its space when off so rows stay aligned. */
export default function OvcsDot({ on = false, className, ...props }) {
  return <span className={cx('ovcs-dot', on && 'ovcs-dot--on', className)} aria-hidden="true" {...props} />
}
