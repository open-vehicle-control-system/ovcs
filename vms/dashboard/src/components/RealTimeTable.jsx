import { ButtonAction, NumberAction, ToggleAction, useActionPost } from './ActionControls.jsx'
import MetricValue from './MetricValue.jsx'

const ACTION_CONTROLS = { button: ButtonAction, number: NumberAction, toggle: ToggleAction }

function Label({ row, error }) {
  return (
    <th scope="row" className="py-2 pr-3 text-left align-middle font-normal">
      <span className="block whitespace-nowrap font-semibold">{row.name}</span>
      {row.hint ? <span className="mt-0.5 block max-w-xs text-xs text-ovcs-muted">{row.hint}</span> : null}
      {error ? <span className="mt-0.5 block text-xs text-ovcs-error-text">{error}</span> : null}
    </th>
  )
}

function MetricRow({ row }) {
  return (
    <tr>
      <Label row={row} />
      <td className="py-2 text-right align-middle">
        <MetricValue row={row} />
      </td>
    </tr>
  )
}

function ActionRow({ row }) {
  const action = useActionPost(row)
  const Control = ACTION_CONTROLS[row.inputType]

  return (
    <tr>
      <Label row={row} error={action.error} />
      <td className="py-2 text-right align-middle">{Control ? <Control row={row} action={action} /> : null}</td>
    </tr>
  )
}

/** A table block: one row per metric or action, each under its name. */
export default function RealTimeTable({ block }) {
  return (
    <table className="w-full text-sm">
      <tbody className="divide-y divide-ovcs-border">
        {block.rows.map((row, index) =>
          row.type === 'action' ? <ActionRow key={index} row={row} /> : <MetricRow key={index} row={row} />
        )}
      </tbody>
    </table>
  )
}
