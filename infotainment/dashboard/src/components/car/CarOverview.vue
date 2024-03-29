<template>
    <div class="text-center pt-4">
        <Doors :store="store"></Doors>
    </div>
    <div class="grid grid-cols-4 text-center pl-4 pr-6">
        <div class="p-8"><IconEngine :engineStatus="engineStatus"></IconEngine></div>
        <div class="p-6"><IconTrunk :trunkOpen="trunkOpen"></IconTrunk></div>
        <div class="p-8"><IconBeams :beamsActive="beamsActive"></IconBeams></div>
        <div class="p-8"><IconHandbrake :handbrakeEngaged="handbrakeEngaged"></IconHandbrake></div>
    </div>
</template>

<script setup>
import {onMounted, ref} from 'vue'
import IconBeams from '../icons/IconBeams.vue'
import IconHandbrake from '../icons/IconHandbrake.vue'
import IconEngine from '../icons/IconEngine.vue'
import IconTrunk from '../icons/IconTrunk.vue'
import Doors from "./Doors.vue"

const props = defineProps(["metrics"])
const store = props.metrics

let trunkOpen = ref(false)
let beamsActive = ref(false)
let handbrakeEngaged = ref(false)
let engineStatus = ref("off")

const checkEngineStatus = function(state) {
    let readyToDrive =  store.getValueById("ready_to_drive")
    let vmsStatus = store.getValueById("status")

    if(vmsStatus != "failure" && readyToDrive){
        engineStatus.value = "ready"
    } else if (vmsStatus != "failure" && !readyToDrive){
        engineStatus.value = "warning"
    } else if (vmsStatus == "failure"){
        engineStatus.value = "error"
    } else {
        engineStatus.value = "off"
    }
}

store.$subscribe((_mutation, state) => {
    trunkOpen.value = store.getValueById("trunk_door_open")
    beamsActive.value = store.getValueById("beam_active")
    handbrakeEngaged.value = store.getValueById("handbrake_engaged")
    checkEngineStatus(state)
})
</script>