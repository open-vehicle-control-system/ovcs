<template>
  <div class="grid grid-cols-6 gap-10 pb-5">
    <div v-for="emitter in systemStatus.failedEmitters" class="p-5 rounded-md animate-blinkingBg p-4 border-solid border rounded border-gray-300 shadow-md">
      <div class="flex items-center gap-x-3">
        <span class="text-red-800">{{ emitter }} not present</span>
      </div>
    </div>
  </div>
  <div class="grid grid-cols-3 gap-10">
    <div class="p-5 border-solid border rounded border-gray-300 shadow-md">
      <h2 class="text-base">Vehicle information</h2>
      <table class="min-w-full divide-y divide-gray-300">
        <tbody class="divide-y divide-gray-200 bg-white">
          <tr>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">Selected Gear</td>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ vehicle.selectedGear }}</td>
          </tr>
          <tr>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">Key status</td>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ vehicle.keyStatus }}</td>
          </tr>
          <tr>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">Speed</td>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ vehicle.speed }} kph</td>
          </tr>
          <tr>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">RPM</td>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ inverter.rotationPerMinute }}</td>
          </tr>
          <tr>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">Output voltage</td>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ inverter.outputVoltage }}V</td>
          </tr>
          <tr>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">Motor temperature</td>
            <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ inverter.motorTemperature }}C</td>
          </tr>
        </tbody>
      </table>
    </div>
    <RealTimeThrottleChart ref="realTimeThrottleChart" :throttle="throttle"></RealTimeThrottleChart>
    <RealTimeTorqueChart ref="realTimeTorqueChart" :inverter="inverter"></RealTimeTorqueChart>
    <RealTimeTemperatureChart ref="realTimeTemperatureChart" :inverter="inverter"></RealTimeTemperatureChart>
    <RealTimeRpmVoltageChart ref="realTimeRpmVoltageChart" :inverter="inverter"></RealTimeRpmVoltageChart>
    <RealTimeSpeedChart ref="realTimeSpeedChart" :vehicle="vehicle"></RealTimeSpeedChart>
  </div>
</template>

<script setup>
  import { vmsDashboardSocket } from '../services/socket_service.js'
  import { useThrottle } from "../stores/throttle.js"
  import { useInverter } from "../stores/inverter.js"
  import { useVehicle } from "../stores/vehicle.js"
  import { useSystemStatus } from "../stores/system_status.js"
  import { onMounted } from 'vue'

  import RealTimeThrottleChart from "../components/charts/RealTimeThrottleChart.vue"
  import RealTimeTorqueChart from "../components/charts/RealTimeTorqueChart.vue"
  import RealTimeTemperatureChart from "../components/charts/RealTimeTemperatureChart.vue"
  import RealTimeRpmVoltageChart from "../components/charts/RealTimeRpmVoltageChart.vue"
  import RealTimeSpeedChart from "../components/charts/RealTimeSpeedChart.vue"

  const throttle = useThrottle();
  const inverter = useInverter();
  const vehicle = useVehicle();
  const systemStatus = useSystemStatus();
  const chartInterval = 70;

  onMounted(() => {
    throttle.init(vmsDashboardSocket, chartInterval, "throttle")
    inverter.init(vmsDashboardSocket, chartInterval, "inverter")
    vehicle.init(vmsDashboardSocket, chartInterval, "vehicle")
    systemStatus.init(vmsDashboardSocket, chartInterval, "system-status")
  });
</script>