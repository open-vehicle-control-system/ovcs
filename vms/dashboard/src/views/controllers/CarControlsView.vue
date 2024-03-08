<script setup>

import { ref } from 'vue'
import { Switch, SwitchGroup, SwitchLabel } from '@headlessui/vue'

import { Socket } from 'phoenix'

import { useCarControls } from "../../stores/car_controls.js"
import CalibrationHelpers from "../../helpers/calibration_helpers.js"
import VueApexCharts from "vue3-apexcharts";
const carControls = useCarControls()

</script>

<template>
  <h1 class="text-xl">Car Controls</h1>
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
          <div class="pt-6 sm:flex">
            <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">Throttle A</dt>
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <div class="text-gray-900">{{ carControls.raw_throttle_a }}</div>
            </dd>
          </div>
          <div class="pt-6 sm:flex">
            <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">Throttle B</dt>
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <div class="text-gray-900">{{ carControls.raw_throttle_b }}</div>
            </dd>
          </div>
        </dl>
      </div>
    </div>
  </form>

  <div>
    <h2>Real time throttle</h2>
    <apexchart type="line" :options="options" :series="series"></apexchart>
  </div>
</template>

<script>
export default {
  name: "CarControls",
  components: {
    apexchart: VueApexCharts,
  },
  mounted: function() {
    let carControlsStore = useCarControls()
    CalibrationHelpers.fetch_calibration_data().then((response) => carControlsStore.$patch(response.data));

    let vmsDashboardSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", {})
    vmsDashboardSocket.connect();
    let carControlsChannel = vmsDashboardSocket.channel("car-controls", {})

    let chartData = [{name: "Throttle A", data: []}, {name: "Throttle B", data: []}];
    carControlsChannel.on("updated", payload => {
        carControlsStore.$patch(payload);
        if(chartData[0]["data"].length >= 100){
          chartData[0]["data"].shift();
        }
        if(chartData[1]["data"].length >= 100){
          chartData[1]["data"].shift();
        }
        let timestamp = Date.now()
        chartData[0]["data"].push([timestamp, payload.raw_throttle_a]);
        chartData[1]["data"].push([timestamp, payload.raw_throttle_b]);
        this.series = chartData;
        window.dispatchEvent(new Event('resize'));
    })

    carControlsChannel.join().receive("ok", () => {})
  },
  methods: {
    toggleCalibration: (calibrationEnabled) => {
      let carControlsStore = useCarControls()
      CalibrationHelpers.post_calibration_enabled(calibrationEnabled).then((response) => {
        carControlsStore.$patch(response.data)
        return CalibrationHelpers.fetch_calibration_data();
      })
      .then((response) => carControlsStore.$patch(response.data));
    },
  },

  data: () => {
    return {
      options: {
        chart: {
          id: 'vuechart-example'
        },
        xaxis: {
          type: 'datetime'
        }
      },
      series: [
        {name: "Throttle A", data: []},
        {name: "Throttle B", data: []}
      ]
    }
  }
};

</script>