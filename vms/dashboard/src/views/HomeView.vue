<template>
    <RealTimeThrottleChart ref="realTimeThrottleChart" :carControls="carControls"></RealTimeThrottleChart>
</template>

<script>
import { vmsDashboardSocket } from '../services/socket_service.js'
import { useCarControls } from "../stores/car_controls.js"
import { useInverter } from "../stores/inverter.js"
import { onMounted } from 'vue'

import RealTimeThrottleChart from "../components/charts/RealTimeThrottleChart.vue"

export default {
  name: "Home",
  components: {
    RealTimeThrottleChart,
  },
  setup(){
    const carControls = useCarControls();
    const inverter = useInverter();
    const chartInterval = 50;

    onMounted(() => {
      let carControlsChannel = vmsDashboardSocket.channel("car-controls", {interval: chartInterval})
      carControlsChannel.on("updated", payload => {
        carControls.$patch(payload);
      });

      let inverterChannel = vmsDashboardSocket.channel("inverter", {interval: chartInterval})
      inverterChannel.on("updated", payload => {
        inverter.$patch(payload)
      });

      carControlsChannel.join().receive("ok", () => {});
      inverterChannel.join().receive("ok", () => {});
    });

    return {
      carControls
    }
  }
};

</script>