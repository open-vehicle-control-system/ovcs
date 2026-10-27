<script setup>
import { computed, onUnmounted, ref } from 'vue'
import { useBusSocket } from './busSocket'
import { groupTree } from './signals'
import FilterBar from './components/FilterBar.vue'
import SignalTree from './components/SignalTree.vue'

const { signals, connected } = useBusSocket()
const filter = ref('')
const now = ref(Date.now())

const timer = setInterval(() => {
  now.value = Date.now()
}, 500)
onUnmounted(() => clearInterval(timer))

const tree = computed(() => groupTree(signals.value, filter.value))
</script>

<template>
  <div class="min-h-screen">
    <FilterBar v-model="filter" :connected="connected" :count="signals.size" />
    <main class="mx-auto max-w-5xl p-4">
      <p v-if="!tree.length" class="text-ovcs-muted">
        {{ connected ? 'No signals match.' : 'Waiting for the gateway...' }}
      </p>
      <SignalTree :tree="tree" :now="now" />
    </main>
  </div>
</template>
