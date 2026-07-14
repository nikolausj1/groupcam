from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image
from skimage import morphology, transform

from Tools.reference_compositor.engine import (
    CompositeFailure,
    _warp_mask,
    _warp_rgb,
    choose_vertical_seam,
    composite_pair,
    estimate_homography,
    load_alpha,
    load_mask,
    load_rgb,
)
from Tools.reference_compositor.generate_fixtures import (
    generate_fixture,
    generate_non_vertical_seam_fixture,
)


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
        self.donor_matte = load_mask(
            self.fixture_directory / files["donor_matte"], self.side_one.shape[:2]
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

    def test_donor_instance_preserves_both_photographers_without_interior_cutoff(self) -> None:
        # Keep the donor-instance API dependency explicit at this regression boundary.
        from Tools.reference_compositor.engine import composite_donor_instance

        result = composite_donor_instance(
            self.side_one,
            self.side_two,
            donor_matte=self.donor_matte,
            protected_one=self.mask_one,
            protected_two=self.mask_two,
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

        actual = transform.ProjectiveTransform(matrix=result.donor_to_base)
        warped_donor = _warp_mask(self.donor_matte, actual, self.side_one.shape[:2])
        donor_interior = morphology.erosion(warped_donor, morphology.disk(8))
        self.assertGreater(int(np.count_nonzero(donor_interior)), 1_000)
        self.assertTrue(
            bool(np.all(result.donor_alpha[donor_interior] >= 0.99)),
            "the donor-source boundary cuts through Photographer A's interior",
        )

        expected = transform.ProjectiveTransform(
            matrix=np.asarray(self.manifest["expected_side_two_to_side_one"], dtype=np.float64)
        )
        corners = np.asarray(
            [[0, 0], [1199, 0], [0, 799], [1199, 799], [600, 400]],
            dtype=np.float64,
        )
        corner_error = np.linalg.norm(actual(corners) - expected(corners), axis=1)
        self.assertLess(float(np.max(corner_error)), 1.5)

    def test_donor_instance_rejects_output_edge_contact(self) -> None:
        from Tools.reference_compositor.engine import composite_donor_instance

        edge_matte = self.donor_matte.astype(np.float32)
        edge_matte[200:500, :20] = 1.0
        with self.assertRaisesRegex(
            CompositeFailure,
            "donorOutputBoundaryIntersectsPerson",
        ):
            composite_donor_instance(
                self.side_one,
                self.side_two,
                donor_matte=edge_matte,
                protected_one=self.mask_one,
                protected_two=self.mask_two,
            )

    def test_non_vertical_corridor_exists_when_every_straight_seam_is_blocked(self) -> None:
        fixture_directory = self.fixture_directory / "non_vertical"
        manifest = generate_non_vertical_seam_fixture(fixture_directory)
        files = manifest["files"]
        side_one = load_rgb(fixture_directory / files["side_one"])
        side_two = load_rgb(fixture_directory / files["side_two"])
        shape = side_one.shape[:2]
        mask_one = load_mask(fixture_directory / files["protected_one"], shape)
        mask_two = load_mask(fixture_directory / files["protected_two"], shape)
        search_range = tuple(manifest["seam_search_range"])
        feather_width = int(manifest["feather_width"])

        model, *_ = estimate_homography(side_one, side_two, mask_one, mask_two)
        warped_side_two = _warp_rgb(side_two, model, shape)
        valid_donor = _warp_mask(np.ones(shape, dtype=bool), model, shape)
        warped_mask_two = _warp_mask(mask_two, model, shape)
        protected = morphology.dilation(
            mask_one | warped_mask_two,
            morphology.disk(max(4, feather_width // 2)),
        )
        with self.assertRaisesRegex(
            CompositeFailure,
            manifest["expected_straight_seam_failure"],
        ):
            choose_vertical_seam(
                side_one,
                warped_side_two,
                valid_donor,
                protected,
                search_range=search_range,
                feather_width=feather_width,
            )

        result = composite_pair(
            side_one,
            side_two,
            protected_one=mask_one,
            protected_two=mask_two,
            search_range=search_range,
            feather_width=feather_width,
        )
        self.assertFalse(result.metrics.seam_person_intersection)
        self.assertFalse(result.metrics.source_boundary_person_intersection)
        self.assertGreaterEqual(
            result.metrics.seam_max_x - result.metrics.seam_min_x,
            int(manifest["minimum_path_horizontal_travel"]),
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

    def test_load_alpha_preserves_soft_donor_matte_values(self) -> None:
        matte_path = self.fixture_directory / "soft-donor-matte.png"
        grayscale = np.asarray([[0, 64, 128, 255]], dtype=np.uint8)
        Image.fromarray(grayscale, mode="L").save(matte_path)

        alpha = load_alpha(matte_path, grayscale.shape)
        protected = load_mask(matte_path, grayscale.shape)

        np.testing.assert_allclose(
            alpha,
            grayscale.astype(np.float32) / 255.0,
            atol=1.0 / 255.0,
        )
        self.assertEqual(alpha.dtype, np.float32)
        np.testing.assert_array_equal(
            protected,
            np.asarray([[False, False, True, True]]),
        )


if __name__ == "__main__":
    unittest.main()
