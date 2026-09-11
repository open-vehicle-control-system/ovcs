"""Generate original, approximate Baja Bug visuals using only the stdlib.

Body vertices use fractions of the URDF shell envelope. Wheel vertices use
radius=1 and width=1, with the axle along z. Collision and inertia geometry
remain in the URDF; these open surface meshes are for rendering only.
"""

import math
import struct
from itertools import pairwise
from pathlib import Path


class Mesh:
    def __init__(self):
        self.triangles = []

    def face(self, *points):
        for i in range(1, len(points) - 1):
            self.triangles.append((points[0], points[i], points[i + 1]))

    def save(self, path):
        with path.open("wb") as stream:
            stream.write(b"OVCS original procedural visual mesh".ljust(80, b"\0"))
            stream.write(struct.pack("<I", len(self.triangles)))
            for a, b, c in self.triangles:
                u = [b[i] - a[i] for i in range(3)]
                v = [c[i] - a[i] for i in range(3)]
                n = [
                    u[1] * v[2] - u[2] * v[1],
                    u[2] * v[0] - u[0] * v[2],
                    u[0] * v[1] - u[1] * v[0],
                ]
                length = math.sqrt(sum(x * x for x in n))
                if length < 1e-12:
                    raise ValueError(f"Degenerate triangle in {path}")
                stream.write(struct.pack("<12fH", *(x / length for x in n), *a, *b, *c, 0))


def interpolate(x, knots):
    for (a, va), (b, vb) in pairwise(knots):
        if x <= b:
            return va + (vb - va) * (x - a) / (b - a)
    return knots[-1][1]


def body_meshes():
    body, glass, trim, stripe = Mesh(), Mesh(), Mesh(), Mesh()
    # Original Baja Bug approximation, unit shell envelope (not vehicle height).
    roof = [
        (-0.5, 0.14),
        (-0.42, 0.24),
        (-0.30, 0.53),
        (-0.20, 0.80),
        (-0.08, 0.98),
        (0, 1),
        (0.10, 0.94),
        (0.20, 0.70),
        (0.27, 0.40),
        (0.40, 0.27),
        (0.50, 0.13),
    ]
    width = [
        (-0.5, 0.18),
        (-0.40, 0.28),
        (-0.25, 0.39),
        (0, 0.40),
        (0.20, 0.35),
        (0.35, 0.29),
        (0.50, 0.18),
    ]
    xs = sorted(
        {
            round(x, 10)
            for x in [-0.5 + i / 160 for i in range(161)]
            + [x for x, _ in roof]
            + [x for x, _ in width]
        }
    )

    def surface(x, angle):
        top = interpolate(x, roof)
        edge = interpolate(x, width)
        shoulder = min(0.20, top * 0.7)
        return (x, edge * math.cos(angle), shoulder + (top - shoulder) * math.sin(angle))

    for a, b in pairwise(xs):
        mid = (a + b) / 2
        for j in range(48):
            lo, hi = j * math.pi / 48, (j + 1) * math.pi / 48
            angle = (lo + hi) / 2
            side_window = (
                -0.20 < mid < 0.15
                and not -0.04 < mid < -0.015
                and (0.32 < angle < 1.04 or 2.10 < angle < 2.82)
            )
            windscreen = 0.155 < mid < 0.235 and 0.65 < angle < 2.49
            rear_window = -0.285 < mid < -0.215 and 0.72 < angle < 2.42
            target = glass if side_window or windscreen or rear_window else body
            if target is body and 1.44 < angle < 1.70:
                target = stripe
            target.face(surface(a, lo), surface(a, hi), surface(b, hi), surface(b, lo))
        for side, angle in [(1, 0), (-1, math.pi)]:
            pa, pb = surface(a, angle), surface(b, angle)
            points = [(a, pa[1] * 0.94, 0), (b, pb[1] * 0.94, 0), pb, pa]
            body.face(*(points[::-1] if side == 1 else points))
    for x in (-0.5, 0.5):
        centre = (x, 0, 0.03)
        for j in range(48):
            a, b = surface(x, j * math.pi / 48), surface(x, (j + 1) * math.pi / 48)
            body.face(*([centre, a, b] if x > 0 else [centre, b, a]))
    # Cut-down Baja fenders, distinct from the narrower cabin and bonnet.
    for axle in (-0.325, 0.325):
        for side in (-1, 1):
            for j in range(40):
                a, b = 0.12 + j * (math.pi - 0.24) / 40, 0.12 + (j + 1) * (math.pi - 0.24) / 40

                def fender(theta, outer, axle=axle, side=side):
                    return (
                        axle + 0.145 * math.cos(theta),
                        side * (0.5 if outer else 0.30),
                        0.045 + (0.44 if outer else 0.40) * math.sin(theta),
                    )

                points = [fender(a, False), fender(a, True), fender(b, True), fender(b, False)]
                body.face(*(points[::-1] if side == -1 else points))
    # Round headlights on the front bonnet, in normalized shell coordinates.
    for side in (-1, 1):
        centre = (0.475, side * 0.23, 0.24)
        for i in range(32):
            a, b = i * math.tau / 32, (i + 1) * math.tau / 32
            stripe.face(
                centre,
                (0.475, centre[1] + 0.053 * math.cos(a), 0.24 + 0.067 * math.sin(a)),
                (0.475, centre[1] + 0.053 * math.cos(b), 0.24 + 0.067 * math.sin(b)),
            )
    # Rear engine cover vents; no simulated combustion engine is added.
    for j in range(7):
        z = 0.055 + j * 0.014
        trim.face(
            (-0.501, -0.14, z),
            (-0.501, -0.14, z + 0.005),
            (-0.501, 0.14, z + 0.005),
            (-0.501, 0.14, z),
        )
    return {"body": body, "windows": glass, "trim": trim, "stripe": stripe}


def lathe(mesh, profile, segments=64):
    for i in range(segments):
        a, b = i * math.tau / segments, (i + 1) * math.tau / segments
        for (r0, z0), (r1, z1) in pairwise(profile):
            mesh.face(
                (r0 * math.cos(a), r0 * math.sin(a), z0),
                (r0 * math.cos(b), r0 * math.sin(b), z0),
                (r1 * math.cos(b), r1 * math.sin(b), z1),
                (r1 * math.cos(a), r1 * math.sin(a), z1),
            )


def wheel_meshes():
    tyre, rim = Mesh(), Mesh()
    lathe(
        tyre,
        [
            (0.57, -0.44),
            (0.78, -0.50),
            (0.94, -0.39),
            (0.975, -0.27),
            (0.975, 0.27),
            (0.94, 0.39),
            (0.78, 0.50),
            (0.57, 0.44),
        ],
    )
    lathe(rim, [(0.52, -0.45), (0.59, -0.45), (0.59, 0.45), (0.52, 0.45)])
    lathe(rim, [(0.12, -0.46), (0.21, -0.46), (0.21, 0.46), (0.12, 0.46)])
    for side in (-1, 1):
        for i in range(10):
            angle = i * math.tau / 10
            points = [
                (r * math.cos(angle + d), r * math.sin(angle + d), side * 0.44)
                for r, d in [(0.18, -0.17), (0.55, -0.08), (0.55, 0.08), (0.18, 0.17)]
            ]
            rim.face(*(points if side > 0 else points[::-1]))
    # Three staggered rows of tread blocks reveal wheel rotation.
    for row in range(3):
        z = -0.23 + row * 0.23
        for i in range(32):
            a = (i + 0.5 * (row % 2)) * math.tau / 32
            corners = [
                (r * math.cos(a + d), r * math.sin(a + d), zz)
                for r in (0.972, 1.0)
                for d, zz in [
                    (-0.047, z - 0.08),
                    (0.047, z - 0.08),
                    (0.047, z + 0.08),
                    (-0.047, z + 0.08),
                ]
            ]
            tyre.face(*corners[4:])
            for j in range(4):
                k = (j + 1) % 4
                tyre.face(corners[j], corners[k], corners[k + 4], corners[j + 4])
    return {"tyre": tyre, "rim": rim}


if __name__ == "__main__":
    destination = Path(__file__).with_name("meshes")
    destination.mkdir(exist_ok=True)
    for name, mesh in (body_meshes() | wheel_meshes()).items():
        mesh.save(destination / f"{name}.stl")
