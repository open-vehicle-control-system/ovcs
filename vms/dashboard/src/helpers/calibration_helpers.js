import axios from 'axios'

const fetch_calibration_data = () => {
    return axios.get("/api/calibration", {});
  }

const post_calibration_enabled = (calibrationEnabled) => {
    return axios.post("/api/calibration", {
      calibrationModeEnabled: calibrationEnabled,
    });
  }
  
export default {
    fetch_calibration_data,
    post_calibration_enabled
}