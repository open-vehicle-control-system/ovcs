const REVOKE_DELAY_MS = 10000

/** Saves `blob` as `filename` through the browser's download. */
export function downloadFile(blob, filename) {
  const href = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = href
  link.download = filename
  link.click()
  // Some browsers start the download after the click returns.
  setTimeout(() => URL.revokeObjectURL(href), REVOKE_DELAY_MS)
}
