<template>
  <h1 class="text-xl">Throttle</h1>
  <form>
    <div class="space-y-12">
      <div class="border-b border-gray-900/10 pb-12">
        <h2 class="text-base font-semibold leading-7 text-gray-900">Calibration</h2>
        <dl class="mt-6 space-y-6 divide-y divide-gray-100 border-t border-gray-200 text-sm leading-6">
          <div class="pt-6 sm:flex">
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <SwitchGroup as="div" class="flex pt-6">
                    <SwitchLabel as="dt" class="flex-none pr-6 font-medium text-gray-900 sm:w-64" passive>Calibration mode enabled</SwitchLabel>
                    <dd class="flex flex-auto items-center justify-end">
                      <Switch @click="toggleCalibration(!throttle.calibrationEnabled)" :class="[throttle.calibrationEnabled ? 'bg-indigo-600' : 'bg-gray-200', 'flex w-8 cursor-pointer rounded-full p-px ring-1 ring-inset ring-gray-900/5 transition-colors duration-200 ease-in-out focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']">
                          <span aria-hidden="true" :class="[throttle.calibrationEnabled ? 'translate-x-3.5' : 'translate-x-0', 'h-4 w-4 transform rounded-full bg-white shadow-sm ring-1 ring-gray-900/5 transition duration-200 ease-in-out']" />
                      </Switch>
                    </dd>
              </SwitchGroup>
            </dd>
          </div>
          <div v-for="key in Object.keys(throttle.$state)" class="pt-6 sm:flex">
            <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">{{ key }}</dt>
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <div class="text-gray-900">{{ throttle[key] }}</div>
            </dd>
          </div>
        </dl>
      </div>
    </div>
  </form>

  <RealTimeThrottleChart ref="realTimeThrottleChart" :throttle="throttle"></RealTimeThrottleChart>
</template>

<script setup>
  import { Switch, SwitchGroup, SwitchLabel } from '@headlessui/vue'
  import { vmsDashboardSocket } from '../services/socket_service.js'
  import { useThrottle } from "../stores/throttle.js"
  import ThrottleCalibrationService from "../services/throttle_calibration_service.js"
  import { ref, onMounted } from 'vue'

  import RealTimeThrottleChart from "../components/charts/RealTimeThrottleChart.vue"

  const throttle = useThrottle();

  const realTimeThrottleChart = ref();
  const chartInterval = 50;

  function toggleCalibration(calibrationEnabled){
    ThrottleCalibrationService.post_calibration_enabled(calibrationEnabled).then((response) => {
      throttle.$patch(response.data)
    });
  };

  onMounted(() => {
    throttle.init(vmsDashboardSocket, chartInterval, "throttle")

    ThrottleCalibrationService.fetch_calibration_data().then(
      (response) => {
        throttle.$patch(response.data)
      }
    );
  });

  defineExpose({
    toggleCalibration
  })
</script>