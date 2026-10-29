const base = () => import.meta.env.VITE_BASE_URL + '/api/parameters'

export async function fetchParameters() {
  const response = await fetch(base())
  if (!response.ok) throw new Error(`GET /api/parameters: ${response.status}`)
  return (await response.json()).parameters
}

// The value in force, or an Error with the reason the value was refused.
export async function setParameter(name, value) {
  const response = await fetch(`${base()}/${encodeURIComponent(name)}`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ value })
  })
  const body = await response.json()
  if (!response.ok) throw new Error(body.error ?? `PUT /api/parameters/${name}: ${response.status}`)
  return body.value
}
