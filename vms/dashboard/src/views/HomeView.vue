<template>
  <div class="grid grid-cols-2 gap-10">
    <RealTimeThrottleChart ref="realTimeThrottleChart" :carControls="carControls"></RealTimeThrottleChart>
    <RealTimeTorqueChart ref="realTimeTorqueChart" :inverter="inverter"></RealTimeTorqueChart>
    <RealTimeTemperatureChart ref="realTimeTemperatureChart" :inverter="inverter"></RealTimeTemperatureChart>
  </div>
</template>

<script>
import { vmsDashboardSocket } from '../services/socket_service.js'
import { useCarControls } from "../stores/car_controls.js"
import { useInverter } from "../stores/inverter.js"
import { useVehicle } from "../stores/vehicle.js"
import { onMounted } from 'vue'

import RealTimeThrottleChart from "../components/charts/RealTimeThrottleChart.vue"
import RealTimeTorqueChart from "../components/charts/RealTimeTorqueChart.vue"
import RealTimeTemperatureChart from "../components/charts/RealTimeTemperatureChart.vue"


export default {
  name: "Home",
  components: {
    RealTimeThrottleChart,
    RealTimeTorqueChart,
    RealTimeTemperatureChart
  },
  setup(){
    const carControls = useCarControls();
    const inverter = useInverter();
    const vehicle = useVehicle();
    const chartInterval = 100;

    onMounted(() => {
      carControls.init(vmsDashboardSocket, chartInterval, "car-controls")
      inverter.init(vmsDashboardSocket, chartInterval, "inverter")
      vehicle.init(vmsDashboardSocket, chartInterval, "vehicle")
    });

    return {
      carControls,
      inverter
    }
  }
};

</script>