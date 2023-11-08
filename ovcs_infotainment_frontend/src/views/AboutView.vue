<template>
  <div class="about">
    <h1>OVCS is a Spin42 Engineering project!</h1>
    <h2>Status: {{content.status}}</h2>
  </div>
</template>

<style>
@media (min-width: 1024px) {
  .about {
    min-height: 100vh;
    display: flex;
    align-items: center;
  }
}
</style>

<script>
export default {
  data() {
    return {
      content: {status: "Loading ..."},
    };
  },

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