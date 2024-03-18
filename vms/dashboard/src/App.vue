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
      <div class="sticky top-0 z-40 flex h-16 shrink-0 items-center gap-x-4 border-b border-gray-200 bg-white px-4 shadow-sm sm:gap-x-6 sm:px-6 lg:px-8">
      </div>
      <div>
        <main class="py-10">
          <div class="px-4 sm:px-6 lg:px-8">
            <RouterView />
          </div>
        </main>
      </div>
    </div>
</template>

<script setup>
  import { RouterView } from 'vue-router'
  import { useRouter } from 'vue-router'

  import { ref } from 'vue'
  import {
    HomeIcon,
    GlobeAltIcon,
    AdjustmentsVerticalIcon,
  } from '@heroicons/vue/24/outline'

  let router = useRouter()
  let currentRouteName = router.options.history.location
  let navigation = [
    { name: 'Dashboard', href: '/', icon: HomeIcon, current: currentRouteName == '/' },
    { name: 'Network', href: '/network', icon: GlobeAltIcon, current: currentRouteName == '/network' },
    { name: 'Car Controls', href: '/car-controls', icon: AdjustmentsVerticalIcon, current: currentRouteName == '/car-controls' },
  ]
</script>