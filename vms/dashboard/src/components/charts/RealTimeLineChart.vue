<script>
import VueApexCharts from "vue3-apexcharts";
import { defineStore } from 'pinia'
import { ref } from 'vue'

export default{
  name: "RealTimeLineChart",
  props: ['title', 'series', 'id', 'serieMaxSize', 'chartInterval', 'yaxis'],
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
        pushToSerie(name, value, timestamp){
          let index = this.series.findIndex((serie) => {
            return serie.name == name
          });
          if(index >= 0){
            if(this.series[index].data.length >= this.serieMaxSize){
              this.series[index].data.shift()
            }

            this.series[index].data.push([timestamp, value]);
          }
        }
      }
    });

    // Defines chart options
    let options = ref({
      chart: {
        id: props.id,
        type: "line",
        zoom: {
          enabled: false,
          type: "xy",
          autoScaleYaxis: false
        }
      },
      yaxis: props.yaxis,
      xaxis: {
        type: 'datetime',
        labels: {
          show: false
        }
      }
    });

    let seriesStore = useChartStore();
    let series = seriesStore.series;

    // Defines component exposed functions
    function pushSeriesData(newSeriesValues) {
      newSeriesValues.forEach(newSerieValue => {
        let timestamp = Date.now();
        seriesStore.pushToSerie(newSerieValue["name"], newSerieValue["value"], timestamp);
      });
    };

    function setYaxisMaxForSerie(seriesName, max){
      let index = options.value.yaxis.findIndex((serie) => {
        return serie.seriesName == seriesName
      });
      if(index >= 0){
        let yaxis = options.value.yaxis
        yaxis[index]["max"] = max
        options.value = {
          ...options.value,
          yaxis: yaxis
        }
      };
    };

    return {
      pushSeriesData,
      setYaxisMaxForSerie,
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