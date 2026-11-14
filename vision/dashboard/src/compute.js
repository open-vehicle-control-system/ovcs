const RUNS_ON = { cpu: 'CPU', gpu: 'GPU', npu: 'NPU' }
const IMPLEMENTATIONS = { rust: 'Rust', elixir: 'Elixir', nx: 'Elixir Nx' }
const BACKENDS = { vulkan: 'Vulkan', llvm_cpu: 'LLVM', exla: 'EXLA', evaluator: 'Nx evaluator' }

/** Where a stage's `compute` runs, as its tag, `null` when it does not say. */
export const runsOnTag = (compute) => RUNS_ON[compute?.runsOn] ?? null

/** A stage's `compute` as tag labels: where it runs, what it is written in and, for Nx, what compiles it. */
export function computeTags(compute) {
  if (!compute) return []
  return [RUNS_ON[compute.runsOn], IMPLEMENTATIONS[compute.implementation], BACKENDS[compute.backend]].filter(Boolean)
}
