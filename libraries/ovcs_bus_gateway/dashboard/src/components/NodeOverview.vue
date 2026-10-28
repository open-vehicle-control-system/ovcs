<script setup>
import { OvcsCard, OvcsStatus } from '@ovcs/ui/vue'
import { ago } from '../format'
import { nodeStatus, signalCount, staleCount } from '../signals'

defineProps({
  tree: { type: Array, required: true },
  now: { type: Number, required: true }
})
</script>

<template>
  <nav class="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
    <OvcsCard
      v-for="node in tree"
      :key="node.node"
      :href="node.sources.length ? `#node-${node.node}` : null"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="font-semibold">{{ node.node }}</span>
        <OvcsStatus :tone="nodeStatus(node).tone" class="text-xs">{{ nodeStatus(node).label }}</OvcsStatus>
      </div>
      <p class="mt-1 text-xs text-ovcs-muted">
        <template v-if="node.sources.length">
          {{ signalCount(node) }} signals · changed {{ ago(now - node.lastChange) }}
          <span v-if="staleCount(node)" class="text-ovcs-warn">· {{ staleCount(node) }} stale</span>
        </template>
        <template v-else>Publishes no signals</template>
      </p>
    </OvcsCard>
  </nav>
</template>
