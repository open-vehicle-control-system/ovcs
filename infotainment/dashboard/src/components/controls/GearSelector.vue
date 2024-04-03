<template>
    <div class="text-3xl text-white grid grid-rows-4 h-full p-4">
        <div @click="requestGear('parking')" :class="[selectedGear == 'parking' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">P</span>
        </div>
        <div @click="requestGear('reverse')" :class="[selectedGear == 'reverse' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">R</span>
        </div>
        <div @click="requestGear('neutral')" :class="[selectedGear == 'neutral' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">N</span>
        </div>
        <div @click="requestGear('drive')" :class="[selectedGear == 'drive' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">D</span>
        </div>
    </div>
</template>

<script setup>
import axios from 'axios'
import { ref } from 'vue'
import { infotainmentSocket } from '../../services/socket_service.js'

const refreshIntervalms = 500

let selectedGear = ref("parking")
let gearChannel = infotainmentSocket.channel("gear", {interval: refreshIntervalms})

gearChannel.on("updated", payload => {
    selectedGear.value = payload["gear"]
})

gearChannel.join()
    .receive("ok", () => {})

const requestGear = function(gear){
    axios.post(import.meta.env.VITE_BASE_URL + "/api/gear-selector", {gear: gear}).then((response) => {
    })
}

</script>