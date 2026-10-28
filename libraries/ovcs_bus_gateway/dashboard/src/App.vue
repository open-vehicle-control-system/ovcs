<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useBusSocket } from './busSocket'
import { groupTree, isPresence } from './signals'
import FilterBar from './components/FilterBar.vue'
import NodeOverview from './components/NodeOverview.vue'
import SignalTree from './components/SignalTree.vue'

const { signals, connected } = useBusSocket()
const filter = ref('')
const now = ref(Date.now())
const filterBar = ref(null)

const timer = setInterval(() => {
  now.value = Date.now()
}, 500)

// "/" focuses the filter from anywhere but a text field.
function onKey(event) {
  if (event.key !== '/' || ['INPUT', 'TEXTAREA'].includes(event.target.tagName)) return
  event.preventDefault()
  filterBar.value?.focus()
}
onMounted(() => window.addEventListener('keydown', onKey))
onUnmounted(() => {
  clearInterval(timer)
  window.removeEventListener('keydown', onKey)
})

const tree = computed(() => groupTree(signals.value, filter.value))
const signalCount = computed(() => [...signals.value.values()].filter((signal) => !isPresence(signal)).length)
</script>

<template>
  <div class="min-h-screen">
    <FilterBar ref="filterBar" v-model="filter" :connected="connected" :count="signalCount" />
    <main class="mx-auto max-w-5xl px-4 py-6">
      <p v-if="!tree.length" class="text-ovcs-muted">
        {{ connected ? 'No signals match.' : 'Waiting for the gateway...' }}
      </p>
      <template v-else>
        <NodeOverview :tree="tree" :now="now" />
        <SignalTree :tree="tree" :now="now" />
      </template>
    </main>
  </div>
</template>
