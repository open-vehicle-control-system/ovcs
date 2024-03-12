<script>
import VueApexCharts from "vue3-apexcharts";
import { defineStore } from 'pinia'

export default{  
  name: "RealTimeLineChart",
  props: ['title', 'series', 'id', 'serieMaxSize'],
  components: {
    apexchart: VueApexCharts
  },
  setup(props){
    // Defines a store for the chart
    const useChartStore = defineStore(props.id, {
      state: () => ({
        series: props.series,
        serieMaxSize: props.serieMaxSize
      }),
      actions: {
        pushToSerie(name, value){
          let index = this.series.findIndex((serie) => {
            return serie.name == name
          });
          if(index >= 0){
            if(this.series[index].data.length >= this.serieMaxSize){
              this.series[index].data.shift()
            }
            let timestamp = Date.now();
            this.series[index].data.push([timestamp, value]);
          }
        }
      }
    });

    let seriesStore = useChartStore();
    let series = seriesStore.series;

    // Defines component exposed functions
    function pushSeriesData(newSeriesValues) {
      newSeriesValues.forEach(newSerieValue => {
        seriesStore.pushToSerie(newSerieValue["name"], newSerieValue["value"]);
      });
      window.dispatchEvent(new Event('resize'));
    };

    // Defines chart oprions
    let options = {
      chart: {
        id: props.id,
        type: "line",
      },
      stroke: {
        curve: 'smooth'
      },
      xaxis: {
        type: 'datetime'
      }
    };

    return {
      pushSeriesData,
      series,
      options
    }
  }
};
</script>

<template>
    <div>
        <h2>{{ title }}</h2>
        <apexchart :options="options" :series="series"></apexchart>
    </div>
</template>