<script setup>
import { ref, onBeforeMount, onBeforeUnmount } from 'vue'
import {RouterView } from 'vue-router'
import { useRouter } from 'vue-router'
import {
  BugAntIcon,
  Squares2X2Icon,
  RadioIcon,
  CogIcon
} from '@heroicons/vue/24/outline'

let router = useRouter()
let currentRouteName = router.options.history.location

const navigation = [
  //{ name: 'Radio', href: '/radio', icon: RadioIcon, current: currentRouteName == '/radio' },
  //{ name: 'Settings', href: '/settings', icon: CogIcon, current: currentRouteName == '/settings' },
  { name: 'Debug', href: '/debug', icon: BugAntIcon, current: currentRouteName == '/debug' },
]

let currentTime = ref("")

function setCurrentTime(){
  currentTime.value = new Date().toLocaleString("fr-BE");
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
    <div class="lg:pl-32 dark:bg-gray-800 opacity-60 text-gray-900 dark:text-gray-400"><h3 id="clock" class="text-xl text-center">{{ currentTime }}</h3></div>
    <!-- Static sidebar for desktop -->
    <div class="lg:fixed lg:inset-y-0 lg:z-50 lg:flex lg:w-51 lg:flex-col">
      <!-- Sidebar component, swap this element with another sidebar if you like -->
      <div class="flex grow flex-col gap-y-5 bg-indigo-600 dark:bg-gray-900 px-6">
        <div class="flex h-1 items-center">
        </div>
        <nav class="flex flex-1 flex-col">
          <ul role="list" class="flex flex-1 flex-col gap-y-7">
          </ul>
          <div>
            <a href="/" class="group flex gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold">
              <Squares2X2Icon class="text-white h-20 w-16" />
            </a>
          </div>
        </nav>
      </div>
    </div>

    <main class="py-8 lg:pl-32 overflow-y-auto">
      <div class="sm:px-6 lg:px-8">
        <RouterView :navigation="navigation" />
      </div>
    </main>
  </div>
</template>

<style scoped>
.geometric-bg {
    background-image: url("./launchpad_background.svg");
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
