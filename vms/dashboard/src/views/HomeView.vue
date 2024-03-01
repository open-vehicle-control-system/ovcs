<script setup>

import { ref } from 'vue'
import { Dialog, DialogPanel, Switch, SwitchGroup, SwitchLabel } from '@headlessui/vue'
import {
  TransitionChild,
  TransitionRoot,
} from '@headlessui/vue'
import {
  Bars3Icon,
  HomeIcon,
  XMarkIcon,
} from '@heroicons/vue/24/outline'

import { storeToRefs } from 'pinia'
import { Socket } from 'phoenix'
import axios from 'axios'
import { useCarControls } from "../stores/car_controls.js"

const carControls = useCarControls()

const navigation = [
  { name: 'Dashboard', href: '#', icon: HomeIcon, current: true },
]

const sidebarOpen = ref(false)
</script>

<template>
  <div>
    <TransitionRoot as="template" :show="sidebarOpen">
      <Dialog as="div" class="relative z-50 lg:hidden" @close="sidebarOpen = false">
        <TransitionChild as="template" enter="transition-opacity ease-linear duration-300" enter-from="opacity-0" enter-to="opacity-100" leave="transition-opacity ease-linear duration-300" leave-from="opacity-100" leave-to="opacity-0">
          <div class="fixed inset-0 bg-gray-900/80" />
        </TransitionChild>

        <div class="fixed inset-0 flex">
          <TransitionChild as="template" enter="transition ease-in-out duration-300 transform" enter-from="-translate-x-full" enter-to="translate-x-0" leave="transition ease-in-out duration-300 transform" leave-from="translate-x-0" leave-to="-translate-x-full">
            <DialogPanel class="relative mr-16 flex w-full max-w-xs flex-1">
              <TransitionChild as="template" enter="ease-in-out duration-300" enter-from="opacity-0" enter-to="opacity-100" leave="ease-in-out duration-300" leave-from="opacity-100" leave-to="opacity-0">
                <div class="absolute left-full top-0 flex w-16 justify-center pt-5">
                  <button type="button" class="-m-2.5 p-2.5" @click="sidebarOpen = false">
                    <span class="sr-only">Close sidebar</span>
                    <XMarkIcon class="h-6 w-6 text-white" aria-hidden="true" />
                  </button>
                </div>
              </TransitionChild>
              <!-- Sidebar component, swap this element with another sidebar if you like -->
              <div class="flex grow flex-col gap-y-5 overflow-y-auto bg-indigo-600 px-6 pb-4">
                <div class="flex h-16 shrink-0 items-center">
                  <img class="h-8 w-auto" src="https://tailwindui.com/img/logos/mark.svg?color=white" alt="Your Company" />
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
            </DialogPanel>
          </TransitionChild>
        </div>
      </Dialog>
    </TransitionRoot>

    <!-- Static sidebar for desktop -->
    <div class="hidden lg:fixed lg:inset-y-0 lg:z-50 lg:flex lg:w-72 lg:flex-col">
      <!-- Sidebar component, swap this element with another sidebar if you like -->
      <div class="flex grow flex-col gap-y-5 overflow-y-auto bg-indigo-600 px-6 pb-4">
        <div class="flex h-16 shrink-0 items-center">
          <img class="h-8 w-auto" src="https://tailwindui.com/img/logos/mark.svg?color=white" alt="Your Company" />
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

    <div class="lg:pl-72">
      <div class="sticky top-0 z-40 flex h-16 shrink-0 items-center gap-x-4 border-b border-gray-200 bg-white px-4 shadow-sm sm:gap-x-6 sm:px-6 lg:px-8" :display="sidebarOpen = false">
        <button type="button" class="-m-2.5 p-2.5 text-gray-700 lg:hidden" @click="sidebarOpen = true">
          <span class="sr-only">Open sidebar</span>
          <Bars3Icon class="h-6 w-6" aria-hidden="true" />
        </button>
      </div>

      <main class="py-10">
        <div class="px-4 sm:px-6 lg:px-8">
          <h1 class="text-xl">VMS dashboard</h1>
          <form>
            <div class="space-y-12">
              <div class="border-b border-gray-900/10 pb-12">
                <h2 class="text-base font-semibold leading-7 text-gray-900">Car controls Controller</h2>
                <dl class="mt-6 space-y-6 divide-y divide-gray-100 border-t border-gray-200 text-sm leading-6">
                  <div class="pt-6 sm:flex">
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <SwitchGroup as="div" class="flex pt-6">
                            <SwitchLabel as="dt" class="flex-none pr-6 font-medium text-gray-900 sm:w-64" passive>Calibration mode enabled</SwitchLabel>
                            <dd class="flex flex-auto items-center justify-end">
                              <Switch @click="toggleCalibration(!carControls.calibrationEnabled)" :class="[carControls.calibrationEnabled ? 'bg-indigo-600' : 'bg-gray-200', 'flex w-8 cursor-pointer rounded-full p-px ring-1 ring-inset ring-gray-900/5 transition-colors duration-200 ease-in-out focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']">
                                  <span aria-hidden="true" :class="[carControls.calibrationEnabled ? 'translate-x-3.5' : 'translate-x-0', 'h-4 w-4 transform rounded-full bg-white shadow-sm ring-1 ring-gray-900/5 transition duration-200 ease-in-out']" />
                              </Switch>
                            </dd>
                      </SwitchGroup>
                    </dd>
                  </div>
                  <div class="pt-6 sm:flex">
                    <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">Low raw throttle value A</dt>
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <div class="text-gray-900">{{ carControls.low_raw_throttle_a }}</div>
                    </dd>
                  </div>
                  <div class="pt-6 sm:flex">
                    <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">High raw throttle value A</dt>
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <div class="text-gray-900">{{ carControls.high_raw_throttle_a }}</div>
                    </dd>
                  </div>
                  <div class="pt-6 sm:flex">
                    <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">Low raw throttle value B</dt>
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <div class="text-gray-900">{{ carControls.low_raw_throttle_b }}</div>
                    </dd>
                  </div>
                  <div class="pt-6 sm:flex">
                    <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">High raw throttle value B</dt>
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <div class="text-gray-900">{{ carControls.high_raw_throttle_b }}</div>
                    </dd>
                  </div>
                  <div class="pt-6 sm:flex">
                    <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">Requested Gear</dt>
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <div class="text-gray-900">{{ carControls.requested_gear }}</div>
                    </dd>
                  </div>
                  <div class="pt-6 sm:flex">
                    <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">Throttle</dt>
                    <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
                      <div class="text-gray-900">{{ carControls.throttle }}</div>
                    </dd>
                  </div>
                </dl>
              </div>
            </div>
          </form>
        </div>
      </main>
    </div>
  </div>
</template>

<script>
export default {
  name: "App",
  components: {
  },
  mounted: () => {
    let carControlsStore = useCarControls()
    axios.get("/api/calibration", {})
    .then((response) => carControlsStore.$patch(response.data));

    let vmsDashboardSocket = new Socket("ws://localhost:4000/sockets/dashboard", {})
    vmsDashboardSocket.connect();
    let carControlsChannel = vmsDashboardSocket.channel("car-controls", {})
    let networkInterfaces = vmsDashboardSocket.channel("network-interfaces", {})

    carControlsChannel.on("updated", payload => {
      console.log(payload);
      carControlsStore.$patch(payload);
    })

    networkInterfaces.on("updated", payload => {
      console.log(payload);
    })

    carControlsChannel.join().receive("ok", () => {})
    networkInterfaces.join().receive("ok", () => {})
  },
  methods: {
    toggleCalibration: (calibrationEnabled) => {
      let carControlsStore = useCarControls()
      axios.post("/api/calibration", {
        calibrationModeEnabled: calibrationEnabled,
      })
      .then((response) => {
        carControlsStore.$patch(response.data)
        return axios.get("/api/calibration", {});
      })
      .then((response) => carControlsStore.$patch(response.data));
    }
  },
};

</script>