import './assets/main.css'

import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { PiniaSocketChannelPlugin } from './lib/pinia_socket_channel_plugin.js'

import App from './App.vue'
import router from './router'

import VueApexCharts from "vue3-apexcharts";

const app = createApp(App)
const pinia = createPinia()
pinia.use(PiniaSocketChannelPlugin)
app.use(pinia)
app.use(VueApexCharts);
app.use(router)


app.mount('#app')
