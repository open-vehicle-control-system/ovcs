export async function fetchSettings() {
  const response = await fetch(import.meta.env.VITE_BASE_URL + "/api/settings")
  if (!response.ok) throw new Error(`GET /api/settings: ${response.status}`)
  return response.json()
}
