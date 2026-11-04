/** The firmware the gateway runs on: `revision`, `target`, `nervesSystem`, `nervesSystemVersion` and `vehicle`. */
export async function fetchFirmware() {
  const response = await fetch('/api/firmware', { headers: { Accept: 'application/vnd.api+json' } })
  if (!response.ok) throw new Error(`GET /api/firmware: ${response.status}`)
  return (await response.json()).data.attributes
}
