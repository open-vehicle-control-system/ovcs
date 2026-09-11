"""Preview the Mini's visual geometry and joints without running physics."""

import xml.etree.ElementTree as ET
from pathlib import Path

import xacro
from launch import LaunchDescription
from launch_ros.actions import Node


def split_preview_visuals(description):
    """Give each visual its own fixed link for RViz's per-link materials."""
    robot = ET.fromstring(description)
    for link in list(robot.findall("link")):
        for index, visual in enumerate(link.findall("visual")[1:], start=1):
            name = f"{link.attrib['name']}_preview_visual_{index}"
            link.remove(visual)
            child = ET.SubElement(robot, "link", name=name)
            child.append(visual)
            joint = ET.SubElement(robot, "joint", name=f"{name}_joint", type="fixed")
            ET.SubElement(joint, "parent", link=link.attrib["name"])
            ET.SubElement(joint, "child", link=name)
    return ET.tostring(robot, encoding="unicode")


def generate_launch_description():
    description_dir = Path(__file__).resolve().parent
    repository = description_dir.parents[2]
    description = xacro.process_file(
        str(description_dir / "ovcs_mini.urdf.xacro"),
        mappings={
            "common_dir": str(repository / "compose/local/simulation/common"),
            "mesh_dir": str(description_dir / "meshes"),
        },
    ).toxml()
    description = split_preview_visuals(description)
    # RViz's OGRE viewport flickers with Qt fractional scaling on Wayland.
    display_environment = {
        "QT_QPA_PLATFORM": "xcb",
        "QT_ENABLE_HIGHDPI_SCALING": "0",
        "QT_AUTO_SCREEN_SCALE_FACTOR": "0",
        "QT_SCALE_FACTOR": "1",
        "QT_SCREEN_SCALE_FACTORS": "1",
    }
    return LaunchDescription(
        [
            Node(
                package="robot_state_publisher",
                executable="robot_state_publisher",
                parameters=[{"robot_description": description}],
            ),
            Node(
                package="joint_state_publisher_gui",
                executable="joint_state_publisher_gui",
                additional_env=display_environment,
            ),
            Node(
                package="rviz2",
                executable="rviz2",
                arguments=["-d", str(description_dir / "view.rviz")],
                additional_env=display_environment,
            ),
        ]
    )
