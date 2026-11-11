"""Measures a camera's pose relative to a vision unit's stereo pair.

Reads pairs of images of a chessboard, each taken at one moment by the
stereo pair's left camera, raw, and by the camera, named `left-<n>.<ext>`
and `camera-<n>.<ext>` in one directory, with both cameras' calibrations,
`camera_info` YAMLs. It solves the transform from the left camera to the
camera with OpenCV on the calibrations' intrinsics, held fixed:
`stereoCalibrate` when the camera's `distortion_model` is `plumb_bob`,
`fisheye.stereoCalibrate` when it is `equidistant`; the left camera's
corners are first moved to that model when its own differs. It then
composes the left calibration's rectification rotation, so the pose is
from the rectified left optical frame, the frame of the stereo depth:

    p_camera = rotation * p_left_rectified + translation   (metres)

It writes the pose as YAML for the `:camera` component's `:pose`
(`VisionCore.Camera.Pose`) and prints the RMS reprojection error, in
pixels. Each camera's images are of one size; a calibration of another
size is scaled to them, one without a size taken as it is. Run from the
repository root, with OpenCV and NumPy:

    python3 -I scripts/camera_pose.py --pairs pairs/ \\
        --left stereo_left.yaml --camera hq.yaml \\
        --board 9x6 --square 0.025 --output hq_pose.yaml
"""

import argparse
import re
import sys
from pathlib import Path

import cv2
import numpy as np

MODELS = ("plumb_bob", "equidistant")
PAIR_NAME = re.compile(r"^(left|camera)-(.+)\.(png|jpg|jpeg|bmp)$", re.IGNORECASE)
MINIMUM_PAIRS = 3


def read_matrix(yaml, key):
    """The `data` list of `key` in a `camera_info` YAML, or None."""
    match = re.search(rf"^{key}:.*?data:\s*\[([^\]]*)\]", yaml, re.MULTILINE | re.DOTALL)
    if match is None:
        return None
    return [float(number) for number in match.group(1).split(",") if number.strip()]


def read_calibration(path):
    """A `camera_info` YAML's size, distortion model, K, D and R; R None without one."""
    yaml = Path(path).read_text()
    width = re.search(r"^image_width:\s*(\d+)", yaml, re.MULTILINE)
    height = re.search(r"^image_height:\s*(\d+)", yaml, re.MULTILINE)
    model = re.search(r"^distortion_model:\s*\"?([^\"\n]+)\"?", yaml, re.MULTILINE)
    camera_matrix = read_matrix(yaml, "camera_matrix")
    if width is None or height is None or camera_matrix is None:
        raise ValueError(f"{path}: no image_width, image_height or camera_matrix")
    rectification = read_matrix(yaml, "rectification_matrix")
    return {
        "size": (int(width.group(1)), int(height.group(1))),
        "model": model.group(1).strip() if model else "plumb_bob",
        "K": np.array(camera_matrix, dtype=np.float64).reshape(3, 3),
        "D": np.array(read_matrix(yaml, "distortion_coefficients") or [], dtype=np.float64),
        "R": None
        if rectification is None
        else np.array(rectification, dtype=np.float64).reshape(3, 3),
    }


def scaled_camera_matrix(camera_matrix, calibration_size, image_size):
    """`camera_matrix` of a calibration at `calibration_size` for images of `image_size`.

    A calibration without a size, 0 x 0, is taken as it is, as the vision
    unit takes it.
    """
    if calibration_size[0] == 0 or calibration_size[1] == 0:
        return camera_matrix
    scale_x = image_size[0] / calibration_size[0]
    scale_y = image_size[1] / calibration_size[1]
    scaled = camera_matrix.copy()
    scaled[0, :] *= scale_x
    scaled[1, :] *= scale_y
    return scaled


def distortion(coefficients, model):
    """`coefficients` as OpenCV takes them for `model`: 4 for a fisheye, at least 5 otherwise."""
    count = 4 if model == "equidistant" else max(5, len(coefficients))
    padded = np.zeros(count)
    padded[: min(count, len(coefficients))] = coefficients[:count]
    return padded


def to_model(points, camera_matrix, coefficients, own_model, solve_model):
    """`points`, pixels of a camera of `own_model`, as an undistorted `solve_model` camera's.

    Returns the points and the distortion to solve with: the camera's own
    when the models agree, zero otherwise.
    """
    if own_model == solve_model:
        return points, distortion(coefficients, own_model)
    if solve_model == "equidistant":
        rays = cv2.undistortPoints(points, camera_matrix, distortion(coefficients, own_model))
        return cv2.fisheye.distortPoints(rays, camera_matrix, np.zeros(4)), np.zeros(4)
    pixels = cv2.fisheye.undistortPoints(
        points, camera_matrix, distortion(coefficients, own_model), P=camera_matrix
    )
    return pixels, np.zeros(5)


def solve_pose(board_points, left_points, camera_points, left, camera, image_size):
    """The RMS error, in pixels, and the pose from the raw left camera to the camera.

    `left` and `camera` hold each one's `K`, `D` and `model`, `K` at the
    size of its images. The camera's model is the one solved with.
    """
    model = camera["model"]
    if model not in MODELS or left["model"] not in MODELS:
        raise ValueError(
            f"distortion models {left['model']} and {model}: "
            f"only {', '.join(MODELS)} are supported"
        )

    # The fisheye solver takes float64 points, the pinhole one float32.
    point_type = np.float64 if model == "equidistant" else np.float32
    moved = [
        to_model(points, left["K"], left["D"], left["model"], model) for points in left_points
    ]
    left_points = [points.reshape(-1, 1, 2).astype(point_type) for points, _ in moved]
    left_distortion = moved[0][1]
    camera_points = [points.reshape(-1, 1, 2).astype(point_type) for points in camera_points]
    board_points = [points.reshape(-1, 1, 3).astype(point_type) for points in board_points]
    criteria = (cv2.TERM_CRITERIA_COUNT + cv2.TERM_CRITERIA_EPS, 100, 1e-10)

    if model == "equidistant":
        solved = cv2.fisheye.stereoCalibrate(
            board_points,
            left_points,
            camera_points,
            left["K"],
            left_distortion,
            camera["K"],
            distortion(camera["D"], model),
            image_size,
            flags=cv2.fisheye.CALIB_FIX_INTRINSIC,
            criteria=criteria,
        )
    else:
        solved = cv2.stereoCalibrate(
            board_points,
            left_points,
            camera_points,
            left["K"],
            left_distortion,
            camera["K"],
            distortion(camera["D"], model),
            image_size,
            flags=cv2.CALIB_FIX_INTRINSIC,
            criteria=criteria,
        )

    rms, rotation, translation = solved[0], solved[5], solved[6]
    return rms, rotation, translation.reshape(3)


def from_rectified_left(rotation, translation, rectification):
    """The pose from the rectified left frame, given the one from the raw left frame.

    `rectification` maps the raw left frame to the rectified one,
    `p_rectified = R_rect * p_raw`, so
    `p_camera = rotation * R_rectᵀ * p_rectified + translation`.
    """
    return rotation @ rectification.T, translation


def board_points(columns, rows, square_m):
    """The chessboard's inner corners on its plane, in metres, row by row."""
    grid = np.zeros((rows * columns, 3), np.float64)
    grid[:, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_m
    return grid


def find_corners(path, columns, rows):
    """The chessboard's refined inner corners in the image at `path`, or None, and its size."""
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"{path}: not an image")
    found, corners = cv2.findChessboardCorners(
        image, (columns, rows), flags=cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE
    )
    size = (image.shape[1], image.shape[0])
    if not found:
        return None, size
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 1e-3)
    return cv2.cornerSubPix(image, corners, (5, 5), (-1, -1), criteria), size


def image_pairs(directory):
    """`(left, camera)` image paths of each pair in `directory`, by their shared name."""
    found = {}
    for path in Path(directory).iterdir():
        match = PAIR_NAME.match(path.name)
        if match:
            found.setdefault(match.group(2), {})[match.group(1).lower()] = path
    return [
        (paths["left"], paths["camera"])
        for name, paths in sorted(found.items())
        if "left" in paths and "camera" in paths
    ]


def number(value):
    """`value` as YAML text that reads back as a float."""
    return repr(float(value))


def pose_yaml(rotation, translation, rms):
    """The pose YAML `VisionCore.Camera.Pose` reads."""
    return (
        "# From the rectified left optical frame to the camera's optical frame:\n"
        "# p_camera = rotation * p_left + translation, in metres.\n"
        f"rotation: [{', '.join(number(value) for value in rotation.reshape(9))}]\n"
        f"translation: [{', '.join(number(value) for value in translation.reshape(3))}]\n"
        f"rms_px: {number(rms)}\n"
    )


def board_size(text):
    """The chessboard's inner corners, `(columns, rows)`, from `9x6`."""
    match = re.fullmatch(r"\s*(\d+)\s*[xX]\s*(\d+)\s*", text)
    if match is None or int(match.group(1)) < 2 or int(match.group(2)) < 2:
        raise ValueError(f"--board {text!r}: give the inner corners as <columns>x<rows>, as 9x6")
    return int(match.group(1)), int(match.group(2))


def measure(arguments):
    """Solves the pose from the arguments' pairs, writes it and returns the RMS error."""
    columns, rows = board_size(arguments.board)
    if columns % 2 == rows % 2:
        print(
            f"a {columns}x{rows} board looks the same after a half turn: two cameras turned "
            "far from each other may number its corners apart; one odd and one even count, "
            "such as 9x6, avoids it"
        )
    left_calibration = read_calibration(arguments.left)
    camera_calibration = read_calibration(arguments.camera)
    if left_calibration["R"] is None:
        print(
            f"{arguments.left} has no rectification_matrix: the pose is from the raw left "
            "frame, which is the rectified one only for a calibration that rectifies nothing"
        )
        left_calibration["R"] = np.eye(3)

    left_points, camera_points, left_sizes, camera_sizes = [], [], set(), set()
    pairs = image_pairs(arguments.pairs)
    for left_path, camera_path in pairs:
        left_corners, left_size = find_corners(left_path, columns, rows)
        camera_corners, camera_size = find_corners(camera_path, columns, rows)
        left_sizes.add(left_size)
        camera_sizes.add(camera_size)
        if left_corners is None or camera_corners is None:
            print(f"{left_path.name}, {camera_path.name}: chessboard not found in both, left out")
            continue
        left_points.append(left_corners)
        camera_points.append(camera_corners)

    for side, found in [("left", left_sizes), ("camera", camera_sizes)]:
        if len(found) > 1:
            listed = ", ".join(f"{width}x{height}" for width, height in sorted(found))
            raise ValueError(f"{side} images of several sizes, {listed}: record them at one size")

    if len(left_points) < MINIMUM_PAIRS:
        raise ValueError(
            f"the chessboard is found in both images of {len(left_points)} of {len(pairs)} "
            f"pairs; at least {MINIMUM_PAIRS} are needed"
        )

    (left_size,), (camera_size,) = left_sizes, camera_sizes
    left = dict(
        left_calibration,
        K=scaled_camera_matrix(left_calibration["K"], left_calibration["size"], left_size),
    )
    camera = dict(
        camera_calibration,
        K=scaled_camera_matrix(camera_calibration["K"], camera_calibration["size"], camera_size),
    )
    board = board_points(columns, rows, arguments.square)

    rms, rotation, translation = solve_pose(
        [board] * len(left_points), left_points, camera_points, left, camera, camera_size
    )
    rotation, translation = from_rectified_left(rotation, translation, left_calibration["R"])
    Path(arguments.output).write_text(pose_yaml(rotation, translation, rms))
    print(
        f"{len(left_points)} pairs, RMS reprojection error {rms:.3f} px, "
        f"pose written to {arguments.output}"
    )
    return rms


def parse_arguments(argv):
    """The command line's arguments; see the module's docstring."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--pairs", required=True, help="directory of left-<n> and camera-<n> images"
    )
    parser.add_argument("--left", required=True, help="the stereo left camera's camera_info YAML")
    parser.add_argument("--camera", required=True, help="the camera's camera_info YAML")
    parser.add_argument("--board", required=True, help="the chessboard's inner corners, as 9x6")
    parser.add_argument(
        "--square", required=True, type=float, help="the chessboard's square, in metres"
    )
    parser.add_argument("--output", required=True, help="the pose YAML to write")
    return parser.parse_args(argv)


def main(argv):
    """Measures and writes the pose; 1, with the reason printed, when it cannot."""
    try:
        measure(parse_arguments(argv))
    except (ValueError, OSError, cv2.error) as error:
        print(f"camera_pose: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
