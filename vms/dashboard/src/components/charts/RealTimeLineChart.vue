<template>
  <div class="p-5 border-solid border rounded border-gray-300 shadow-md">
    <h2>{{ title }}</h2>
    <v-chart ref="chart" class="chart" :option="option" :id="id" />
  </div>
</template>

<script setup>
  import { use } from 'echarts/core'
  import { LineChart } from 'echarts/charts'
  import {
    TooltipComponent,
    TitleComponent,
    ToolboxComponent,
    GridComponent,
    DataZoomComponent,
    LegendComponent
  } from 'echarts/components'
  import VChart, { THEME_KEY } from "vue-echarts";
  import { CanvasRenderer } from 'echarts/renderers'
  import { ref, provide, onMounted, onUnmounted } from "vue"
  import { defineStore } from 'pinia'

  use([
    TooltipComponent,
    TitleComponent,
    ToolboxComponent,
    GridComponent,
    LegendComponent,
    DataZoomComponent,
    LineChart,
    CanvasRenderer
  ])

  const props = defineProps(['title', 'series', 'id', 'serieMaxSize', 'yaxis'])
  const id = props.id
  const chart = ref()

  provide(THEME_KEY, "light");

  const useChartStore = defineStore(props.id, {
    state: () => ({
      series: props.series.map((serie) => ({
        ...serie,
        type: "line",
        showSymbol: false,
        data: serie.data || []
      })),
      serieMaxSize: props.serieMaxSize
    }),
    actions: {
      pushToSerie(name, value, timestamp){
        let index = this.series.findIndex((serie) => serie.name == name);
        if(index >= 0){
          if(this.series[index].data.length >= this.serieMaxSize){
            this.series[index].data.shift()
          }
          this.series[index].data.push([timestamp, value]);
        }
      }
    }
  });

  let seriesStore = useChartStore();

  let yAxis = props.yaxis.map((yaxis) => {
    return {
      ...yaxis,
      name: yaxis.label,
      type: "value",
      nameLocation: "end",
      nameTextStyle: {align: "right", padding: 10}
    }
  })

  const pushSeriesData = (newSeriesValues) => {
    let timestamp = Date.now();
    newSeriesValues.forEach(newSerieValue => {
      seriesStore.pushToSerie(newSerieValue["name"], newSerieValue["value"], timestamp);
    });
  };

  const setMax = (name, max) => {
    let yaxis = option.value.yAxis;
    let index = yaxis.findIndex((serie) => serie.serieName == name);
    if(index >= 0 && yaxis[index] && yaxis[index].max != max){
      yaxis[index].max = max
      option.value = {
        ...option.value,
        yAxis: yaxis
      }
    };
  };

  onMounted(() => {
    window.addEventListener('resize', () => {
      chart.value.resize()
    } )
  })
  onUnmounted(() => {
      window.removeEventListener('resize', () => {})
  })

  defineExpose({
    pushSeriesData,
    setMax
  })

  const option = ref({
    tooltip: {
      trigger: 'axis',
    },
    legend: {
      show: true,
      type: 'plain',
      bottom: 10,
      icon: "circle",
      data: seriesStore.series.map((serie) => { return serie.name })
    },
    animation: false,
    xAxis: {
      type: 'time',
      axisLabel: {
        show: false
      }
    },
    yAxis: yAxis,
    series: seriesStore.series
  });
</script>

<style scoped>
  .chart {
    height: 400px;
  }
</style>