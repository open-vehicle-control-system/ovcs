<script setup>
import { VueElement, ref } from 'vue'
import {RouterView } from 'vue-router'
import {
  DocumentMagnifyingGlassIcon,
} from '@heroicons/vue/24/outline'

const navigation = [
  { name: 'Debug', href: '/debug', icon: DocumentMagnifyingGlassIcon, current: true },
]

const sidebarOpen = ref(false)

</script>

<template>
  <div>
    <div class="py-0 lg:pl-32 dark:bg-gray-800 text-indigo-200"><h3 id="clock" class="text-xl text-center">{{ currentTime }}</h3></div>
    <!-- Static sidebar for desktop -->
    <div class="lg:fixed lg:inset-y-0 lg:z-50 lg:flex lg:w-51 lg:flex-col">
      <!-- Sidebar component, swap this element with another sidebar if you like -->
      <div class="flex grow flex-col gap-y-5 overflow-y-auto bg-indigo-600 dark:bg-gray-900 px-6">
        <div class="flex h-1 shrink-0 items-center">
        </div>
        <nav class="flex flex-1 flex-col">
          <ul role="list" class="flex flex-1 flex-col gap-y-7">
            <li>
              <ul role="list" class="-mx-2 space-y-1">
                <li v-for="item in navigation" :key="item.name">
                  <a :href="item.href" :class="[item.current ? 'bg-indigo-700 dark:bg-gray-700 text-white' : 'text-indigo-200 dark:bg-gray-200 hover:text-white hover:bg-indigo-700', 'group flex gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold']">
                    <component :is="item.icon" :class="[item.current ? 'text-white' : 'text-indigo-200 group-hover:text-white', 'h-20 w-20 shrink-0']" aria-hidden="true" />
                  </a>
                </li>
              </ul>
            </li>
          </ul>
        </nav>
      </div>
    </div>

    <main class="py-10 lg:pl-32 dark:bg-gray-800">
      <div class="sm:px-6 lg:px-8">
        <RouterView />
      </div>
    </main>
  </div>
</template>

<script>
const date = new Date();
export default {
  name: "App",
  data() {
    return {
      currentTime: ""
    }
  },
  methods: {
    setCurrentTime() {
      this.currentTime = new Date().toLocaleString("fr-BE");
    }
  },
  beforeMount(){
    this.timer = setInterval(this.setCurrentTime, 1000);
  },
  beforeUnmount(){
    clearInterval(this.timer);
  }
}

</script>
