import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'

const css = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'tokens.css'), 'utf8')

// The custom properties of the rule opening with `selector {`.
function tokens(selector) {
  const start = css.indexOf(`${selector} {`)
  const body = css.slice(start, css.indexOf('}', start))
  return Object.fromEntries([...body.matchAll(/(--ovcs-[\w-]+):\s*([^;]+);/g)].map(([, name, value]) => [name, value.trim()]))
}

// WCAG 2's contrast ratio between two `#rrggbb` colours.
function contrast(first, second) {
  const luminance = (hex) => {
    const [red, green, blue] = [1, 3, 5].map((index) => {
      const channel = parseInt(hex.slice(index, index + 2), 16) / 255
      return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
    })
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
  }
  const [lighter, darker] = [luminance(first), luminance(second)].sort((a, b) => b - a)
  return (lighter + 0.05) / (darker + 0.05)
}

const colours = ['ok', 'warn', 'error', 'accent'].map((name) => ({ name }))

describe('tokens.css', () => {
  test.each(colours)('--ovcs-$name-text reads on both light surfaces, at AA', ({ name }) => {
    const light = tokens(':root')
    for (const surface of ['--ovcs-surface', '--ovcs-bg']) {
      expect(contrast(light[`--ovcs-${name}-text`], light[surface])).toBeGreaterThanOrEqual(4.5)
    }
  })

  test.each(colours)('--ovcs-$name-text is --ovcs-$name in dark mode', ({ name }) => {
    for (const selector of [':root:not([data-theme="light"])', '[data-theme="dark"]']) {
      expect(tokens(selector)[`--ovcs-${name}-text`]).toBe(`var(--ovcs-${name})`)
    }
  })
})
