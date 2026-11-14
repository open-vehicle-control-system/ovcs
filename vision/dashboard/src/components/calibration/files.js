import { downloadYaml } from '../../services/calibration.js'

/** The YAML files of a calibration, a position's one or each camera's; none while one is missing. */
export function yamlFiles(calibration, pose) {
  if (pose) return calibration.pose?.yaml ? [calibration.pose] : []
  return calibration.cameras.length > 0 && calibration.cameras.every((camera) => camera.yaml) ? calibration.cameras : []
}

export const downloadFiles = (files) => {
  for (const { file, yaml } of files) downloadYaml(file, yaml)
}
