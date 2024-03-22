<template>
<img :src="[leftDoorsAssets[leftScore]]" class="w-40 text-center inline-block"/>
<img :src="[rightDoorsAssets[rightScore]]" class="w-40 text-center inline-block"/>
</template>

<script setup>
import {ref} from 'vue'

const props = defineProps(["metrics"])
const store = props.metrics
const leftDoorsAssets = {
    0: "./all_closed_left.png",
    1: "./front_left_open.png",
    2: "./rear_left_open.png",
    3: "./all_open_left.png"
}

const rightDoorsAssets = {
    0: "./all_closed_right.png",
    1: "./front_right_open.png",
    2: "./rear_right_open.png",
    3: "./all_open_right.png"
}

let leftScore = ref(0)
let rightScore = ref(0)

const computeDoorsScore = function(state) {
    const leftDoors = {"front_left_door_open": 1, "rear_left_door_open": 2}
    const rightDoors = {"front_right_door_open": 1, "rear_right_door_open": 2}

    let leftDoorsStatuses = store.metrics.filter((metric) => {
        return metric.id == "front_left_door_open" || metric.id == "rear_left_door_open"
    })

    let rightDoorsStatuses = store.metrics.filter((metric) => {
        return metric.id == "front_right_door_open" || metric.id == "rear_right_door_open"
    })

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

    console.log(leftScore.value)
    console.log(rightScore.value)
}

store.$subscribe((_mutation, state) => {
    console.log("changed")
    computeDoorsScore(state)
})
</script>