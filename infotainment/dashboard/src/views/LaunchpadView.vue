<template>
    <div class="grid grid-cols-8">
        <div v-for="item in navigation" :key="item.name" class="text-center">
            <a :href="item.href" class="text-white  gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold text-center">
            <component :is="item.icon" class="h-28 w-28 shrink-0 text-center launchpad-icon" aria-hidden="true" />
            <p class="text-center">{{ item.name }}</p>
            </a>
        </div>
    </div>
</template>

<script setup>
const props = defineProps(["navigation"]);
const navigation = props.navigation;
</script>

<style scoped>
.launchpad-icon{
    display: block;
    margin: auto;
}

main{
    height: 100vh;
}
</style>