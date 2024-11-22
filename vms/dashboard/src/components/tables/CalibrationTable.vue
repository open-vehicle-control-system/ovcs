<template>
    <h2 class="text-base">{{ title }}</h2>
    <table class="min-w-full divide-y divide-gray-300">
    <tbody class="divide-y divide-gray-200 bg-white">
        <tr v-for="value in values">
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ value.name }}</td>
            <td v-if="value.type === 'initial'"  class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">
              <button type="button" @click="calibrate(value)" :class="[value.calibrationOngoing ? 'bg-gray-200' : 'bg-indigo-600', 'inline-flex items-center gap-x-2 rounded-md px-3.5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']" >
                Set
                <CheckCircleIcon class="-mr-0.5 h-5 w-5" aria-hidden="true" />
              </button>
            </td>
            <td v-if="value.type === 'boundaries'"  class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">
              <SwitchGroup as="div" class="flex" v-if="store.data[value.module]">
                  <dd class="flex flex-auto items-center justify-end">
                    <Switch @click="calibrate(value)" :class="[store.data[value.module][value.statusMetricKey] === 'disabled' ? 'bg-gray-200' : 'bg-indigo-600' , 'flex w-8 cursor-pointer rounded-full p-px ring-1 ring-inset ring-gray-900/5 transition-colors duration-200 ease-in-out focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']">
                        <span aria-hidden="true" :class="[store.data[value.module][value.statusMetricKey] === 'disabled' ? 'translate-x-0' : 'translate-x-3.5' , 'h-4 w-4 transform rounded-full bg-white shadow-sm ring-1 ring-gray-900/5 transition duration-200 ease-in-out']" />
                    </Switch>
                  </dd>
              </SwitchGroup>
            </td>
        </tr>
    </tbody>
    </table>
</template>

<script setup>

import { ref } from 'vue'
import { Switch, SwitchGroup } from '@headlessui/vue'
import { CheckCircleIcon } from '@heroicons/vue/20/solid'
import CalibrationService from "@/services/calibration_service.js"

const props = defineProps(['title', 'values', 'store'])

const title = props.title
const values = ref(props.values)
let store = props.store

const calibrate = (value) => {
  value.calibrationOngoing = true
  CalibrationService.post_calibration(value).then((response) => {
    value.calibrationOngoing = false
  })
}

</script>