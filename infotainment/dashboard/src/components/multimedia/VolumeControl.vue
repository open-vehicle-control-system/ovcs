<template>
    <div class="">
        <div class="p-3">
          <IconVolumeUp @click="volumeUp"></IconVolumeUp>
        </div>
        <div class="w-full">
          <div class="container h-60 w-auto m-auto">
            <div class="barcontainer h-60 m-auto">
              <div class="bar mx-auto" id="volumeBar">
              </div>
            </div>
          </div>
        </div>
        <div class="p-3 pt-8">
          <IconVolumeDown @click="volumeDown"></IconVolumeDown>
        </div>
    </div>
</template>

<script setup>
import IconVolumeUp from '../icons/IconVolumeUp.vue'
import IconVolumeDown from '../icons/IconVolumeDown.vue'
import axios from 'axios'

import { onMounted, ref } from 'vue'

let volumeLevel = ref("")

const getVolumeLevel = function(){
  axios.get(import.meta.env.VITE_BASE_URL + "/api/volume").then((response) => {
  })
}

const volumeUp = function(){
    console.log("volume up")
}

const volumeDown = function(){
    console.log("volume down")
}

onMounted(() => {
  getVolumeLevel()
})
</script>

<style scoped>
.barcontainer{
  background-color: #374151;
  position: relative;
  width: 24px;
}

.bar{
  background-color: #06b6d4;
  position: absolute;
  bottom: 0;
  width: 24px;
  height: v-bind(volumeLevel);
  box-sizing: border-box;
  animation: grow 1.5s ease-out forwards;
  transform-origin: bottom;
}
</style>