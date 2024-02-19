<script setup>
import { storeToRefs } from 'pinia'
import { useMetricsStore } from "../stores/metrics.js"
import { systemInformationStore } from "../stores/system_information.js"
import { Socket } from 'phoenix'
import KioskBoard from '../kioskboard'
const { metrics } = storeToRefs(useMetricsStore())
const { data } = storeToRefs(systemInformationStore())
</script>

<template>
  <div>
    <div class="px-4 sm:px-0">
      <h3 class="text-3xl font-semibold leading-7 text-gray-900 dark:text-gray-200">
        System Information
      </h3>
    </div>
    <div class="mt-6 border-t border-gray-100 dark:border-gray-800">
      <dl class="divide-y divide-gray-100 dark:divide-gray-600">

        <template v-for="data_point in data">
        <div class="px-4 py-6 sm:grid sm:grid-cols-2 sm:gap-4 sm:px-0">
          <dt class="text-xl font-medium leading-6 text-gray-900 dark:text-gray-400">
            {{ humanizeKey(data_point["attributes"]["name"])}}
          </dt>
          <dd class="mt-1 text-2xl px-28 leading-6 text-gray-700 dark:text-gray-200 sm:col-span-1 sm:mt-0">
            {{ formatValue(data_point["attributes"]["value"], data_point["attributes"]["unit"]) }}
          </dd>
        </div>
        </template>
      </dl>
    </div>
    <div class="px-4 sm:px-0">
      <h3 class="text-3xl font-semibold leading-7 text-gray-900 dark:text-gray-200">
        Debug Information
      </h3>
    </div>
    <div class="mt-6 border-t border-gray-100 dark:border-gray-800">
      <dl class="divide-y divide-gray-100 dark:divide-gray-600">

        <template v-for="metric in metrics">
        <div class="px-4 py-6 sm:grid sm:grid-cols-2 sm:gap-4 sm:px-0">
          <dt class="text-xl font-medium leading-6 text-gray-900 dark:text-gray-400">
            {{ humanizeKey(metric["attributes"]["name"])}}
          </dt>
          <dd class="mt-1 text-2xl px-28 leading-6 text-gray-700 dark:text-gray-200 sm:col-span-1 sm:mt-0">
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
  mounted: () => {
    let store = useMetricsStore()
    let systemStore = systemInformationStore()
    let dashboardSocket = new Socket("ws://localhost:4000/sockets/dashboard", {})
    dashboardSocket.connect()
    let metricsChannel = dashboardSocket.channel("debug-metrics", {})
    let systemInformationChannel = dashboardSocket.channel("system-information", {})


    metricsChannel.on("updated", payload => {
      store.$patch(payload)
    })

    systemInformationChannel.on("updated", payload => {
      console.log(payload);
      systemStore.$patch(payload)
    })

    metricsChannel.join()
      .receive("ok", () => {})

    systemInformationChannel.join()
      .receive("ok", () => {})


    KioskBoard.run(".js-keyboard")
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
        case "m/s":
          formattedValue = value + " " + unit + " (" + value*(18/5)+ " " + "km/h)"
          break
        case null:
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
