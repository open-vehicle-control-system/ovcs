<script setup>
import { ref } from 'vue'
import { LIVE_MS } from '../format'

defineProps({
  modelValue: { type: String, required: true },
  connected: { type: Boolean, required: true },
  count: { type: Number, required: true }
})
defineEmits(['update:modelValue'])

const input = ref(null)
defineExpose({ focus: () => input.value?.focus() })
</script>

<template>
  <header class="sticky top-0 z-10 border-b border-ovcs-border bg-ovcs-surface">
    <div class="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
      <h1 class="text-lg font-semibold">OVCS Bus</h1>
      <span class="flex items-center gap-2 text-sm text-ovcs-muted">
        <span
          class="inline-block h-2.5 w-2.5 rounded-full"
          :class="connected ? 'bg-ovcs-ok' : 'bg-ovcs-error'"
        />
        {{ connected ? `Live · ${count} signals` : 'Disconnected, retrying' }}
      </span>
      <input
        ref="input"
        :value="modelValue"
        type="search"
        placeholder="Filter by node, source or name  ( / )"
        aria-label="Filter signals"
        class="w-full rounded border border-ovcs-border bg-ovcs-bg px-3 py-1.5 text-sm text-ovcs-text placeholder:text-ovcs-muted focus:border-ovcs-accent focus:outline-none sm:ml-auto sm:w-80"
        @input="$emit('update:modelValue', $event.target.value)"
      />
    </div>
    <p class="mx-auto max-w-5xl px-4 pb-2 text-xs text-ovcs-muted">
      <span class="text-ovcs-accent">●</span> value changed in the last {{ LIVE_MS / 1000 }} s ·
      <span class="rounded bg-ovcs-warn px-1 text-[10px] font-semibold uppercase text-ovcs-bg">stale</span>
      no longer received by the gateway · faint “Published” times are current
    </p>
  </header>
</template>
