import axios from 'axios'

const fetch_calibration_data = () => {
    return axios.get(import.meta.env.VITE_BASE_URL + "/api/calibration", {});
  }

const post_calibration_enabled = (calibrationEnabled) => {
    return axios.post(import.meta.env.VITE_BASE_URL + "/api/calibration", {
      calibrationModeEnabled: calibrationEnabled,
    });
  }
  
export default {
    fetch_calibration_data,
    post_calibration_enabled
}