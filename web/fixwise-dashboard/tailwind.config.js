/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        fixwise: {
          orange: '#FF6B35',
          dark: '#1a1a2e',
          blue: '#2B6CB0',
          teal: '#00D4AA',
        },
      },
    },
  },
  plugins: [],
};
