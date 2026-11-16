# The Mini's segmentation model

`OvcsMini.Vision.Composer` segments the left camera's 1152 × 576 band with
DDRNet-23-slim, compiled for the Hailo-8 at that size:
`priv/models/ddrnet_23_slim_576x1152.hef`. Hailo's model zoo compiles it
for 1024 × 2048 only; enlarging the band to that input, and the tensors
the larger compilation parks in the host's memory, cost the Pi 5 more
memory bandwidth than the cameras and the depth leave it.

The HEF is not committed and not yet fetchable: build it as below.

## Licence

DDRNet's code is MIT. Its weights are trained on Cityscapes, whose terms
allow non-commercial use only.

## Build it

You need an x86-64 Linux machine, Python 3.10 and Hailo's Dataflow
Compiler **3.34.0**, the version HailoRT 4.24.0 on the Mini runs
(Hailo model zoo v2.20.0): download its wheel from Hailo's Developer
Zone, which takes an account. No GPU is needed.

1. Get the model zoo's ONNX
   (`ddrnet_23_slim.zip`, sha256
   `9a4b519d1708bb992436720e2b8e504b2d91e5bbfafdb81f00f08da4fc64a8a8`) and
   rewrite it for the band:

        curl -LO https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/Segmentation/Cityscapes/ddrnet_23_slim/pretrained/2026-10-05/ddrnet_23_slim.zip
        unzip ddrnet_23_slim.zip
        uv run --with onnx python ../../../scripts/hailo/resize_onnx.py \
          ddrnet_23_slim.onnx ddrnet_23_slim_576x1152.onnx 576 1152

2. Collect calibration frames: at least 64 JPEGs of the left camera's
   `half_jpeg` output, in one directory, of the scenes the Mini will
   segment. The compiler quantises the model on their bottom bands.

3. Compile it, in a virtual environment holding the Dataflow Compiler,
   then copy the HEF to `priv/models/`:

        uv venv --python 3.10 dfc
        VIRTUAL_ENV=dfc uv pip install hailo_dataflow_compiler-3.34.0-py3-none-linux_x86_64.whl
        dfc/bin/python ../../../scripts/hailo/compile_hef.py \
          ddrnet_23_slim_576x1152.onnx ddrnet_23_slim ddrnet_23_slim_576x1152.alls \
          <calibration dir> ../priv/models/ddrnet_23_slim_576x1152.hef

   The compilation takes about 15 minutes on 20 cores.

`ddrnet_23_slim_576x1152.alls` is the model zoo's script for the model,
without its upsampling to the input's size: the argmax runs on the 1/8
scores, one class id per 8 × 8 cell, which `hailo` keeps as they are.

## Check it

On a Cityscapes street image, the HEF on the Mini's Hailo-8 gives the
class of 98.8 % of the cells the float model gives at 576 × 1152, road
IoU 0.99; that model agrees with the zoo's 1024 × 2048 one on 94.5 % of
the pixels, road IoU 0.98, thin objects (poles, signs, people) lower.
