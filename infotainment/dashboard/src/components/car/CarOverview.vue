<template>
    <div class="text-center pt-4">
        <Doors :leftScore="leftScore" :rightScore="rightScore"></Doors>
    </div>
    <div class="grid grid-cols-4 text-center pl-4 pr-6">
        <div class="p-8"><IconEngine :engineStatus="engineStatus"></IconEngine></div>
        <div class="p-6"><IconTrunk :trunkOpen="trunkOpen"></IconTrunk></div>
        <div class="p-8"><IconBeams :beamsActive="beamsActive"></IconBeams></div>
        <div class="p-8"><IconHandbrake :handbrakeEngaged="handbrakeEngaged"></IconHandbrake></div>
    </div>
</template>

<script setup>
import {ref} from 'vue'
import IconBeams from '../icons/IconBeams.vue'
import IconHandbrake from '../icons/IconHandbrake.vue'
import IconEngine from '../icons/IconEngine.vue'
import IconTrunk from '../icons/IconTrunk.vue'
import Doors from "./Doors.vue"
import { infotainmentSocket } from '../../services/socket_service.js'
import axios from 'axios'

const refreshIntervalms = 1000
let engineStatus = ref("off")
let trunkOpen = ref(false)
let beamsActive = ref(false)
let handbrakeEngaged = ref(false)

let leftDoorsStatuses = ref([false, false])
let rightDoorsStatuses = ref([false, false])

let leftScore = ref(0)
let rightScore = ref(0)

const leftDoors = [1, 2]
const rightDoors = [1, 2]

const overviewToRefs = function(overview) {
    engineStatus.value = overview.vms_status.value
    trunkOpen.value = overview.trunk_door_open.value
    beamsActive.value = overview.beam_active.value
    handbrakeEngaged.value = overview.handbrake_engaged.value

    leftDoorsStatuses.value = [
        overview.front_left_door_open.value,
        overview.rear_left_door_open.value
    ]

    rightDoorsStatuses.value = [
        overview.front_right_door_open.value,
        overview.rear_right_door_open.value
    ]

    leftDoorsStatuses.value.forEach((door, index) => {
        if(door == true){
            leftScore.value += leftDoors[index]
        }
    })

    rightDoorsStatuses.value.forEach((door, index) => {
        if(door == true){
            rightScore.value += rightDoors[index]
        }
    })
}

await axios.get(import.meta.env.VITE_BASE_URL + "/api/car-overview").then((response) => {
    overviewToRefs(response.data)
})

let carOverviewChannel = infotainmentSocket.channel("car-overview", {interval: refreshIntervalms})
carOverviewChannel.on("updated", payload => {
    overviewToRefs(payload)
})
carOverviewChannel.join().receive("ok", () => {})
</script>