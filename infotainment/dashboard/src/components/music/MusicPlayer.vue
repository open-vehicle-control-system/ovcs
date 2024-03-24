<template>
    <div class="grid grid-rows-3 gap-4 h-full">
        <div class="grid grid-cols-3 row-span-2">
            <div class="inline pl-12 mt-8">
                <img src="/tipik.png" />
            </div>
            <div class="inline col-span-2 p-4 ml-6">
                <h3 class="text-3xl mt-6">Tipik</h3>
                <p class="text-2xl">Green Day</p>
                <p class="text-xl">Basket Case</p>
            </div>
        </div>

        <div class="grid grid-cols-4 p-2">
            <IconPrevious class="h-12 m-auto"></IconPrevious>
            <IconPlay class="h-12 m-auto"></IconPlay>
            <IconPause class="h-12 m-auto"></IconPause>
            <IconNext class="h-12 m-auto"></IconNext>
        </div>
    </div>
</template>

<script setup>
import IconMusic from "../icons/IconMusic.vue"
import IconPlay from "../icons/IconPlay.vue"
import IconPause from "../icons/IconPause.vue"
import IconPrevious from "../icons/IconPrevious.vue"
import IconNext from "../icons/IconNext.vue"
</script>