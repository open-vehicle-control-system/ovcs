<script setup>
defineProps({
  tree: { type: Array, required: true },
  now: { type: Number, required: true }
})

function age(timestamp, now) {
  const seconds = Math.max(0, (now - timestamp) / 1000)
  if (seconds < 10) return `${seconds.toFixed(1)} s`
  if (seconds < 3600) return `${Math.round(seconds)} s`
  return `${Math.floor(seconds / 3600)} h`
}

function format(value) {
  return typeof value === 'object' && value !== null ? JSON.stringify(value) : String(value)
}
</script>

<template>
  <section v-for="node in tree" :key="node.node" class="mb-6">
    <h2 class="mb-2 text-base font-semibold text-ovcs-accent">{{ node.node }}</h2>
    <div
      v-for="source in node.sources"
      :key="source.source"
      class="mb-3 rounded border border-ovcs-border bg-ovcs-surface"
    >
      <h3 class="border-b border-ovcs-border px-3 py-1.5 text-sm font-medium">{{ source.source }}</h3>
      <table class="w-full text-sm">
        <tbody>
          <tr
            v-for="signal in source.signals"
            :key="signal.name"
            class="border-b border-ovcs-border last:border-b-0"
          >
            <td class="px-3 py-1">{{ signal.name }}</td>
            <td class="px-3 py-1 text-right font-mono">{{ format(signal.value) }}</td>
            <td class="w-16 px-3 py-1 text-ovcs-muted">{{ signal.unit }}</td>
            <td class="w-20 px-3 py-1 text-right font-mono text-ovcs-muted">
              {{ age(signal.timestamp, now) }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>
