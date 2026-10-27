<script setup>
defineProps({
  modelValue: { type: String, required: true },
  connected: { type: Boolean, required: true },
  count: { type: Number, required: true }
})
defineEmits(['update:modelValue'])
</script>

<template>
  <header class="sticky top-0 border-b border-ovcs-border bg-ovcs-surface">
    <div class="mx-auto flex max-w-5xl items-center gap-4 p-4">
      <h1 class="text-lg font-semibold">OVCS Bus</h1>
      <span class="flex items-center gap-2 text-sm text-ovcs-muted">
        <span
          class="inline-block h-2.5 w-2.5 rounded-full"
          :class="connected ? 'bg-ovcs-ok' : 'bg-ovcs-error'"
        />
        {{ connected ? `Connected, ${count} signals` : 'Disconnected' }}
      </span>
      <input
        :value="modelValue"
        type="search"
        placeholder="Filter node/source/name"
        class="ml-auto w-72 rounded border border-ovcs-border bg-ovcs-bg px-3 py-1.5 text-sm text-ovcs-text placeholder:text-ovcs-muted focus:border-ovcs-accent focus:outline-none"
        @input="$emit('update:modelValue', $event.target.value)"
      />
    </div>
  </header>
</template>
