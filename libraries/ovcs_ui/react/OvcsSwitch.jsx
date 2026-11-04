import { FOCUS, classNames } from './styles.js'

/**
 * An on/off switch named by `label`. Its position is `checked` alone: a click calls `onClick`, and the switch moves
 * when the caller changes `checked`.
 */
export default function OvcsSwitch({ checked = false, label, className, ref, ...props }) {
  return (
    <button
      ref={ref}
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      className={classNames(
        'inline-flex w-9 shrink-0 rounded-full p-0.5 transition-colors disabled:cursor-not-allowed disabled:opacity-50',
        checked ? 'bg-ovcs-accent' : 'bg-ovcs-border',
        FOCUS,
        className
      )}
      {...props}
    >
      <span
        aria-hidden="true"
        className={classNames(
          'size-4 rounded-full bg-ovcs-surface shadow transition-transform',
          checked ? 'translate-x-4' : 'translate-x-0'
        )}
      />
    </button>
  )
}
