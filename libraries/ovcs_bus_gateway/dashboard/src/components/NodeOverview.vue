<script setup>
import { ago } from '../format'
import { nodeStatus, signalCount, staleCount } from '../signals'

defineProps({
  tree: { type: Array, required: true },
  now: { type: Number, required: true }
})
</script>

<template>
  <nav class="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
    <component
      :is="node.sources.length ? 'a' : 'div'"
      v-for="node in tree"
      :key="node.node"
      :href="node.sources.length ? `#node-${node.node}` : undefined"
      class="block rounded border border-ovcs-border bg-ovcs-surface px-4 py-3"
      :class="{ 'hover:border-ovcs-accent': node.sources.length }"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="font-semibold">{{ node.node }}</span>
        <span class="flex items-center gap-1.5 text-xs" :class="nodeStatus(node).text">
          <span class="inline-block h-2 w-2 rounded-full" :class="nodeStatus(node).dot" />
          {{ nodeStatus(node).label }}
        </span>
      </div>
      <p class="mt-1 text-xs text-ovcs-muted">
        <template v-if="node.sources.length">
          {{ signalCount(node) }} signals · changed {{ ago(now - node.lastChange) }}
          <span v-if="staleCount(node)" class="text-ovcs-warn">· {{ staleCount(node) }} stale</span>
        </template>
        <template v-else>Publishes no signals</template>
      </p>
    </component>
  </nav>
</template>
