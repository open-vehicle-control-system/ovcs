import { cx } from './styles.js'

/** A bordered block on the surface colour; a link when `href` is set. */
export default function OvcsCard({ href, as: Tag = 'div', className, children, ...props }) {
  if (href) {
    return (
      <a href={href} className={cx('ovcs-card', className)} {...props}>
        {children}
      </a>
    )
  }
  return (
    <Tag className={cx('ovcs-card', className)} {...props}>
      {children}
    </Tag>
  )
}
