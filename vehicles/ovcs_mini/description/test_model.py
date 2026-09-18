"""Check expanded geometry, including steering clearances, without a simulator."""

import math
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

import xacro

DESCRIPTION = Path(__file__).resolve().parent
COMMON = DESCRIPTION.parents[2] / "compose/local/simulation/common"


def vector(element, attribute):
    return tuple(float(v) for v in element.attrib[attribute].split())


class ModelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.robot = ET.fromstring(
            xacro.process_file(
                str(DESCRIPTION / "ovcs_mini.urdf.xacro"),
                mappings={"common_dir": str(COMMON)},
            ).toxml()
        )
        cls.joints = {j.get("name"): j for j in cls.robot.findall("joint")}
        cls.links = {link.get("name"): link for link in cls.robot.findall("link")}
        cls.controller = cls.robot.find(".//plugin[@name='gz::sim::systems::AckermannSteering']")

    def test_mass_budget_and_positive_inertias(self):
        masses = [float(m.get("value")) for m in self.robot.findall(".//inertial/mass")]
        self.assertAlmostEqual(sum(masses), 2.41)
        self.assertTrue(all(m > 0 for m in masses))
        for inertia in self.robot.findall(".//inertia"):
            diagonal = [float(inertia.get(k)) for k in ("ixx", "iyy", "izz")]
            self.assertTrue(all(i > 0 for i in diagonal))
            self.assertLessEqual(2 * max(diagonal), sum(diagonal) + 1e-12)

    def test_controller_geometry_matches_joint_locations(self):
        left = vector(self.joints["front_left_steering_joint"].find("origin"), "xyz")
        right = vector(self.joints["front_right_steering_joint"].find("origin"), "xyz")
        rear = vector(self.joints["rear_left_wheel_joint"].find("origin"), "xyz")
        self.assertAlmostEqual(
            left[1] - right[1], float(self.controller.findtext("kingpin_width"))
        )
        self.assertAlmostEqual(
            left[1] - right[1], float(self.controller.findtext("wheel_separation"))
        )
        self.assertAlmostEqual(left[0] - rear[0], float(self.controller.findtext("wheel_base")))

    def test_tight_turn_targets_fit_both_joint_stops(self):
        length = float(self.controller.findtext("wheel_base"))
        width = float(self.controller.findtext("kingpin_width"))
        radius = length / math.sin(float(self.controller.findtext("steering_limit")))
        self.assertAlmostEqual(radius, length / math.tan(0.52))
        for sign in (-1, 1):
            for side, name in [(1, "left"), (-1, "right")]:
                angle = math.atan(length / (sign * radius - side * width / 2))
                limit = self.joints[f"front_{name}_steering_joint"].find("limit")
                self.assertGreaterEqual(angle, float(limit.get("lower")) - 1e-12)
                self.assertLessEqual(angle, float(limit.get("upper")) + 1e-12)

    def test_front_tyres_clear_chassis_through_steering_range(self):
        for side in ("left", "right"):
            joint = self.joints[f"front_{side}_steering_joint"]
            centre = vector(joint.find("origin"), "xyz")
            stop = float(joint.find("limit").get("upper"))
            tyre = self.links[f"front_{side}_wheel"].find("collision/geometry/cylinder")
            radius, half_width = float(tyre.get("radius")), float(tyre.get("length")) / 2
            for i in range(101):
                angle = stop * (2 * i / 100 - 1)
                extent = (
                    radius * abs(math.cos(angle)) + half_width * abs(math.sin(angle)),
                    radius * abs(math.sin(angle)) + half_width * abs(math.cos(angle)),
                    radius,
                )
                for collision in self.links["chassis"].findall("collision"):
                    position = vector(collision.find("origin"), "xyz")
                    size = vector(collision.find("geometry/box"), "size")
                    overlap = all(
                        abs(centre[k] - position[k]) < extent[k] + size[k] / 2 for k in range(3)
                    )
                    self.assertFalse(overlap, (side, angle, collision.get("name")))

    def test_tray_visuals_match_collision_shapes(self):
        link = self.links["chassis"]
        for collision in link.findall("collision"):
            visual = link.find(f"visual[@name='{collision.get('name')}']")
            self.assertIsNotNone(visual)
            self.assertEqual(
                vector(visual.find("origin"), "xyz"), vector(collision.find("origin"), "xyz")
            )
            self.assertEqual(
                vector(visual.find("geometry/box"), "size"),
                vector(collision.find("geometry/box"), "size"),
            )

    def test_default_preview_has_no_shell_and_all_meshes_exist(self):
        names = {v.get("name") for v in self.robot.findall(".//visual")}
        self.assertFalse(names & {"body", "windows", "trim", "stripe"})
        for mesh in self.robot.findall(".//mesh"):
            self.assertTrue(Path(mesh.get("filename").removeprefix("file://")).is_file())

    def test_sensor_mass_and_stereo_frames(self):
        left = vector(self.joints["stereo_left_joint"].find("origin"), "xyz")
        right = vector(self.joints["stereo_right_joint"].find("origin"), "xyz")
        self.assertAlmostEqual(left[1] - right[1], 0.090)
        self.assertEqual(left[0], right[0])
        self.assertEqual(left[2], right[2])
        for name in ("left", "right"):
            # Rz(yaw) Ry(pitch) Rx(roll) maps optical +z to body +x.
            roll, pitch, yaw = vector(
                self.joints[f"stereo_{name}_optical_joint"].find("origin"), "rpy"
            )
            self.assertAlmostEqual(pitch, 0)
            optical_z = (
                math.sin(yaw) * math.sin(roll),
                -math.cos(yaw) * math.sin(roll),
                math.cos(roll),
            )
            for actual, expected in zip(optical_z, (1, 0, 0)):
                self.assertAlmostEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
