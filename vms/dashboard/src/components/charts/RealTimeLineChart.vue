<template>
    <h2>{{ title }}</h2>
    <v-chart ref="chart" class="chart" :option="option" :id="id" />
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

  const props = defineProps(['title', 'series', 'id', 'serieMaxSize', 'yaxis', 'interval', 'store'])
  const id = props.id
  const chart = ref()
  const interval = props.interval
  const now = Date.now()
  const store = props.store
  const series = props.series

  provide(THEME_KEY, "light");

  const useChartStore = defineStore(props.id, {
    state: () => ({
      series: props.series.map((serie) => ({
        ...serie,
        type: "line",
        showSymbol: false,
        data: serie.data || Array.from({length: props.serieMaxSize}, (e, i) => [now - interval * (props.serieMaxSize - i), 0 ])
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
      if(chart.value)
        chart.value.resize()
    })
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

  if(store){
    store.$subscribe((mutation, state) => {
      pushSeriesData(
        series.map((serie) => {
          return {name: serie.name, value: state.data[serie.metric.module][serie.metric.key]}
        })
      )
    })
  }
</script>

<style scoped>
  .chart {
    height: 400px;
  }
</style>