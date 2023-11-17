<script setup>
import { storeToRefs } from 'pinia'
import { useMetricsStore } from "../stores/metrics.js"
const { metrics } = storeToRefs(useMetricsStore())
</script>

<template>
  <div>
    <div class="px-4 sm:px-0">
      <h3 class="text-3xl font-semibold leading-7 text-gray-900 dark:text-gray-200">
        Debug Information
      </h3>
    </div>
    <div class="mt-6 border-t border-gray-100 dark:border-gray-800">
      <dl class="divide-y divide-gray-100 dark:divide-gray-600">
        <template v-for="metric in metrics">
        <div class="px-4 py-6 sm:grid sm:grid-cols-3 sm:gap-4 sm:px-0">
          <dt class="text-xl font-medium leading-6 text-gray-900 dark:text-gray-400">
            {{ humanizeKey(metric["attributes"]["name"])}}
          </dt>
          <dd class="mt-1 text-2xl leading-6 text-gray-700 dark:text-gray-200 sm:col-span-2 sm:mt-0">
            {{ formatValue(metric["attributes"]["value"], metric["attributes"]["unit"]) }}
          </dd>
        </div>
        </template>
      </dl>
    </div>
  </div>
</template>
<script>
export default {
  name: "App",
  components: {
  },
  data: () => ({
  }),
  methods: {
    humanizeKey: (key) => {
      return key.replace(/([A-Z])/g, ' $1').replace(/^./, (str) => {
        return str.toUpperCase();
      })
    },

    formatValue: (value, unit) => {
      let formattedValue;
      switch(unit) {
        case "celcius":
          formattedValue = value + " " + "°C"
          break
        case undefined:
          formattedValue = value
          break
        default:
          formattedValue = value + " " + unit
      }
      return formattedValue;
    }
  },
};
</script>
