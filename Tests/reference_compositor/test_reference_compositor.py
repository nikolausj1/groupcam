from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from skimage import transform

from Tools.reference_compositor.engine import (
    CompositeFailure,
    composite_pair,
    load_mask,
    load_rgb,
)
from Tools.reference_compositor.generate_fixtures import generate_fixture


class ReferenceCompositorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture_directory = Path(self.temporary.name)
        generate_fixture(self.fixture_directory)
        self.manifest = json.loads((self.fixture_directory / "fixture.json").read_text())
        files = self.manifest["files"]
        self.side_one = load_rgb(self.fixture_directory / files["side_one"])
        self.side_two = load_rgb(self.fixture_directory / files["side_two"])
        self.mask_one = load_mask(
            self.fixture_directory / files["protected_one"], self.side_one.shape[:2]
        )
        self.mask_two = load_mask(
            self.fixture_directory / files["protected_two"], self.side_one.shape[:2]
        )
        self.ground_truth = load_rgb(self.fixture_directory / files["ground_truth"])

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_composite_recovers_both_opposite_edge_photographers(self) -> None:
        seam_range = tuple(self.manifest["seam_search_range"])
        result = composite_pair(
            self.side_one,
            self.side_two,
            protected_one=self.mask_one,
            protected_two=self.mask_two,
            search_range=seam_range,
            feather_width=18,
        )

        a = self.manifest["joining_regions"]["photographer_a"]
        b = self.manifest["joining_regions"]["photographer_b"]
        a_slice = np.s_[a[1] : a[3], a[0] : a[2]]
        b_slice = np.s_[b[1] : b[3], b[0] : b[2]]
        a_error = float(np.mean(np.abs(result.image[a_slice] - self.ground_truth[a_slice])))
        b_error = float(np.mean(np.abs(result.image[b_slice] - self.ground_truth[b_slice])))

        self.assertLess(a_error, 0.08)
        self.assertLess(b_error, 0.015)
        self.assertGreaterEqual(result.metrics.registration_inliers, 35)
        self.assertGreater(result.metrics.inlier_ratio, 0.45)
        self.assertFalse(result.metrics.seam_person_intersection)
        self.assertFalse(result.metrics.source_boundary_person_intersection)
        self.assertEqual(result.image.shape, self.side_one.shape)

        expected = transform.ProjectiveTransform(
            matrix=np.asarray(self.manifest["expected_side_two_to_side_one"], dtype=np.float64)
        )
        actual = transform.ProjectiveTransform(matrix=result.side_two_to_side_one)
        corners = np.asarray(
            [[0, 0], [1199, 0], [0, 799], [1199, 799], [600, 400]],
            dtype=np.float64,
        )
        corner_error = np.linalg.norm(actual(corners) - expected(corners), axis=1)
        self.assertLess(float(np.max(corner_error)), 1.5)

    def test_rejects_when_every_seam_crosses_a_protected_region(self) -> None:
        blocked = self.mask_one.copy()
        start = int(blocked.shape[1] * 0.55)
        end = int(blocked.shape[1] * 0.72)
        blocked[:, start:end] = True

        with self.assertRaisesRegex(CompositeFailure, "noProtectedBackgroundSeam"):
            composite_pair(
                self.side_one,
                self.side_two,
                protected_one=blocked,
                protected_two=self.mask_two,
                search_range=(0.57, 0.69),
                feather_width=18,
            )

    def test_rejects_when_donor_footprint_boundary_crosses_protection(self) -> None:
        protected_at_warp_edge = self.mask_one.copy()
        protected_at_warp_edge[770:800, 50:180] = True

        with self.assertRaisesRegex(CompositeFailure, "sourceBoundaryCrossesProtectedPerson"):
            composite_pair(
                self.side_one,
                self.side_two,
                protected_one=protected_at_warp_edge,
                protected_two=self.mask_two,
                search_range=(0.57, 0.69),
                feather_width=18,
            )


if __name__ == "__main__":
    unittest.main()
