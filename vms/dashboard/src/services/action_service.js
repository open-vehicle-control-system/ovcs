import axios from 'axios'

const createAction = (action) => {
    const baseParameters = {
      module: action.module,
      action: action.action
    };
    const parameters = {...baseParameters, ...action.extraParameters}
    return axios.post(import.meta.env.VITE_BASE_URL + "/api/actions", parameters);
  }

export default {
  createAction,
}