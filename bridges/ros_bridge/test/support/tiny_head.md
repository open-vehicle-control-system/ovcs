# tiny_head.onnx — provenance

A 1.5 KB ONNX model, **written for this repo**, shaped like a yolov8
detection head: `[1, 3, 2, 2]` in, `[1, 84, 4]` out.

It is not a YOLO and it detects nothing. It exists so
`dnn_integration_test.exs` can run `RosBridge.Inference.Dnn` for real —
load, blob, `forward`, decode — without a downloaded model.

## Why not a real yolov8n.onnx

Two reasons, and the licensing one is the decisive half.

YOLOv8 is AGPL-3.0. Vendoring ~12 MB of weights under that licence into
this repo is a decision for whoever owns the licensing, not something a
test fixture should quietly commit. This model is ours, so the tests
carry no model licence at all.

It is also 1.5 KB against 12 MB, and runs in microseconds, so the test
suite stays fast enough to run on every change.

## Why the weights are zero

The convolution weights are all zero and the bias is `channel / 100`,
so the output is exactly the bias broadcast across anchors —
independent of the input. That determinism is the point: it lets the
OpenCL result be compared to the CPU's for **equality** rather than for
plausibility. A model with real weights would only support "both
produced something roughly similar", which is not much of a test of a
GPU path.

The four box attributes are channels 0–3, so every anchor decodes to a
degenerate box (`cx=0, cy=0.01, w=0.02, h=0.03`). Box geometry is
`dnn_test.exs`'s job, against hand-built tensors.

## What it caught

Both of these were real bugs in the backend, and neither is reachable
without running actual inference:

* `Evision.DNN.Net.forward/1` returns a **list** of Mats — one per
  output layer — even for a single-output model. Treating it as a Mat
  raised on the first real frame.
* Evision signals failure by *returning* `{:error, message}` rather
  than raising, so the `rescue` clauses that were supposed to handle a
  bad model never fired.

It also caught a bad *test*: with the backend's default
`input_size: 640`, the 2×2 blob makes the model's fixed reshape fail,
inference returns `[]`, and a per-detection assertion loop passes
vacuously. Hence `input_size: 2` in the fixture and an explicit
`detections != []`.

## Regenerating

Needs `onnx` (any recent version) in a throwaway venv — it is not a
project dependency:

```sh
uv venv /tmp/onnxvenv
uv pip install --python /tmp/onnxvenv/bin/python onnx
/tmp/onnxvenv/bin/python - <<'PY'
import numpy as np, onnx
from onnx import helper, TensorProto, numpy_helper

C_OUT, C_IN, H, W = 84, 3, 2, 2
weights = np.zeros((C_OUT, C_IN, 1, 1), dtype=np.float32)
bias = (np.arange(C_OUT, dtype=np.float32) / 100.0)

nodes = [
    helper.make_node("Conv", ["images", "w", "b"], ["conv"], kernel_shape=[1, 1]),
    helper.make_node("Reshape", ["conv", "shape"], ["output"]),
]
graph = helper.make_graph(
    nodes, "tiny_yolo_head",
    [helper.make_tensor_value_info("images", TensorProto.FLOAT, [1, C_IN, H, W])],
    [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, C_OUT, H * W])],
    [numpy_helper.from_array(weights, "w"),
     numpy_helper.from_array(bias, "b"),
     numpy_helper.from_array(np.array([1, C_OUT, H * W], dtype=np.int64), "shape")],
)
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 12)])
model.ir_version = 8
onnx.checker.check_model(model)
onnx.save(model, "bridges/ros_bridge/test/support/tiny_head.onnx")
PY
```

`ir_version = 8` is set explicitly: onnx 1.22 defaults to a newer IR
version than the OpenCV 4.13 importer in the precompiled Evision
accepts.
