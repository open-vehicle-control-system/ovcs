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
  plugins: [
    require('@tailwindcss/forms'),
  ],
}

