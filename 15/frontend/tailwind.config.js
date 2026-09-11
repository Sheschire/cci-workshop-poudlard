/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './src/pages/**/*.{js,ts,jsx,tsx,mdx}',
    './src/components/**/*.{js,ts,jsx,tsx,mdx}',
    './src/app/**/*.{js,ts,jsx,tsx,mdx}'
  ],
  theme: {
    extend: {
      colors: {
        hedwige: {
          50: '#f5f7fa',
          100: '#ebeef3',
          200: '#d3dbe5',
          300: '#acbccf',
          400: '#8097b3',
          500: '#607a9a',
          600: '#4c6280',
          700: '#3f5068',
          800: '#374457',
          900: '#313b4a',
          950: '#202630'
        }
      }
    }
  },
  plugins: []
};
