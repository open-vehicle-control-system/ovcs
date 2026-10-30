import { cx } from './styles.js'

/** A row that lights up while `live` and fades back after. */
export default function OvcsRow({ live = false, as: Tag = 'div', className, children, ...props }) {
  return (
    <Tag className={cx('ovcs-row', live && 'ovcs-row--live', className)} {...props}>
      {children}
    </Tag>
  )
}
