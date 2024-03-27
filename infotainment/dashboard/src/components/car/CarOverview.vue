<template>
    <div class="text-center pt-4">
        <img :src="[leftDoorsAssets[leftScore]]" class="w-1/3 text-center inline-block"/>
        <img :src="[rightDoorsAssets[rightScore]]" class="w-1/3 text-center inline-block"/>
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

const props = defineProps(["metrics"])
const store = props.metrics
const leftDoorsAssets = {
    0: "/images/all_closed_left.png",
    1: "/images/front_left_open.png",
    2: "/images/rear_left_open.png",
    3: "/images/all_open_left.png"
}

const rightDoorsAssets = {
    0: "/images/all_closed_right.png",
    1: "/images/front_right_open.png",
    2: "/images/rear_right_open.png",
    3: "/images/all_open_right.png"
}

let leftScore = ref(0)
let rightScore = ref(0)
let trunkOpen = ref(false)
let beamsActive = ref(false)
let handbrakeEngaged = ref(false)
let engineStatus = ref("off")

const checkBeams = function(state) {
    beamsActive.value = store.metrics.filter((metric) => {
        return metric.id == "beam_active"
    })[0].attributes.value
}

const checkHandbrake = function(state) {
    handbrakeEngaged.value = store.metrics.filter((metric) => {
        return metric.id == "handbrake_engaged"
    })[0].attributes.value
}

const checkEngineStatus = function(state) {
    let readyToDrive = store.metrics.filter((metric) => {
        return metric.id == "ready_to_drive"
    })[0].attributes.value

    let vmsStatus = store.metrics.filter((metric) => {
        return metric.id == "status"
    })[0].attributes.value

    console.log(readyToDrive)

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

const computeDoorsScore = function(state) {
    const leftDoors = {"front_left_door_open": 1, "rear_left_door_open": 2}
    const rightDoors = {"front_right_door_open": 1, "rear_right_door_open": 2}

    let leftDoorsStatuses = store.metrics.filter((metric) => {
        return metric.id == "front_left_door_open" || metric.id == "rear_left_door_open"
    })

    let rightDoorsStatuses = store.metrics.filter((metric) => {
        return metric.id == "front_right_door_open" || metric.id == "rear_right_door_open"
    })

    trunkOpen.value = store.metrics.filter((metric) => {
        return metric.id == "trunk_door_open"
    })[0].attributes.value

    leftScore.value = 0
    rightScore.value = 0

    leftDoorsStatuses.forEach((door) => {
        if(door.attributes.value == true){
            leftScore.value += leftDoors[door.id]
        }
    })

    rightDoorsStatuses.forEach((door) => {
        if(door.attributes.value == true){
            rightScore.value += rightDoors[door.id]
        }
    })
}

store.$subscribe((_mutation, state) => {
    computeDoorsScore(state)
    checkBeams(state)
    checkHandbrake(state)
    checkEngineStatus(state)
})
</script>

<style scoped>
</style>