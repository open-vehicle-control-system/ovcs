<script setup>
import { ago, duration, formatValue, isLive } from '../format'
import { splitSource, staleCount } from '../signals'

defineProps({
  tree: { type: Array, required: true },
  now: { type: Number, required: true }
})

const status = {
  true: { label: 'Connected', dot: 'bg-ovcs-ok', text: 'text-ovcs-ok' },
  false: { label: 'Disconnected', dot: 'bg-ovcs-error', text: 'text-ovcs-error' },
  null: { label: 'Status unknown', dot: 'bg-ovcs-muted', text: 'text-ovcs-muted' }
}

const tone = { ok: 'text-ovcs-ok', muted: 'text-ovcs-muted', plain: '' }

const signalCount = (node) => node.sources.reduce((count, source) => count + source.signals.length, 0)
</script>

<template>
  <section v-for="node in tree" :key="node.node" class="mb-8">
    <header class="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1">
      <h2 class="text-xl font-semibold">{{ node.node }}</h2>
      <span class="flex items-center gap-1.5 text-sm" :class="status[node.connected].text">
        <span class="inline-block h-2 w-2 rounded-full" :class="status[node.connected].dot" />
        {{ status[node.connected].label }}
      </span>
      <span v-if="node.sources.length" class="text-sm text-ovcs-muted">
        {{ signalCount(node) }} signals · last change {{ ago(now - node.lastChange) }}
      </span>
      <span v-if="staleCount(node)" class="text-sm text-ovcs-warn">{{ staleCount(node) }} stale</span>
    </header>

    <p v-if="!node.sources.length" class="text-sm text-ovcs-muted">Publishes no signals.</p>

    <div v-else class="rounded border border-ovcs-border bg-ovcs-surface">
      <div
        class="grid grid-cols-[1fr_minmax(9rem,auto)_6rem_7rem] gap-4 border-b border-ovcs-border px-3 py-1.5 text-xs uppercase tracking-wide text-ovcs-muted"
      >
        <span>Signal</span>
        <span>Value</span>
        <span class="text-right">Last change</span>
        <span class="text-right">Last published</span>
      </div>

      <template v-for="source in node.sources" :key="source.source">
        <h3 class="border-b border-ovcs-border bg-ovcs-bg px-3 pb-1 pt-3 text-sm" :title="source.source">
          <span class="text-ovcs-muted">{{ splitSource(source.source).namespace }}</span>
          <span class="font-semibold">{{ splitSource(source.source).name }}</span>
        </h3>
        <div
          v-for="signal in source.signals"
          :key="signal.name"
          class="signal-row grid grid-cols-[1fr_minmax(9rem,auto)_6rem_7rem] items-baseline gap-4 border-b border-ovcs-border px-3 py-1 text-sm last:border-b-0"
          :class="{ 'signal-row--live': isLive(signal, now) }"
        >
          <span class="flex items-center gap-2 pl-3">
            <span
              class="inline-block h-1.5 w-1.5 rounded-full"
              :class="isLive(signal, now) ? 'bg-ovcs-accent' : 'bg-transparent'"
            />
            {{ signal.name }}
          </span>
          <span class="font-mono" :class="signal.stale === true ? 'text-ovcs-muted' : tone[formatValue(signal.value).tone]">
            {{ formatValue(signal.value).text }}
            <span v-if="signal.unit" class="ml-1 font-sans text-xs text-ovcs-muted">{{ signal.unit }}</span>
            <span v-if="signal.stale === true" class="ml-2 font-sans text-xs text-ovcs-warn">stale</span>
          </span>
          <span class="text-right text-xs text-ovcs-muted" :title="new Date(signal.changed_at).toISOString()">
            {{ duration(now - signal.changed_at) }}
          </span>
          <span
            v-if="signal.published_at != null"
            class="text-right text-xs text-ovcs-muted"
            :title="new Date(signal.published_at).toISOString()"
          >
            {{ duration(now - signal.published_at) }}
          </span>
          <span v-else class="text-right text-xs text-ovcs-muted">—</span>
        </div>
      </template>
    </div>
  </section>
</template>
