<template>
    <div class="text-3xl text-white grid grid-rows-4 h-full p-4">
        <div @click="requestGear('parking')" :class="[store.selectedGear == 'parking' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">P</span>
        </div>
        <div @click="requestGear('reverse')" :class="[store.selectedGear == 'reverse' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">R</span>
        </div>
        <div @click="requestGear('neutral')" :class="[store.selectedGear == 'neutral' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">N</span>
        </div>
        <div @click="requestGear('drive')" :class="[store.selectedGear == 'drive' ? 'bg-gray-700 opacity-99 rounded rounded-3xl' : '', 'text-center p-8']">
            <span class="h-20 w-20 leading-5 align-middle">D</span>
        </div>
    </div>
</template>

<script setup>
import axios from 'axios'

const props = defineProps(["store"])
const store = props.store

const requestGear = function(gear){
    axios.post(import.meta.env.VITE_BASE_URL + "/api/gear-selector", {gear: gear}).then((response) => {
    })
}

</script>