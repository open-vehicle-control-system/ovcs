import { createRouter, createWebHistory } from 'vue-router'
import DebugView from '../views/DebugView.vue'
import HomeView from '../views/HomeView.vue'
import LaunchpadView from '../views/LaunchpadView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/debug',
      name: 'debug',
      component: DebugView
    },
    {
      path: '/launchpad',
      name: 'launchpad',
      component: LaunchpadView
    },
    {
      path: '/',
      name: "home",
      component: HomeView
    }
  ]
})

export default router
