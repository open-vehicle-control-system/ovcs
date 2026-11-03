// Before the app's styles, so Tailwind utilities override the shared components.
import '@ovcs/ui/tokens.css'
import '@ovcs/ui/components.css'
import './style.css'

import { createRoot } from 'react-dom/client'
import App from './App.jsx'

createRoot(document.getElementById('app')).render(<App />)
