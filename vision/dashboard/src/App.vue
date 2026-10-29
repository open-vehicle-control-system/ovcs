<template>
  <main class="mx-auto max-w-7xl space-y-8 px-4 py-8 sm:px-6 lg:px-8">
    <h1 class="text-2xl font-semibold text-gray-900">Vision</h1>

    <section>
      <StatusCards :status="status.snapshot" />
    </section>

    <section class="grid gap-4 lg:grid-cols-3">
      <Preview v-for="stream in streams" :key="stream" :stream="stream" :socket="dashboardSocket" />
    </section>

    <section class="rounded-lg bg-white p-4 shadow">
      <h2 class="mb-3 text-sm font-medium text-gray-500">Parameters</h2>
      <p v-if="parametersError" class="text-sm text-red-700">{{ parametersError }}</p>
      <Parameters v-else-if="parameters" :parameters="parameters" :save="setParameter" />
    </section>

    <section class="rounded-lg bg-white p-4 shadow">
      <h2 class="mb-3 text-sm font-medium text-gray-500">Settings</h2>
      <p v-if="settingsError" class="text-sm text-red-700">{{ settingsError }}</p>
      <SettingsTree v-else-if="settings" :settings="settings" />
    </section>
  </main>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import StatusCards from './components/StatusCards.vue'
import Preview from './components/Preview.vue'
import SettingsTree from './components/SettingsTree.vue'
import Parameters from './components/Parameters.vue'
import { dashboardSocket } from './services/socket.js'
import { fetchSettings } from './services/settings.js'
import { fetchParameters, setParameter } from './services/parameters.js'
import { useStatus } from './stores/status.js'

const streams = ['left', 'right', 'depth']
const status = useStatus()
const settings = ref(null)
const settingsError = ref(null)
const parameters = ref(null)
const parametersError = ref(null)

onMounted(async () => {
  status.listen(dashboardSocket)
  try {
    settings.value = await fetchSettings()
  } catch (error) {
    settingsError.value = error.message
  }
  try {
    parameters.value = await fetchParameters()
  } catch (error) {
    parametersError.value = error.message
  }
})
</script>
