<script setup>
import { storeToRefs } from 'pinia'
import { useMetricsStore } from "../stores/metrics.js"
const { metrics } = storeToRefs(useMetricsStore())
</script>

<template>
  <div>
    <div class="px-4 sm:px-0">
      <h3 class="text-base font-semibold leading-7 text-gray-900">
        Debug Information
      </h3>
    </div>
    <div class="mt-6 border-t border-gray-100">
      <dl class="divide-y divide-gray-100">
        <template v-for="metric in metrics">
        <div class="px-4 py-6 sm:grid sm:grid-cols-3 sm:gap-4 sm:px-0">
          <dt class="text-sm font-medium leading-6 text-gray-900">
            {{ metric["attributes"]["name"] }}
          </dt>
          <dd class="mt-1 text-sm leading-6 text-gray-700 sm:col-span-2 sm:mt-0">
            {{ metric["attributes"]["value"] }} {{ metric["attributes"]["unit"]}}
          </dd>
        </div>
        </template>
      </dl>
    </div>
  </div>
</template>
<script>
export default {
  name: "App",
  components: {
  },
  data: () => ({
  }),
  methods: {
  },
};
</script>
