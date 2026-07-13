"""A deliberately small, deterministic baseline for groupCam experiments.

The baseline registers side two into side one's coordinates, finds a protected
vertical background seam, and uses side two on the left and side one on the
right. That source policy matches the prototype's opposite-edge choreography:
Photographer A joins on the left for side two while Photographer B was present
on the right in side one.

This is an experiment harness, not the production engine. Every stage returns
measurable evidence so a more complex algorithm is adopted only when fixtures
and the consented benchmark show that it is necessary.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image
from skimage import color, morphology, transform
from skimage.feature import ORB, match_descriptors
from skimage.measure import ransac


class CompositeFailure(RuntimeError):
    """Typed reference-harness failure safe to surface as a retake reason."""


@dataclass(frozen=True)
class CompositeMetrics:
    matched_features: int
    registration_inliers: int
    inlier_ratio: float
    median_reprojection_error: float
    p95_reprojection_error: float
    seam_x: int
    seam_cost: float
    seam_person_intersection: bool
    source_boundary_person_intersection: bool
    valid_donor_fraction: float
    output_width: int
    output_height: int

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class CompositeResult:
    image: np.ndarray
    debug_overlay: np.ndarray
    side_two_to_side_one: np.ndarray
    source_alpha: np.ndarray
    metrics: CompositeMetrics


def load_rgb(path: str | Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0


def load_mask(path: str | Path | None, shape: tuple[int, int]) -> np.ndarray:
    if path is None:
        return np.zeros(shape, dtype=bool)
    with Image.open(path) as image:
        gray = np.asarray(image.convert("L").resize((shape[1], shape[0])))
    return gray >= 128


def save_rgb(path: str | Path, image: np.ndarray) -> None:
    output = Image.fromarray(np.uint8(np.clip(image, 0.0, 1.0) * 255.0), mode="RGB")
    output.save(path)


def estimate_homography(
    side_one: np.ndarray,
    side_two: np.ndarray,
    protected_one: np.ndarray,
    protected_two: np.ndarray,
    *,
    max_keypoints: int = 2_500,
) -> tuple[
    transform.ProjectiveTransform,
    np.ndarray,
    np.ndarray,
    np.ndarray,
    np.ndarray,
]:
    gray_one = color.rgb2gray(side_one).copy()
    gray_two = color.rgb2gray(side_two).copy()

    # Suppress protected interiors, then reject every descriptor whose support
    # neighborhood may touch a person or the artificial fill boundary. This
    # keeps registration evidence on the static scene rather than the subjects
    # who deliberately change between captures.
    static_one = ~protected_one
    static_two = ~protected_two
    if int(np.count_nonzero(static_one)) < 1_000 or int(np.count_nonzero(static_two)) < 1_000:
        raise CompositeFailure("notEnoughStaticBackground")
    gray_one[protected_one] = float(np.median(gray_one[~protected_one]))
    gray_two[protected_two] = float(np.median(gray_two[~protected_two]))
    excluded_one = morphology.dilation(protected_one, morphology.disk(24))
    excluded_two = morphology.dilation(protected_two, morphology.disk(24))

    orb_one = ORB(n_keypoints=max_keypoints, fast_threshold=0.04)
    orb_two = ORB(n_keypoints=max_keypoints, fast_threshold=0.04)
    try:
        orb_one.detect_and_extract(gray_one)
        orb_two.detect_and_extract(gray_two)
    except RuntimeError as error:
        raise CompositeFailure("notEnoughBackgroundDetail") from error

    row_one = np.clip(np.rint(orb_one.keypoints[:, 0]).astype(int), 0, gray_one.shape[0] - 1)
    column_one = np.clip(np.rint(orb_one.keypoints[:, 1]).astype(int), 0, gray_one.shape[1] - 1)
    row_two = np.clip(np.rint(orb_two.keypoints[:, 0]).astype(int), 0, gray_two.shape[0] - 1)
    column_two = np.clip(np.rint(orb_two.keypoints[:, 1]).astype(int), 0, gray_two.shape[1] - 1)
    keep_one = ~excluded_one[row_one, column_one]
    keep_two = ~excluded_two[row_two, column_two]
    keypoints_one = orb_one.keypoints[keep_one]
    descriptors_one = orb_one.descriptors[keep_one]
    keypoints_two = orb_two.keypoints[keep_two]
    descriptors_two = orb_two.descriptors[keep_two]
    if len(descriptors_one) < 12 or len(descriptors_two) < 12:
        raise CompositeFailure("notEnoughStaticBackgroundFeatures")

    matches = match_descriptors(
        descriptors_two,
        descriptors_one,
        metric="hamming",
        cross_check=True,
        max_ratio=0.82,
    )
    if len(matches) < 12:
        raise CompositeFailure("notEnoughBackgroundMatches")

    source_xy = keypoints_two[matches[:, 0]][:, ::-1]
    destination_xy = keypoints_one[matches[:, 1]][:, ::-1]
    model, inliers = ransac(
        (source_xy, destination_xy),
        transform.ProjectiveTransform,
        min_samples=4,
        residual_threshold=2.5,
        max_trials=2_000,
        rng=0,
    )
    if model is None or inliers is None or int(np.count_nonzero(inliers)) < 10:
        raise CompositeFailure("unstableBackgroundRegistration")
    return model, matches, inliers, source_xy, destination_xy


def _warp_rgb(
    image: np.ndarray,
    side_two_to_side_one: transform.ProjectiveTransform,
    output_shape: tuple[int, int],
) -> np.ndarray:
    return transform.warp(
        image,
        inverse_map=side_two_to_side_one.inverse,
        output_shape=output_shape,
        order=1,
        mode="constant",
        cval=0.0,
        preserve_range=True,
    ).astype(np.float32)


def _warp_mask(
    mask: np.ndarray,
    side_two_to_side_one: transform.ProjectiveTransform,
    output_shape: tuple[int, int],
) -> np.ndarray:
    warped = transform.warp(
        mask.astype(np.float32),
        inverse_map=side_two_to_side_one.inverse,
        output_shape=output_shape,
        order=0,
        mode="constant",
        cval=0.0,
        preserve_range=True,
    )
    return warped >= 0.5


def choose_vertical_seam(
    side_one: np.ndarray,
    warped_side_two: np.ndarray,
    valid_donor: np.ndarray,
    protected: np.ndarray,
    *,
    search_range: tuple[float, float],
    feather_width: int,
) -> tuple[int, float]:
    height, width = valid_donor.shape
    start = max(feather_width, int(width * search_range[0]))
    end = min(width - feather_width, int(width * search_range[1]))
    if start >= end:
        raise CompositeFailure("invalidSeamSearchRange")

    pixel_difference = np.mean(np.abs(side_one - warped_side_two), axis=2)
    best_x: int | None = None
    best_cost = float("inf")
    half = max(3, feather_width // 2)

    for x in range(start, end):
        band = slice(x - half, x + half + 1)
        band_valid = valid_donor[:, band]
        if float(np.mean(band_valid)) < 0.94:
            continue
        if bool(np.any(protected[:, band])):
            continue
        values = pixel_difference[:, band][band_valid]
        if values.size == 0:
            continue
        # Mean discontinuity is primary; a high-percentile term rejects a seam
        # with one locally severe artifact hidden by an otherwise clean column.
        cost = float(np.mean(values) + 0.35 * np.percentile(values, 95))
        if cost < best_cost:
            best_x = x
            best_cost = cost

    if best_x is None:
        raise CompositeFailure("noProtectedBackgroundSeam")
    return best_x, best_cost


def _source_alpha(
    shape: tuple[int, int],
    seam_x: int,
    feather_width: int,
    valid_donor: np.ndarray,
) -> np.ndarray:
    width = shape[1]
    x = np.arange(width, dtype=np.float32)
    left = seam_x - feather_width / 2.0
    right = seam_x + feather_width / 2.0
    ramp = np.clip((right - x) / max(right - left, 1.0), 0.0, 1.0)
    # Smoothstep avoids a visible derivative discontinuity at the feather edge.
    ramp = ramp * ramp * (3.0 - 2.0 * ramp)
    alpha = np.broadcast_to(ramp, shape).copy()
    alpha[~valid_donor] = 0.0
    return alpha


def _source_boundary(alpha: np.ndarray) -> np.ndarray:
    donor_region = alpha >= 0.5
    footprint = morphology.disk(2)
    return morphology.dilation(donor_region, footprint) ^ morphology.erosion(
        donor_region, footprint
    )


def _debug_overlay(
    composite: np.ndarray,
    protected: np.ndarray,
    seam_x: int,
    feather_width: int,
) -> np.ndarray:
    debug = composite.copy()
    boundary = morphology.dilation(protected, morphology.disk(2)) ^ protected
    debug[boundary] = np.array([1.0, 0.15, 0.12], dtype=np.float32)
    left = max(0, seam_x - feather_width // 2)
    right = min(debug.shape[1], seam_x + feather_width // 2 + 1)
    debug[:, left:right, 1] = np.maximum(debug[:, left:right, 1], 0.82)
    debug[:, seam_x : seam_x + 2] = np.array([0.1, 1.0, 0.35], dtype=np.float32)
    return debug


def composite_pair(
    side_one: np.ndarray,
    side_two: np.ndarray,
    *,
    protected_one: np.ndarray | None = None,
    protected_two: np.ndarray | None = None,
    search_range: tuple[float, float] = (0.32, 0.68),
    feather_width: int = 18,
) -> CompositeResult:
    if side_one.shape != side_two.shape or side_one.ndim != 3 or side_one.shape[2] != 3:
        raise CompositeFailure("sourceDimensionsDoNotMatch")

    output_shape = side_one.shape[:2]
    protected_one = (
        np.zeros(output_shape, dtype=bool) if protected_one is None else protected_one.astype(bool)
    )
    protected_two = (
        np.zeros(output_shape, dtype=bool) if protected_two is None else protected_two.astype(bool)
    )
    if protected_one.shape != output_shape or protected_two.shape != output_shape:
        raise CompositeFailure("protectedMaskDimensionsDoNotMatch")

    model, matches, inliers, source_xy, destination_xy = estimate_homography(
        side_one, side_two, protected_one, protected_two
    )
    warped_side_two = _warp_rgb(side_two, model, output_shape)
    valid_donor = _warp_mask(np.ones(output_shape, dtype=bool), model, output_shape)
    warped_protected_two = _warp_mask(protected_two, model, output_shape)
    protected = morphology.dilation(
        protected_one | warped_protected_two,
        morphology.disk(max(4, feather_width // 2)),
    )

    seam_x, seam_cost = choose_vertical_seam(
        side_one,
        warped_side_two,
        valid_donor,
        protected,
        search_range=search_range,
        feather_width=feather_width,
    )
    alpha = _source_alpha(output_shape, seam_x, feather_width, valid_donor)
    source_boundary = _source_boundary(alpha)
    source_boundary_intersection = bool(np.any(source_boundary & protected))
    if source_boundary_intersection:
        raise CompositeFailure("sourceBoundaryCrossesProtectedPerson")
    composite = warped_side_two * alpha[..., None] + side_one * (1.0 - alpha[..., None])

    projected = model(source_xy)
    residuals = np.linalg.norm(projected - destination_xy, axis=1)

    seam_band = protected[:, max(0, seam_x - feather_width // 2) : seam_x + feather_width // 2 + 1]
    metrics = CompositeMetrics(
        matched_features=len(matches),
        registration_inliers=int(np.count_nonzero(inliers)),
        inlier_ratio=float(np.mean(inliers)),
        median_reprojection_error=float(np.median(residuals[inliers])),
        p95_reprojection_error=float(np.percentile(residuals[inliers], 95)),
        seam_x=seam_x,
        seam_cost=seam_cost,
        seam_person_intersection=bool(np.any(seam_band)),
        source_boundary_person_intersection=source_boundary_intersection,
        valid_donor_fraction=float(np.mean(valid_donor)),
        output_width=output_shape[1],
        output_height=output_shape[0],
    )
    return CompositeResult(
        image=np.clip(composite, 0.0, 1.0),
        debug_overlay=_debug_overlay(composite, protected, seam_x, feather_width),
        side_two_to_side_one=np.asarray(model.params),
        source_alpha=alpha,
        metrics=metrics,
    )
