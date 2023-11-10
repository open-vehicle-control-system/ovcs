<template>
  <div>
    <!-- Static sidebar for desktop -->
    <div class="lg:fixed lg:inset-y-0 lg:z-50 lg:flex lg:w-51 lg:flex-col">
      <!-- Sidebar component, swap this element with another sidebar if you like -->
      <div class="flex grow flex-col gap-y-5 overflow-y-auto bg-indigo-600 px-6">
        <div class="flex h-16 shrink-0 items-center">
          <p class="text-3xl text-white">OVCS</p>
        </div>
        <nav class="flex flex-1 flex-col">
          <ul role="list" class="flex flex-1 flex-col gap-y-7">
            <li>
              <ul role="list" class="-mx-2 space-y-1">
                <li v-for="item in navigation" :key="item.name">
                  <a :href="item.href" :class="[item.current ? 'bg-indigo-700 text-white' : 'text-indigo-200 hover:text-white hover:bg-indigo-700', 'group flex gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold']">
                    <component :is="item.icon" :class="[item.current ? 'text-white' : 'text-indigo-200 group-hover:text-white', 'h-20 w-20 shrink-0']" aria-hidden="true" />
                  </a>
                </li>
              </ul>
            </li>
          </ul>
        </nav>
      </div>
    </div>

    <main class="py-10 lg:pl-72">
      <div class="px-4 sm:px-6 lg:px-8">
        <RouterView />
      </div>
    </main>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import { Dialog, DialogPanel, TransitionChild, TransitionRoot } from '@headlessui/vue'
import {
  DocumentMagnifyingGlassIcon,
  RadioIcon,
} from '@heroicons/vue/24/outline'

const navigation = [
  { name: 'Debug', href: '/debug', icon: DocumentMagnifyingGlassIcon, current: true },
]

const sidebarOpen = ref(false)
import { RouterLink, RouterView } from 'vue-router'
</script>
