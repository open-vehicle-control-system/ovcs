<template>
  <h1 class="text-xl">Steering</h1>
  <form>
    <div class="space-y-12">
      <div class="border-b border-gray-900/10 pb-12">
        <dl class="mt-6 space-y-6 divide-y divide-gray-100 border-t border-gray-200 text-sm leading-6">
          <div class="pt-6 sm:flex">
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <button type="button" @click="calibrateAngleSensor()" :class="[steering.$state.lwsCalibrationStatus == 'disabled' ? 'bg-indigo-600' : 'bg-gray-200', 'inline-flex items-center gap-x-2 rounded-md px-3.5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']" >
                Save angle 0°
                <CheckCircleIcon class="-mr-0.5 h-5 w-5" aria-hidden="true" />
              </button>
            </dd>
          </div>
          <div v-for="key in Object.keys(steering.$state)" class="pt-6 sm:flex">
            <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">{{ key }}</dt>
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <div class="text-gray-900">{{ steering[key] }}</div>
            </dd>
          </div>
        </dl>
      </div>
    </div>
  </form>

  <RealTimeSteeringChart ref="realTimeSteeringChart" :steering="steering"></RealTimeSteeringChart>
</template>

<script setup>
  import { Switch, SwitchGroup, SwitchLabel } from '@headlessui/vue'
  import { vmsDashboardSocket } from '../services/socket_service.js'
  import { useSteering } from "../stores/steering.js"
  import SteeringAngleSensorCalibrationService from "../services/steering_angle_sensor_calibration_service.js"
  import { ref, onMounted } from 'vue'
  import { CheckCircleIcon } from '@heroicons/vue/20/solid'

  import RealTimeSteeringChart from "../components/charts/RealTimeSteeringChart.vue"

  const steering = useSteering();

  const realTimeSteeringChart = ref();
  const chartInterval = 50;

  function calibrateAngleSensor(){
    steering.lwsCalibrationStatus = "enabled";
    SteeringAngleSensorCalibrationService.postSteeringAngleSensorCalibration().then((response) => {
      steering.$patch({lwsCalibrationStatus: "disabled"})
    });
  };

  onMounted(() => {
    steering.init(vmsDashboardSocket, chartInterval, "steering")
  });

  defineExpose({
    calibrateAngleSensor
  })
</script>