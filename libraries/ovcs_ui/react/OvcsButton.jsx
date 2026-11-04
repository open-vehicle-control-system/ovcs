import { FOCUS, classNames } from './styles.js'

const BUTTON = `min-h-9 rounded border border-ovcs-border px-3 text-sm enabled:hover:border-ovcs-accent disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`

const VARIANTS = {
  default: '',
  primary: 'enabled:border-ovcs-accent font-semibold'
}

/** An outlined button that never submits a form; `variant` is `default` or `primary`, the action a view leads to. */
export default function OvcsButton({ variant = 'default', className, ref, children, ...props }) {
  return (
    <button ref={ref} type="button" className={classNames(BUTTON, VARIANTS[variant], className)} {...props}>
      {children}
    </button>
  )
}
