import { createApp } from 'vue'
// Before the app's styles, so Tailwind utilities override the shared components.
import '@ovcs/ui/vue'
import './style.css'
import App from './App.vue'

createApp(App).mount('#app')
