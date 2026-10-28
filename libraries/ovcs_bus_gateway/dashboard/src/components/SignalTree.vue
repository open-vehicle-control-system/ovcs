<script setup>
import { OvcsBadge, OvcsCard, OvcsDot, OvcsRow, OvcsStatus } from '@ovcs/ui/vue'
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
      <OvcsStatus :tone="nodeStatus(node).tone" class="text-sm">{{ nodeStatus(node).label }}</OvcsStatus>
      <span v-if="staleCount(node)" class="text-sm text-ovcs-warn">{{ staleCount(node) }} stale</span>
    </header>

    <OvcsCard class="overflow-hidden p-0">
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
          <OvcsRow
            v-for="signal in source.signals"
            :key="signal.name"
            :live="isLive(signal, now)"
            :class="columns"
            class="items-baseline border-b border-ovcs-border px-3 py-1.5 text-sm last:border-b-0"
          >
            <span class="col-span-2 flex min-w-0 items-center gap-2 sm:col-span-1">
              <OvcsDot :on="isLive(signal, now)" />
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
              <OvcsBadge v-if="signal.stale === true" tone="warn" class="shrink-0">stale</OvcsBadge>
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
          </OvcsRow>
        </template>
      </template>
    </OvcsCard>
  </section>
</template>
