<template>
  <div class="lg:fixed lg:inset-y-0 lg:flex lg:w-60">
    <!-- Sidebar component, swap this element with another sidebar if you like -->
    <div class="flex grow flex-col gap-y-5 overflow-y-auto bg-indigo-600 px-6 pb-4">
      <div class="flex h-16 shrink-0 items-center">
        <p class="text-xl text-white">OVCS VMS</p>
      </div>
      <nav class="flex flex-1 flex-col">
        <ul role="list" class="flex flex-1 flex-col gap-y-7">
          <li>
            <ul role="list" class="-mx-2 space-y-1">
              <li v-for="item in navigation" :key="item.name">
                <a :href="item.href" :class="[item.current ? 'bg-indigo-700 text-white' : 'text-indigo-200 hover:text-white hover:bg-indigo-700', 'group flex gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold']">
                  <component :is="item.icon" :class="[item.current ? 'text-white' : 'text-indigo-200 group-hover:text-white', 'h-6 w-6 shrink-0']" aria-hidden="true" />
                  {{ item.name }}
                </a>
              </li>
            </ul>
          </li>
        </ul>
      </nav>
    </div>
  </div>

  <div class="lg:pl-60">
    <main class="py-10">
      <div class="px-4 sm:px-6 lg:px-8">
        <RouterView />
      </div>
    </main>
  </div>
</template>

<script setup>
  import { RouterView } from 'vue-router'
  import { useRouter } from 'vue-router'

  import { ref } from 'vue'
  import {
    HomeIcon,
    ExclamationCircleIcon,
    ArrowPathIcon,
    WifiIcon,
    Battery50Icon,
    ChevronUpDownIcon,
  } from '@heroicons/vue/24/outline'
import { ChevronDoubleRightIcon } from '@heroicons/vue/20/solid';

  let router = useRouter()
  let currentRouteName = router.options.history.location
  let navigation = [
    { name: 'Dashboard', href: '/', icon: HomeIcon, current: currentRouteName == '/' },
    { name: 'Networks', href: '/networks', icon: WifiIcon, current: currentRouteName == '/networks' },
    { name: 'Throttle', href: '/throttle', icon: ChevronDoubleRightIcon, current: currentRouteName == '/throttle' },
    { name: 'Steering', href: '/steering', icon: ArrowPathIcon, current: currentRouteName == '/steering' },
    { name: 'Braking', href: '/braking', icon: ExclamationCircleIcon, current: currentRouteName == '/braking' },
    { name: 'Gear', href: '/gear', icon: ChevronUpDownIcon, current: currentRouteName == '/gear'},
    { name: 'Energy', href: '/energy', icon: Battery50Icon, current: currentRouteName == '/energy'}
  ]
</script>