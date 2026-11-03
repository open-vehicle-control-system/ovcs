import { classNames } from './styles.js'

const TEXT_COLOURS = { ok: 'text-ovcs-ok-text', warn: 'text-ovcs-warn-text', error: 'text-ovcs-error-text' }

/**
 * A coloured dot followed by its label; `tone` is `ok`, `warn`, `error` or `muted` (default). The label takes the
 * tone's text colour, which reads on the light surfaces where the tone's own colour is too light.
 */
export default function OvcsStatus({ tone = 'muted', className, children, ...props }) {
  return (
    <span className={classNames('ovcs-status', tone !== 'muted' && `ovcs-status--${tone}`, TEXT_COLOURS[tone], className)} {...props}>
      {children}
    </span>
  )
}
