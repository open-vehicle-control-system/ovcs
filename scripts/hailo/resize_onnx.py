"""Rewrites a segmentation ONNX for another input size.

A simplified export fixes the sizes of its Resize nodes for the input it was
exported at. Each is scaled with the input, as is the output: a fully
convolutional model then runs at the new size unchanged. Every Resize size and
the output must be a whole fraction of the input on both sides, which the new
size must keep.

usage: python resize_onnx.py <source.onnx> <target.onnx> <height> <width>
"""

import sys

import onnx
from onnx import numpy_helper


def fraction(name, size, original, new):
    """The factor `size` divides `original` by, which must divide `new` too."""
    (old_height, old_width), (height, width) = original, new
    factor = old_height // size[0]
    if size[0] * factor != old_height or size[1] * factor != old_width:
        sys.exit(f"{name}: {size[0]}x{size[1]} is no whole fraction of {old_height}x{old_width}")
    if height % factor or width % factor:
        sys.exit(f"{name}: 1/{factor} of {height}x{width} is not whole")
    return factor


def resize(source, target, height, width):
    model = onnx.load(source)
    graph = model.graph
    input_dims = graph.input[0].type.tensor_type.shape.dim
    original = (input_dims[2].dim_value, input_dims[3].dim_value)
    sizes = {tensor.name: tensor for tensor in graph.initializer}
    rewritten = set()
    for node in graph.node:
        # Several Resize nodes can share one sizes tensor.
        if node.op_type != "Resize" or node.input[3] in rewritten:
            continue
        rewritten.add(node.input[3])
        tensor = sizes[node.input[3]]
        value = numpy_helper.to_array(tensor).copy()
        factor = fraction(node.name, value[2:4], original, (height, width))
        value[2], value[3] = height // factor, width // factor
        tensor.CopyFrom(numpy_helper.from_array(value, tensor.name))
        print(f"{node.name}: {value.tolist()}")

    input_dims[2].dim_value, input_dims[3].dim_value = height, width
    output_dims = graph.output[0].type.tensor_type.shape.dim
    output = (output_dims[2].dim_value, output_dims[3].dim_value)
    factor = fraction("output", output, original, (height, width))
    output_dims[2].dim_value, output_dims[3].dim_value = height // factor, width // factor
    del graph.value_info[:]
    model = onnx.shape_inference.infer_shapes(model)
    onnx.checker.check_model(model)
    onnx.save(model, target)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    source, target, height, width = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    resize(source, target, height, width)


if __name__ == "__main__":
    main()
