<script setup>
import VueApexCharts from 'vue3-apexcharts'
</script>
    
<template>
    <div>
        <h2>Title</h2>
        <apexchart width="500" type="line" :options="options" :series="series"></apexchart>
    </div>
</template>

<script>
export default {
  name: "LineChart",
  components: {
  },
  mounted: () => {
    var me = this
    window.setInterval(function () {
      getNewSeries(lastDate, {
        min: 10,
        max: 90
      })
      
      me.$refs.chart.updateSeries([{
        data: data
      }])
    }, 500)

    // every 60 seconds, we reset the data to prevent memory leaks
    window.setInterval(function () {
      resetData()
      
      me.$refs.chart.updateSeries([{
        data
      }], false, true)
    }, 10000)
  },
  data: () => {
    return {
      options: {
        chart: {
          id: 'vuechart-example'
        },
        xaxis: {
          categories: []
        }
      },
      series: [{
        name: 'series-1',
        data: [30, 40, 45, 50, 49, 60, 70, 91]
      }]
    }
  }
}
</script>
