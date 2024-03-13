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
          <div v-for="key in Object.keys(carControls.$state)" class="pt-6 sm:flex">
            <dt class="font-medium text-gray-900 sm:w-64 sm:flex-none sm:pr-6">{{ key }}</dt>
            <dd class="mt-1 flex justify-between gap-x-6 sm:mt-0 sm:flex-auto">
              <div class="text-gray-900">{{ carControls[key] }}</div>
            </dd>
          </div>
        </dl>
      </div>
    </div>
  </form>

  <RealTimeLineChart ref="throttleChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :chartInterval="chartInterval"></RealTimeLineChart>
</template>

<script>
  import { Switch, SwitchGroup, SwitchLabel } from '@headlessui/vue'
  import { Socket } from 'phoenix'
  import { useCarControls } from "../../stores/car_controls.js"
  import CalibrationService from "../../services/calibration_service.js"
  import CarControlsService from "../../services/car_controls_service.js"
  import { ref, onMounted } from 'vue'

  import RealTimeLineChart from "../../components/charts/RealTimeLineChart.vue"

  export default {
    name: "CarControls",
    components: {
      RealTimeLineChart,
      Switch,
      SwitchGroup,
      SwitchLabel
    },
    setup(){
      const carControls = useCarControls();
      const chartTitle    = "Real-time Throttle Chart";
      const chartId       = "realtime-throttle-chart";
      const throttleChart = ref();
      const chartInterval = 50;
      const serieMaxSize  = 300;

      let carControlsStore = useCarControls();
      let series = [
        {name: "Throttle A", data: []},
        {name: "Throttle B", data: []}
      ];

      function toggleCalibration(calibrationEnabled){
        let carControlsStore = useCarControls();
        CalibrationService.post_calibration_enabled(calibrationEnabled).then((response) => {
          carControlsStore.$patch(response.data)
        });
      };

      onMounted(() => {
        let vmsDashboardSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", {});
        vmsDashboardSocket.connect();
        let carControlsChannel = vmsDashboardSocket.channel("car-controls", {})

        CalibrationService.fetch_calibration_data().then(
          (response) => {
            carControlsStore.$patch(response.data)
            throttleChart.value.setYMax(carControlsStore.raw_max_throttle)
          }
        );

        carControlsChannel.on("updated", payload => {
          carControlsStore.$patch(payload);
          throttleChart.value.pushSeriesData([
            {name: "Throttle A", value: payload.raw_throttle_a},
            {name: "Throttle B", value: payload.raw_throttle_b}
          ]);
        })

        CarControlsService.set_transmission_interval(chartInterval).then(
          (_response) => carControlsChannel.join().receive("ok", () => {})
        )

      });

      return {
        carControls,
        series,
        chartId,
        chartTitle,
        throttleChart,
        chartInterval,
        serieMaxSize,
        toggleCalibration
      }
    }
  };
</script>../stores/car_controls.js../services/calibration_service.js../services/car_controls_service.js./CarControlsView.vue/index.js