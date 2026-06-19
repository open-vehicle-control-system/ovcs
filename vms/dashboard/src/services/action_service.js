import axios from 'axios'

const createAction = (action) => {
    const baseParameters = {
      module: action.module,
      action: action.action
    };
    const parameters = {...baseParameters, ...action.extraParameters}
    if (action.inputValue !== undefined && action.inputValue !== null && action.inputValue !== "") {
      parameters.value = String(action.inputValue)
    }
    return axios.post(import.meta.env.VITE_BASE_URL + "/api/actions", parameters);
  }

export default {
  createAction,
}