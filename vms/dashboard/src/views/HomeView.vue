<template>
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
    <RealTimeThrottleChart ref="realTimeThrottleChart" :carControls="carControls"></RealTimeThrottleChart>
    <RealTimeTorqueChart ref="realTimeTorqueChart" :inverter="inverter"></RealTimeTorqueChart>
    <RealTimeTemperatureChart ref="realTimeTemperatureChart" :inverter="inverter"></RealTimeTemperatureChart>
    <RealTimeRpmVoltageChart ref="realTimeRpmVoltageChart" :inverter="inverter"></RealTimeRpmVoltageChart>
    <RealTimeSpeedChart ref="realTimeSpeedChart" :vehicle="vehicle"></RealTimeSpeedChart>
  </div>
</template>

<script setup>
import { vmsDashboardSocket } from '../services/socket_service.js'
import { useCarControls } from "../stores/car_controls.js"
import { useInverter } from "../stores/inverter.js"
import { useVehicle } from "../stores/vehicle.js"
import { onMounted } from 'vue'

import RealTimeThrottleChart from "../components/charts/RealTimeThrottleChart.vue"
import RealTimeTorqueChart from "../components/charts/RealTimeTorqueChart.vue"
import RealTimeTemperatureChart from "../components/charts/RealTimeTemperatureChart.vue"
import RealTimeRpmVoltageChart from "../components/charts/RealTimeRpmVoltageChart.vue"
import RealTimeSpeedChart from "../components/charts/RealTimeSpeedChart.vue"

const carControls = useCarControls();
const inverter = useInverter();
const vehicle = useVehicle();
const chartInterval = 100;

onMounted(() => {
  carControls.init(vmsDashboardSocket, chartInterval, "car-controls")
  inverter.init(vmsDashboardSocket, chartInterval, "inverter")
  vehicle.init(vmsDashboardSocket, chartInterval, "vehicle")
});
</script>