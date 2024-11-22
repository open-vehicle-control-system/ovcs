import { createRouter, createWebHistory } from 'vue-router'
import NetworkView from '../views/NetworkView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/network',
      name: 'network',
      component: NetworkView
    },
  ]
})

export default router
