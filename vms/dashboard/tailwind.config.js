/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{vue,js,ts,jsx,tsx}'],
  theme: {
    extend: {
      keyframes: {
        blinkingBg: {
            '0%, 100%': { backgroundColor: '#f87171' },
            '50%': { backgroundColor: '#fecaca' },
        }
        },
      animation: {
          blinkingBg: 'blinkingBg 2s ease-in-out infinite',
      }
    },
  },
  safelist: [
    {
      pattern: /bg-(orange|red|blue|indigo|gray|green|amber|rose|teal)-(200|600|700)/,
      variants: ['lg', 'hover', 'focus', 'lg:hover'],
    },
    {
      pattern: /text-(orange|red|blue|indigo|gray|green|amber|rose|teal)-(200|600|700)/,
    }
  ],
  plugins: [
    import('@tailwindcss/forms'),
  ],
}

