import './assets/main.css'

import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { PiniaSocketChannelPlugin } from './lib/pinia_socket_channel_plugin.js'

import App from './App.vue'
import router from './router'

const app = createApp(App)
const pinia = createPinia()
pinia.use(PiniaSocketChannelPlugin)
app.use(pinia)
app.use(router)


app.mount('#app')
