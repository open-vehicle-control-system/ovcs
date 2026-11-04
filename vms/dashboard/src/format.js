/** A row's own unit, else the one its publisher gave. */
export const unitOf = (row, publisherUnit) => row.unit ?? publisherUnit

/** A number, or a string holding one: decimals arrive as strings. */
export const isNumeric = (value) =>
  typeof value === 'number' || (typeof value === 'string' && value.trim() !== '' && !Number.isNaN(Number(value)))

/** A metric value as a row shows it; booleans are drawn as icons instead. */
export function displayValue(value, row, publisherUnit) {
  if (value === null || value === undefined) return row.placeholder ?? '—'
  if (isNumeric(value)) {
    const unit = unitOf(row, publisherUnit)
    // A fraction of a full range reads as a percentage.
    if (unit === 'fraction') return `${Math.round(Number(value) * 1000) / 10} %`
    const rounded = Math.round(Number(value) * 100) / 100
    return unit == null ? String(rounded) : `${rounded} ${unit}`
  }
  if (Array.isArray(value)) return value.join(', ')
  if (typeof value === 'object') return JSON.stringify(value, null, 2)
  return String(value)
}

export const isMultiline = (value) => typeof value === 'string' && value.includes('\n')

/** The live value behind an action row, as its "now" badge and number field show it. */
export function liveValue(value) {
  if (value === null || value === undefined) return ''
  return typeof value === 'number' ? String(Math.round(value * 10000) / 10000) : String(value)
}

/** The body of an action row's request: its module and action, its extra parameters, and `value` as a string if any. */
export function actionBody(row, value) {
  const body = { module: row.module, action: row.action, ...row.extraParameters }
  if (value !== undefined && value !== null && value !== '') body.value = String(value)
  return body
}
