<script setup>
import { ref, onBeforeMount, onBeforeUnmount, onMounted } from 'vue'
import {RouterView } from 'vue-router'
import { useRouter } from 'vue-router'
import {
  BugAntIcon,
  Squares2X2Icon,
  RadioIcon,
  CogIcon,
  HomeIcon
} from '@heroicons/vue/24/outline'

import VolumeControl from './components/multimedia/VolumeControl.vue'

let router = useRouter()
let currentRouteName = router.options.history.location

const navigation = [
  //{ name: 'Radio', href: '/radio', icon: RadioIcon, color: "bg-red-400", current: currentRouteName == '/radio' },
  //{ name: 'Settings', href: '/settings', icon: CogIcon, color: "bg-amber-400", current: currentRouteName == '/settings' },
  { name: 'Debug', href: '/debug', icon: BugAntIcon,  color: "bg-green-400", current: currentRouteName == '/debug' },
]

let currentTime = ref("")
let currentDate = ref("")

function setCurrentTime(){
  currentTime.value = new Date().toLocaleString("fr-BE", {timeStyle: "short"});
  currentDate.value = new Date().toLocaleString("fr-BE", {dateStyle: "short"});
}

onBeforeMount(() => {
  setCurrentTime();
  setInterval(setCurrentTime, 1000);
})

onBeforeUnmount(() => {
  clearInterval(timer);
})
</script>

<template>
  <div class="geometric-bg">
    <div class="fixed inset-y-0 z-50 flex w-51 grow">
      <!-- Sidebar component, swap this element with another sidebar if you like -->
      <div class="grid  grid-rows-9 bg-gray-900 px-4">
        <div class="pt-12 items-center row-span-2">
          <p class="text-2xl text-center text-white">{{ currentTime }}</p>
          <p  class="text-md text-center text-white">{{ currentDate }}</p>
        </div>
        <div class="row-span-6">
          <!--<VolumeControl></VolumeControl>-->
        </div>
        <div class="p-3">
          <a :href="[ currentRouteName == '/launchpad' ? '/' : '/launchpad']" class="text-sm font-semibold inline-block align-bottom">
            <Squares2X2Icon class="text-white h-16 w-16" />
          </a>
        </div>
      </div>
    </div>

    <main class="pl-32 overflow-y-auto">
      <div class="py-8 px-8 h-full">
        <RouterView :navigation="navigation" />
      </div>
    </main>
  </div>
</template>

<style scoped>
.geometric-bg {
    background-image: url("/images/launchpad_background.svg");
    height: 100%;

    /* Center and scale the image nicely */
    /* background-position: center; */
    background-repeat: repeat;
    background-size: cover;
}

main {
  height: 100vh;
}
</style>
