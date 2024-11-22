import './assets/main.css'

import { createApp, ref } from 'vue'
import { createPinia } from 'pinia'
import { PiniaSocketChannelPlugin } from './lib/pinia_socket_channel_plugin.js'
import VehiculeService from "./services/vehicle_service.js"
import DynamicView from './views/DynamicView.vue'

import App from './App.vue'
import router from './router'

const app = createApp(App)
const pinia = createPinia()
pinia.use(PiniaSocketChannelPlugin)
app.use(pinia)

let refreshInterval = ref()

VehiculeService.getVehicle().then((response) => {
    refreshInterval.value = response.data.data.attributes.refreshInterval
});

VehiculeService.getVehiclePages().then((response) => {
    let pages = response.data.data
    pages.forEach((page) => {
        let href = pages.indexOf(page) === 0 ? "/" : "/" + page.id
        router.addRoute({
            component: DynamicView,
            name: page.id,
            path: href,
            props: {
                title: page.attributes.name,
                id: page.id,
                refreshInterval: refreshInterval
            }
        })
    });
    app.use(router)
    app.mount('#app')
});
