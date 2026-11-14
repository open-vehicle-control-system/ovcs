import { FOCUS, classNames } from './styles.js'

const BUTTON = `min-h-9 rounded border border-ovcs-border px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`

const VARIANTS = {
  default: 'enabled:hover:border-ovcs-accent',
  primary: 'enabled:border-ovcs-accent enabled:hover:border-ovcs-accent font-semibold',
  danger: 'enabled:border-ovcs-error text-ovcs-error-text font-semibold'
}

/**
 * An outlined button that never submits a form; `variant` is `default`, `primary`, the action a view leads to, or
 * `danger`, an action that destroys something.
 */
export default function OvcsButton({ variant = 'default', className, ref, children, ...props }) {
  return (
    <button ref={ref} type="button" className={classNames(BUTTON, VARIANTS[variant], className)} {...props}>
      {children}
    </button>
  )
}
