<script setup>
import { RouterLink, RouterView } from 'vue-router'
</script>

<template>
  <header>
    <div class="wrapper">
      <nav class="bg-gray-800">
	<div class="mx-auto px-2">
	  <div class="relative flex h-16 items-center justify-between">
      	    <div class="absolute inset-y-0 left-0 flex items-center">
	      <RouterLink to="/" class="text-gray-300 rounded-md px-3 py-2 text-sm font-medium">Home</RouterLink>
	    </div>
          </div>
        </div>
      </nav>
    </div>
  </header>
  <RouterView />
</template>
