const RUNS_ON = { cpu: 'CPU', gpu: 'GPU' }
const IMPLEMENTATIONS = { rust: 'Rust', elixir: 'Elixir', nx: 'Elixir Nx' }
const BACKENDS = { vulkan: 'Vulkan', llvm_cpu: 'LLVM', exla: 'EXLA', evaluator: 'Nx evaluator' }

/** A stage's `compute` as tag labels: where it runs, what it is written in and, for Nx, what compiles it. */
export function computeTags(compute) {
  if (!compute) return []
  return [RUNS_ON[compute.runs_on], IMPLEMENTATIONS[compute.implementation], BACKENDS[compute.backend]].filter(Boolean)
}
