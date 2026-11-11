"""Recovers known poses from synthetic chessboard views with camera_pose.py."""

import contextlib
import importlib.util
import io
import re
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

spec = importlib.util.spec_from_file_location(
    "camera_pose", Path(__file__).resolve().parents[1] / "camera_pose.py"
)
camera_pose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(camera_pose)

# Inner corners odd by even: the board reads differently after a half turn.
COLUMNS, ROWS, SQUARE_M = 9, 6, 0.04
IMAGE_SIZE = (1014, 760)
IDENTITY = np.eye(3)


def rotation(x, y, z):
    """The rotation of the Rodrigues vector (x, y, z), in radians."""
    return cv2.Rodrigues(np.array([x, y, z], dtype=np.float64))[0]


def project(points, rotation_matrix, translation, camera):
    """`points` seen by `camera`, placed at `rotation_matrix`, `translation` from them."""
    rvec = cv2.Rodrigues(rotation_matrix)[0]
    tvec = translation.reshape(3, 1)
    if camera["model"] == "equidistant":
        projected, _ = cv2.fisheye.projectPoints(
            points.reshape(-1, 1, 3),
            rvec,
            tvec,
            camera["K"],
            camera_pose.distortion(camera["D"], "equidistant"),
        )
    else:
        projected, _ = cv2.projectPoints(points, rvec, tvec, camera["K"], camera["D"])
    return projected.reshape(-1, 1, 2)


LEFT = {
    "model": "plumb_bob",
    "K": np.array([[700.0, 0.0, 500.0], [0.0, 702.0, 380.0], [0.0, 0.0, 1.0]]),
    "D": np.array([-0.12, 0.04, 0.001, -0.0005, -0.006]),
}
LEFT_EQUIDISTANT = {
    "model": "equidistant",
    "K": np.array([[420.0, 0.0, 505.0], [0.0, 421.0, 378.0], [0.0, 0.0, 1.0]]),
    "D": np.array([0.03, -0.01, 0.004, -0.001]),
}
CAMERA_PLUMB_BOB = {
    "model": "plumb_bob",
    "K": np.array([[880.0, 0.0, 510.0], [0.0, 878.0, 372.0], [0.0, 0.0, 1.0]]),
    "D": np.array([-0.2, 0.08, -0.0008, 0.0012, -0.01]),
}
CAMERA_EQUIDISTANT = {
    "model": "equidistant",
    "K": np.array([[400.0, 0.0, 507.0], [0.0, 401.0, 383.0], [0.0, 0.0, 1.0]]),
    "D": np.array([0.05, -0.02, 0.006, -0.002]),
}

# The left calibration's rectification: raw left frame to rectified.
RECTIFICATION = rotation(0.01, -0.02, 0.015)
# The pose to recover, from the rectified left frame: the camera 12 cm right, 3 cm down, turned.
TRUE_ROTATION = rotation(0.03, -0.08, 0.05)
TRUE_TRANSLATION = np.array([-0.12, 0.03, 0.01])


def synthetic_views(left, camera):
    """Board corners in both cameras, seen from the raw left camera's pose to the camera."""
    raw_rotation = TRUE_ROTATION @ RECTIFICATION
    board = camera_pose.board_points(COLUMNS, ROWS, SQUARE_M)
    centre = np.array([(COLUMNS - 1) * SQUARE_M / 2, (ROWS - 1) * SQUARE_M / 2, 0.0])
    left_points, camera_points = [], []
    for tilt_x, tilt_y, turn, x, y, distance in [
        (0.0, 0.0, 0.0, 0.0, 0.0, 1.0),
        (0.4, 0.0, 0.1, -0.2, 0.0, 1.2),
        (-0.4, 0.2, -0.1, 0.2, 0.1, 1.1),
        (0.1, 0.5, 0.2, 0.1, -0.15, 0.9),
        (0.0, -0.5, 0.0, -0.1, 0.15, 1.4),
        (0.3, 0.3, 0.3, 0.25, -0.1, 1.3),
        (-0.3, -0.3, -0.2, -0.25, 0.1, 1.0),
        (0.2, -0.2, 0.0, 0.0, 0.2, 0.8),
    ]:
        board_rotation = rotation(tilt_x, tilt_y, turn)
        board_translation = np.array([x, y, distance]) - board_rotation @ centre
        left_points.append(project(board, board_rotation, board_translation, left))
        camera_points.append(
            project(
                board,
                raw_rotation @ board_rotation,
                raw_rotation @ board_translation + TRUE_TRANSLATION,
                camera,
            )
        )
    return [board] * len(left_points), left_points, camera_points


class FromRectifiedLeftTest(unittest.TestCase):
    def test_composes_the_rectification_into_the_rotation_and_keeps_the_translation(self):
        raw_rotation = TRUE_ROTATION @ RECTIFICATION

        composed, translation = camera_pose.from_rectified_left(
            raw_rotation, TRUE_TRANSLATION, RECTIFICATION
        )

        np.testing.assert_allclose(composed, TRUE_ROTATION, atol=1e-12)
        np.testing.assert_array_equal(translation, TRUE_TRANSLATION)
        point_rectified = np.array([0.3, -0.2, 2.0])
        point_raw = RECTIFICATION.T @ point_rectified
        np.testing.assert_allclose(
            composed @ point_rectified + translation,
            raw_rotation @ point_raw + TRUE_TRANSLATION,
            atol=1e-12,
        )


class SolvePoseTest(unittest.TestCase):
    def recovers(self, left, camera):
        boards, left_points, camera_points = synthetic_views(left, camera)

        rms, raw_rotation, translation = camera_pose.solve_pose(
            boards, left_points, camera_points, left, camera, IMAGE_SIZE
        )
        pose_rotation, pose_translation = camera_pose.from_rectified_left(
            raw_rotation, translation, RECTIFICATION
        )

        self.assertLess(rms, 1e-3)
        np.testing.assert_allclose(pose_rotation, TRUE_ROTATION, atol=1e-6)
        np.testing.assert_allclose(pose_translation, TRUE_TRANSLATION, atol=1e-6)

    def test_plumb_bob_camera(self):
        self.recovers(LEFT, CAMERA_PLUMB_BOB)

    def test_equidistant_camera_beside_a_plumb_bob_left(self):
        self.recovers(LEFT, CAMERA_EQUIDISTANT)

    def test_plumb_bob_camera_beside_an_equidistant_left(self):
        self.recovers(LEFT_EQUIDISTANT, CAMERA_PLUMB_BOB)

    def test_equidistant_camera_beside_an_equidistant_left(self):
        self.recovers(LEFT_EQUIDISTANT, CAMERA_EQUIDISTANT)

    def test_refuses_another_distortion_model(self):
        boards, left_points, camera_points = synthetic_views(LEFT, CAMERA_PLUMB_BOB)
        rational = dict(CAMERA_PLUMB_BOB, model="rational_polynomial")

        with self.assertRaisesRegex(ValueError, "rational_polynomial"):
            camera_pose.solve_pose(boards, left_points, camera_points, LEFT, rational, IMAGE_SIZE)


def calibration_yaml(camera, size, rectification=IDENTITY):
    """A camera_info YAML of `camera` at `size`; without `rectification_matrix` when None."""
    projection = np.hstack([camera["K"], np.zeros((3, 1))])

    def data(matrix):
        return ", ".join(repr(float(value)) for value in np.ravel(matrix))

    rectification_yaml = (
        ""
        if rectification is None
        else f"rectification_matrix:\n  rows: 3\n  cols: 3\n  data: [{data(rectification)}]\n"
    )
    return (
        f"image_width: {size[0]}\nimage_height: {size[1]}\ncamera_name: test\n"
        f"camera_matrix:\n  rows: 3\n  cols: 3\n  data: [{data(camera['K'])}]\n"
        f"distortion_model: {camera['model']}\n"
        f"distortion_coefficients:\n  rows: 1\n  cols: {len(camera['D'])}\n"
        f"  data: [{data(camera['D'])}]\n"
        f"{rectification_yaml}"
        f"projection_matrix:\n  rows: 3\n  cols: 4\n  data: [{data(projection)}]\n"
    )


def render_chessboard(camera, board_rotation, board_translation, size):
    """A grey image of the chessboard seen by the undistorted pinhole `camera`."""
    pixels_per_square = 40
    margin = pixels_per_square
    texture_size = (
        (COLUMNS + 1) * pixels_per_square + 2 * margin,
        (ROWS + 1) * pixels_per_square + 2 * margin,
    )
    texture = np.full((texture_size[1], texture_size[0]), 255, np.uint8)
    for row in range(ROWS + 1):
        for column in range(COLUMNS + 1):
            if (row + column) % 2 == 0:
                top = margin + row * pixels_per_square
                left = margin + column * pixels_per_square
                texture[top : top + pixels_per_square, left : left + pixels_per_square] = 0
    # Texture pixel to board metres: the first inner corner is the board's origin.
    texture_to_board = np.array(
        [
            [
                SQUARE_M / pixels_per_square,
                0,
                -(margin + pixels_per_square) * SQUARE_M / pixels_per_square,
            ],
            [
                0,
                SQUARE_M / pixels_per_square,
                -(margin + pixels_per_square) * SQUARE_M / pixels_per_square,
            ],
            [0, 0, 1],
        ]
    )
    board_to_image = camera["K"] @ np.column_stack(
        [board_rotation[:, 0], board_rotation[:, 1], board_translation]
    )
    return cv2.warpPerspective(
        texture,
        board_to_image @ texture_to_board,
        size,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=255,
    )


RENDERED_LEFT = dict(LEFT, D=np.zeros(5))
RENDERED_CAMERA = dict(CAMERA_PLUMB_BOB, D=np.zeros(5))


def write_rendered_pairs(pairs, true_rotation, camera_sizes):
    """Writes a rendered pair into `pairs` for each camera image size of `camera_sizes`."""
    raw_rotation = true_rotation @ RECTIFICATION
    centre = np.array([(COLUMNS - 1) * SQUARE_M / 2, (ROWS - 1) * SQUARE_M / 2, 0.0])
    board_poses = [
        (0.0, 0.0, 0.0, 0.0, 0.8),
        (0.4, 0.1, -0.05, 0.0, 0.9),
        (-0.3, 0.3, 0.05, 0.03, 0.85),
        (0.2, -0.4, 0.0, -0.03, 0.9),
    ]
    for index, ((tilt_x, tilt_y, x, y, distance), camera_size) in enumerate(
        zip(board_poses, camera_sizes)
    ):
        board_rotation = rotation(tilt_x, tilt_y, 0.05 * index)
        board_translation = np.array([x, y, distance]) - board_rotation @ centre
        cv2.imwrite(
            str(pairs / f"left-{index:04d}.png"),
            render_chessboard(RENDERED_LEFT, board_rotation, board_translation, IMAGE_SIZE),
        )
        cv2.imwrite(
            str(pairs / f"camera-{index:04d}.png"),
            render_chessboard(
                RENDERED_CAMERA,
                raw_rotation @ board_rotation,
                raw_rotation @ board_translation + TRUE_TRANSLATION,
                camera_size,
            ),
        )


def run_command(directory, board=f"{COLUMNS}x{ROWS}"):
    """The status and printed output of the command on `directory`'s pairs and calibrations."""
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = camera_pose.main(
            [
                "--pairs",
                str(directory / "pairs"),
                "--left",
                str(directory / "left.yaml"),
                "--camera",
                str(directory / "camera.yaml"),
                "--board",
                board,
                "--square",
                str(SQUARE_M),
                "--output",
                str(directory / "pose.yaml"),
            ]
        )
    return status, output.getvalue()


def read_pose(path):
    """The rotation, translation and RMS of the pose YAML at `path`."""
    yaml = path.read_text()

    def numbers(key):
        return [
            float(value)
            for value in re.search(rf"^{key}: \[(.*)\]$", yaml, re.M).group(1).split(",")
        ]

    rms = float(re.search(r"^rms_px: (.*)$", yaml, re.M).group(1))
    return np.reshape(numbers("rotation"), (3, 3)), np.array(numbers("translation")), rms


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        (self.directory / "pairs").mkdir()
        self.addCleanup(self.temporary.cleanup)

    def write_calibrations(self, left_rectification=RECTIFICATION, camera_size=None):
        """Writes both calibrations, the camera's at twice the images' size by default."""
        (self.directory / "left.yaml").write_text(
            calibration_yaml(RENDERED_LEFT, IMAGE_SIZE, left_rectification)
        )
        full_size_camera = dict(
            RENDERED_CAMERA, K=np.diag([2.0, 2.0, 1.0]) @ RENDERED_CAMERA["K"]
        )
        camera_size = camera_size or (IMAGE_SIZE[0] * 2, IMAGE_SIZE[1] * 2)
        camera = RENDERED_CAMERA if camera_size == (0, 0) else full_size_camera
        (self.directory / "camera.yaml").write_text(calibration_yaml(camera, camera_size))

    def test_measures_the_pose_from_rendered_pairs_with_a_calibration_of_twice_their_size(self):
        write_rendered_pairs(self.directory / "pairs", TRUE_ROTATION, [IMAGE_SIZE] * 4)
        self.write_calibrations()

        status, output = run_command(self.directory)

        self.assertEqual(status, 0, output)
        pose_rotation, pose_translation, rms = read_pose(self.directory / "pose.yaml")
        np.testing.assert_allclose(pose_rotation, TRUE_ROTATION, atol=5e-3)
        np.testing.assert_allclose(pose_translation, TRUE_TRANSLATION, atol=5e-3)
        self.assertLess(rms, 0.5)
        self.assertIn("RMS reprojection error", output)

    def test_an_asymmetric_board_orders_the_corners_alike_for_a_camera_upside_down(self):
        upside_down = rotation(0.0, 0.0, np.pi - 0.05)
        write_rendered_pairs(self.directory / "pairs", upside_down, [IMAGE_SIZE] * 4)
        self.write_calibrations()

        status, output = run_command(self.directory)

        self.assertEqual(status, 0, output)
        pose_rotation, pose_translation, rms = read_pose(self.directory / "pose.yaml")
        np.testing.assert_allclose(pose_rotation, upside_down, atol=5e-3)
        np.testing.assert_allclose(pose_translation, TRUE_TRANSLATION, atol=5e-3)
        self.assertLess(rms, 0.5)

    def test_takes_a_calibration_without_a_size_as_it_is(self):
        write_rendered_pairs(self.directory / "pairs", TRUE_ROTATION, [IMAGE_SIZE] * 4)
        self.write_calibrations(camera_size=(0, 0))

        status, output = run_command(self.directory)

        self.assertEqual(status, 0, output)
        _rotation, pose_translation, _rms = read_pose(self.directory / "pose.yaml")
        np.testing.assert_allclose(pose_translation, TRUE_TRANSLATION, atol=5e-3)

    def test_warns_when_the_left_calibration_has_no_rectification(self):
        write_rendered_pairs(self.directory / "pairs", TRUE_ROTATION, [IMAGE_SIZE] * 4)
        self.write_calibrations(left_rectification=None)

        status, output = run_command(self.directory)

        self.assertEqual(status, 0, output)
        self.assertIn("has no rectification_matrix", output)

    def test_refuses_pairs_of_several_sizes(self):
        sizes = [IMAGE_SIZE, IMAGE_SIZE, (1000, 750), IMAGE_SIZE]
        write_rendered_pairs(self.directory / "pairs", TRUE_ROTATION, sizes)
        self.write_calibrations()

        status, output = run_command(self.directory)

        self.assertEqual(status, 1)
        self.assertIn("camera images of several sizes", output)
        self.assertFalse((self.directory / "pose.yaml").exists())

    def test_refuses_a_malformed_board(self):
        self.write_calibrations()

        status, output = run_command(self.directory, board="9 by 6")

        self.assertEqual(status, 1)
        self.assertIn("--board", output)

    def test_fails_with_too_few_pairs(self):
        self.write_calibrations()

        status, output = run_command(self.directory)

        self.assertEqual(status, 1)
        self.assertIn("at least 3 are needed", output)
        self.assertFalse((self.directory / "pose.yaml").exists())


if __name__ == "__main__":
    unittest.main()
