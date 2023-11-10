<script setup>
</script>

<template>
  <div class="container mx-auto">
    <h2 class="text-4xl py-10">Status: {{content.status}}</h2>
  </div>
</template>
<script>
export default {
  name: "App",
  components: {
  },
  data: () => ({
    content: {status: "Loading ..."},
  }),
  methods: {
    async getData() {
      try {
        let response = await fetch("http://localhost:4000/api/status");
        this.content = await response.json();;
      } catch (error) {
        console.log(error);
      }
    },
  },
  created() {
    setTimeout(() => this.getData(), 2000);
  },

};
</script>
