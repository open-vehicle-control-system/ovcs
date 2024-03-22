<template>
    <div class="grid grid-cols-6 gap-2">
        <div v-for="item in navigation" :key="item.name" class="h-24 w-24 text-center">
            <a :href="item.href" class="text-black rounded-md text-sm leading-6 font-semibold text-center">
                <div :class="[item.color, 'rounded rounded-3xl p-2']">
                    <component :is="item.icon" class="h-20 w-20 text-center stroke-1 launchpad-icon" aria-hidden="true" />
                </div>
                <p class="text-center p-3 text-white">{{ item.name }}</p>
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