<template>
        <img :src="[leftDoorsAssets[leftScore]]" class="w-1/3 text-center inline-block"/>
        <img :src="[rightDoorsAssets[rightScore]]" class="w-1/3 text-center inline-block"/>
</template>

<script setup>
import {onMounted, ref} from 'vue'

const props = defineProps(["store"])
const store = props.store
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

const computeDoorsScore = function(state) {
    const leftDoors = {"front_left_door_open": 1, "rear_left_door_open": 2}
    const rightDoors = {"front_right_door_open": 1, "rear_right_door_open": 2}

    let leftDoorsStatuses = [
        store.getValueById("front_left_door_open"),
        store.getValueById("rear_left_door_open")
    ]

    let rightDoorsStatuses = [
        store.getValueById("front_right_door_open"),
        store.getValueById("rear_right_door_open")
    ]

    leftScore.value = 0
    rightScore.value = 0

    leftDoorsStatuses.forEach((door) => {
        if(door == true){
            leftScore.value += leftDoors[door.id]
        }
    })

    rightDoorsStatuses.forEach((door) => {
        if(door == true){
            rightScore.value += rightDoors[door.id]
        }
    })
}

store.$subscribe((_mutation, state) => {
    computeDoorsScore(state)
})
</script>