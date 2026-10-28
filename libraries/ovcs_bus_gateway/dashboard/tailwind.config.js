import ovcsPreset from '@ovcs/ui/tailwind-preset'

/** @type {import('tailwindcss').Config} */
export default {
  presets: [ovcsPreset],
  content: ['./index.html', './src/**/*.{vue,js}']
}
