<template>
    <RealTimeThrottleChart ref="realTimeThrottleChart" :carControls="carControls"></RealTimeThrottleChart>
    <RealTimeTorqueChart ref="realTimeTorqueChart" :inverter="inverter"></RealTimeTorqueChart>
    <RealTimeTemperatureChart ref="realTimeTemperatureChart" :inverter="inverter"></RealTimeTemperatureChart>
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
      let carControlsChannel = vmsDashboardSocket.channel("car-controls", {interval: chartInterval})
      carControlsChannel.on("updated", payload => {
        carControls.$patch(payload);
      });

      let inverterChannel = vmsDashboardSocket.channel("inverter", {interval: chartInterval})
      inverterChannel.on("updated", payload => {
        inverter.$patch(payload)
      });

      let vehicleChannel = vmsDashboardSocket.channel("vehicle", {interval: chartInterval})
      vehicleChannel.on("updated", payload => {
        vehicle.$patch(payload)
      });

      carControlsChannel.join().receive("ok", () => {});
      inverterChannel.join().receive("ok", () => {});
      vehicleChannel.join().receive("ok", () => {});
    });

    return {
      carControls,
      inverter
    }
  }
};

</script>