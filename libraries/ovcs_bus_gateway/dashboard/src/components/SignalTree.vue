<script setup>
import { ref } from 'vue'
import { duration, formatValue, isFresh, isLive } from '../format'
import { nodeStatus, splitSource, staleCount } from '../signals'

defineProps({
  tree: { type: Array, required: true },
  now: { type: Number, required: true }
})

const tone = { ok: 'text-ovcs-ok', muted: 'text-ovcs-muted', plain: '' }

const collapsed = ref(new Set())
const sourceKey = (node, source) => `${node.node}/${source.source}`
function toggle(key) {
  const next = new Set(collapsed.value)
  next.has(key) ? next.delete(key) : next.add(key)
  collapsed.value = next
}

// One grid for the header and every row: the name stacks over value and times on narrow screens.
const columns = 'grid grid-cols-[minmax(0,1fr)_auto] gap-x-4 sm:grid-cols-[minmax(0,1fr)_13rem_5rem_6.5rem]'
</script>

<template>
  <section
    v-for="node in tree.filter((n) => n.sources.length)"
    :id="`node-${node.node}`"
    :key="node.node"
    class="mb-8 scroll-mt-28"
  >
    <header class="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1">
      <h2 class="text-xl font-semibold">{{ node.node }}</h2>
      <span class="flex items-center gap-1.5 text-sm" :class="nodeStatus(node).text">
        <span class="inline-block h-2 w-2 rounded-full" :class="nodeStatus(node).dot" />
        {{ nodeStatus(node).label }}
      </span>
      <span v-if="staleCount(node)" class="text-sm text-ovcs-warn">{{ staleCount(node) }} stale</span>
    </header>

    <div class="overflow-hidden rounded border border-ovcs-border bg-ovcs-surface">
      <div
        :class="columns"
        class="hidden border-b border-ovcs-border px-3 py-1.5 text-xs uppercase tracking-wide text-ovcs-muted sm:grid"
      >
        <span>Signal</span>
        <span>Value</span>
        <span class="text-right">Changed</span>
        <span class="text-right">Published</span>
      </div>

      <template v-for="source in node.sources" :key="source.source">
        <button
          type="button"
          class="flex w-full items-center gap-2 border-b border-ovcs-border bg-ovcs-bg px-3 py-1.5 text-left text-sm"
          :title="source.source"
          :aria-expanded="!collapsed.has(sourceKey(node, source))"
          @click="toggle(sourceKey(node, source))"
        >
          <span class="w-3 text-ovcs-muted">{{ collapsed.has(sourceKey(node, source)) ? '▸' : '▾' }}</span>
          <span class="min-w-0 truncate">
            <span class="text-ovcs-muted">{{ splitSource(source.source).namespace }}</span>
            <span class="font-semibold">{{ splitSource(source.source).name }}</span>
          </span>
          <span class="ml-auto shrink-0 text-xs text-ovcs-muted">{{ source.signals.length }}</span>
        </button>

        <template v-if="!collapsed.has(sourceKey(node, source))">
          <div
            v-for="signal in source.signals"
            :key="signal.name"
            :class="[columns, { 'signal-row--live': isLive(signal, now) }]"
            class="signal-row items-baseline border-b border-ovcs-border px-3 py-1.5 text-sm last:border-b-0"
          >
            <span class="col-span-2 flex min-w-0 items-center gap-2 sm:col-span-1">
              <span
                class="inline-block h-1.5 w-1.5 shrink-0 rounded-full"
                :class="isLive(signal, now) ? 'bg-ovcs-accent' : 'bg-transparent'"
              />
              <span class="truncate" :title="signal.name">{{ signal.name }}</span>
            </span>

            <span class="flex min-w-0 items-baseline gap-1 pl-3.5 sm:pl-0">
              <span
                class="truncate font-mono"
                :class="signal.stale === true ? 'text-ovcs-muted' : tone[formatValue(signal.value).tone]"
                :title="formatValue(signal.value).text"
              >
                {{ formatValue(signal.value).text }}
              </span>
              <span v-if="signal.unit" class="shrink-0 text-xs text-ovcs-muted">{{ signal.unit }}</span>
              <span
                v-if="signal.stale === true"
                class="shrink-0 rounded bg-ovcs-warn px-1 text-[10px] font-semibold uppercase text-ovcs-bg"
              >
                stale
              </span>
            </span>

            <span class="flex justify-end gap-3 text-right text-xs text-ovcs-muted sm:contents">
              <span :title="`Changed ${new Date(signal.changed_at).toLocaleString()}`">
                <span class="sm:hidden">changed </span>{{ duration(now - signal.changed_at) }}
              </span>
              <span
                v-if="signal.published_at != null"
                :class="{ 'text-ovcs-warn': signal.stale === true, 'opacity-50': isFresh(signal, now) }"
                :title="`Published ${new Date(signal.published_at).toLocaleString()}`"
              >
                <span class="sm:hidden">published </span>{{ duration(now - signal.published_at) }}
              </span>
              <span v-else title="This node's firmware does not report publications">—</span>
            </span>
          </div>
        </template>
      </template>
    </div>
  </section>
</template>
