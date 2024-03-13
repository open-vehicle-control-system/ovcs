import axios from 'axios'

const set_transmission_interval = (interval) => {
    return axios.post(import.meta.env.VITE_BASE_URL + "/api/car-controls-settings", {
      interval: interval,
    });
  }

export default {
    set_transmission_interval,
}