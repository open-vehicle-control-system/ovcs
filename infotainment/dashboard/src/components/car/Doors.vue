<template>
        <img :src="leftDoorsAssets[props.leftScore]" class="w-1/3 text-center inline-block"/>
        <img :src="rightDoorsAssets[props.rightScore]" class="w-1/3 text-center inline-block"/>
</template>

<script setup>
const props = defineProps(["leftScore", "rightScore"])

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
</script>