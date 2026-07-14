"""A deliberately small, deterministic baseline for groupCam experiments.

The baseline registers side two into side one's coordinates, finds a protected
background seam, and uses side two on the left and side one on the
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
from skimage import color, filters, morphology, transform
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
    seam_min_x: int
    seam_max_x: int
    seam_length: float
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


@dataclass(frozen=True)
class DonorCompositeMetrics:
    matched_features: int
    registration_inliers: int
    inlier_ratio: float
    median_reprojection_error: float
    p95_reprojection_error: float
    donor_min_x: int
    donor_min_y: int
    donor_max_x: int
    donor_max_y: int
    donor_pixel_fraction: float
    donor_output_edge_contact: bool
    donor_source_boundary_person_intersection: bool
    valid_donor_fraction: float
    output_width: int
    output_height: int

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class DonorCompositeResult:
    image: np.ndarray
    debug_overlay: np.ndarray
    donor_to_base: np.ndarray
    donor_alpha: np.ndarray
    metrics: DonorCompositeMetrics

    # Keep the reference result interoperable with the full-frame compositor
    # while exposing names that remain accurate if the capture order is later
    # reversed during automatic direction selection.
    @property
    def side_two_to_side_one(self) -> np.ndarray:
        return self.donor_to_base

    @property
    def source_alpha(self) -> np.ndarray:
        return self.donor_alpha


def load_rgb(path: str | Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0


def load_mask(path: str | Path | None, shape: tuple[int, int]) -> np.ndarray:
    if path is None:
        return np.zeros(shape, dtype=bool)
    with Image.open(path) as image:
        gray = np.asarray(image.convert("L").resize((shape[1], shape[0])))
    return gray >= 128


def load_alpha(path: str | Path | None, shape: tuple[int, int]) -> np.ndarray:
    """Load a grayscale matte while preserving its soft fractional coverage."""
    if path is None:
        return np.zeros(shape, dtype=np.float32)
    with Image.open(path) as image:
        gray = np.asarray(
            image.convert("L").resize(
                (shape[1], shape[0]),
                resample=Image.Resampling.BILINEAR,
            ),
            dtype=np.float32,
        )
    return gray / 255.0


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


def _warp_alpha(
    matte: np.ndarray,
    donor_to_base: transform.ProjectiveTransform,
    output_shape: tuple[int, int],
) -> np.ndarray:
    return transform.warp(
        matte.astype(np.float32),
        inverse_map=donor_to_base.inverse,
        output_shape=output_shape,
        order=1,
        mode="constant",
        cval=0.0,
        preserve_range=True,
    ).astype(np.float32)


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


def choose_protected_seam(
    side_one: np.ndarray,
    warped_side_two: np.ndarray,
    valid_donor: np.ndarray,
    protected: np.ndarray,
    *,
    search_range: tuple[float, float],
    feather_width: int,
) -> tuple[np.ndarray, float]:
    """Find a deterministic 8-connected background seam from top to bottom."""

    height, width = valid_donor.shape
    start = max(feather_width, int(width * search_range[0]))
    end = min(width - feather_width, int(width * search_range[1]))
    if start >= end:
        raise CompositeFailure("invalidSeamSearchRange")

    # A centerline is valid only when the complete horizontal feather corridor
    # remains outside every protected region. Invalid donor pixels are heavily
    # penalized rather than forbidden because a projective warp can leave a
    # thin border with no donor at all; the resulting footprint boundary is
    # independently checked against protection before a result can pass.
    half = max(3, feather_width // 2)
    protected_corridor = morphology.dilation(
        protected,
        footprint=np.ones((1, 2 * half + 1), dtype=bool),
    )
    allowed = ~protected_corridor[:, start:end]
    invalid_corridor = morphology.dilation(
        ~valid_donor,
        footprint=np.ones((1, 2 * half + 1), dtype=bool),
    )

    difference = np.mean(np.abs(side_one - warped_side_two), axis=2)
    gray_one = color.rgb2gray(side_one)
    gray_two = color.rgb2gray(warped_side_two)
    gradient_difference = np.abs(filters.sobel(gray_one) - filters.sobel(gray_two))
    data_cost = difference + 0.25 * gradient_difference
    data_cost += invalid_corridor.astype(np.float32) * 2.0
    data_cost = data_cost[:, start:end].astype(np.float32)

    band_width = end - start
    accumulated = np.full((height, band_width), np.inf, dtype=np.float32)
    parents = np.zeros((height, band_width), dtype=np.int8)
    center = (band_width - 1) / 2.0
    tie_break = np.abs(np.arange(band_width, dtype=np.float32) - center) * 1e-7
    accumulated[0, allowed[0]] = data_cost[0, allowed[0]] + tie_break[allowed[0]]

    # Prefer a straight continuation when costs are equal, then left, then
    # right. The small lateral penalty suppresses needless seam jitter.
    lateral_penalty = 0.0025
    parent_offsets = np.asarray([0, -1, 1], dtype=np.int8)
    for row in range(1, height):
        previous = accumulated[row - 1]
        candidates = np.stack(
            (
                previous,
                np.pad(previous[:-1], (1, 0), constant_values=np.inf) + lateral_penalty,
                np.pad(previous[1:], (0, 1), constant_values=np.inf) + lateral_penalty,
            )
        )
        choices = np.argmin(candidates, axis=0)
        best = np.min(candidates, axis=0)
        reachable = allowed[row] & np.isfinite(best)
        accumulated[row, reachable] = best[reachable] + data_cost[row, reachable]
        parents[row, reachable] = parent_offsets[choices[reachable]]

    if not np.any(np.isfinite(accumulated[-1])):
        raise CompositeFailure("noProtectedBackgroundSeam")

    seam = np.empty(height, dtype=np.int32)
    column = int(np.argmin(accumulated[-1] + tie_break))
    total_cost = float(accumulated[-1, column])
    seam[-1] = column + start
    for row in range(height - 1, 0, -1):
        column += int(parents[row, column])
        seam[row - 1] = column + start

    rows = np.arange(height)
    if not bool(np.all(allowed[rows, seam - start])):
        raise CompositeFailure("noProtectedBackgroundSeam")
    return seam, total_cost / max(height, 1)


def _source_alpha(
    shape: tuple[int, int],
    seam_x: int | np.ndarray,
    feather_width: int,
    valid_donor: np.ndarray,
) -> np.ndarray:
    height, width = shape
    seam = np.asarray(seam_x, dtype=np.float32)
    if seam.ndim == 0:
        seam = np.full(height, float(seam), dtype=np.float32)
    if seam.shape != (height,):
        raise CompositeFailure("invalidSeamShape")
    x = np.arange(width, dtype=np.float32)[None, :]
    left = seam[:, None] - feather_width / 2.0
    right = seam[:, None] + feather_width / 2.0
    ramp = np.clip((right - x) / max(float(feather_width), 1.0), 0.0, 1.0)
    # Smoothstep avoids a visible derivative discontinuity at the feather edge.
    ramp = ramp * ramp * (3.0 - 2.0 * ramp)
    alpha = ramp.astype(np.float32, copy=False)
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
    seam_x: np.ndarray,
    feather_width: int,
) -> np.ndarray:
    debug = composite.copy()
    boundary = morphology.dilation(protected, morphology.disk(2)) ^ protected
    debug[boundary] = np.array([1.0, 0.15, 0.12], dtype=np.float32)
    rows, columns = np.indices(protected.shape)
    band = np.abs(columns - seam_x[:, None]) <= max(1, feather_width // 2)
    debug[..., 1][band] = np.maximum(debug[..., 1][band], 0.82)
    debug[rows[:, 0], seam_x] = np.array([0.1, 1.0, 0.35], dtype=np.float32)
    return debug


def _donor_debug_overlay(
    composite: np.ndarray,
    donor_alpha: np.ndarray,
    source_boundary: np.ndarray,
) -> np.ndarray:
    debug = composite.copy()
    donor_region = donor_alpha >= 0.08
    donor_boundary = morphology.dilation(donor_region, morphology.disk(2)) ^ morphology.erosion(
        donor_region, morphology.disk(2)
    )
    debug[donor_boundary] = np.array([0.1, 1.0, 0.35], dtype=np.float32)
    debug[source_boundary & donor_region] = np.array([1.0, 0.15, 0.12], dtype=np.float32)
    return debug


def composite_donor_instance(
    base: np.ndarray,
    donor: np.ndarray,
    *,
    donor_matte: np.ndarray,
    protected_one: np.ndarray | None = None,
    protected_two: np.ndarray | None = None,
    feather_sigma: float = 1.25,
) -> DonorCompositeResult:
    """Register ``donor`` to ``base`` and insert one visible person instance.

    ``donor_matte`` is in donor coordinates. The caller chooses which person is
    missing from the base image; this reference function never infers identity.
    A matte that meets the donor image boundary may be safe at the final output
    edge, but it is rejected when that source boundary lands inside the output.
    """

    if base.shape != donor.shape or base.ndim != 3 or base.shape[2] != 3:
        raise CompositeFailure("sourceDimensionsDoNotMatch")

    output_shape = base.shape[:2]
    protected_one = (
        np.zeros(output_shape, dtype=bool)
        if protected_one is None
        else np.asarray(protected_one, dtype=bool)
    )
    protected_two = (
        np.zeros(output_shape, dtype=bool)
        if protected_two is None
        else np.asarray(protected_two, dtype=bool)
    )
    if protected_one.shape != output_shape or protected_two.shape != output_shape:
        raise CompositeFailure("protectedMaskDimensionsDoNotMatch")

    matte = np.asarray(donor_matte, dtype=np.float32)
    if matte.shape != output_shape:
        raise CompositeFailure("donorMatteDimensionsDoNotMatch")
    if not bool(np.all(np.isfinite(matte))):
        raise CompositeFailure("invalidDonorMatte")
    matte = np.clip(matte, 0.0, 1.0)
    if int(np.count_nonzero(matte >= 0.08)) < 100:
        raise CompositeFailure("emptyDonorMatte")
    if feather_sigma < 0.0:
        raise CompositeFailure("invalidDonorFeather")

    model, matches, inliers, source_xy, destination_xy = estimate_homography(
        base,
        donor,
        protected_one,
        protected_two,
    )
    warped_donor = _warp_rgb(donor, model, output_shape)
    valid_donor = _warp_mask(np.ones(output_shape, dtype=bool), model, output_shape)
    warped_matte = np.clip(_warp_alpha(matte, model, output_shape), 0.0, 1.0)

    # Test the unfeathered person support against the projective source
    # footprint. This catches the horizontal body cutoff seen when a person at
    # a source edge is projected into the interior of the other photograph.
    donor_region = warped_matte >= 0.08
    footprint_boundary = _source_boundary(valid_donor.astype(np.float32))
    interior = np.ones(output_shape, dtype=bool)
    border = 3
    interior[:border, :] = False
    interior[-border:, :] = False
    interior[:, :border] = False
    interior[:, -border:] = False
    source_boundary_intersection = bool(
        np.any(donor_region & footprint_boundary & interior)
    )
    if source_boundary_intersection:
        raise CompositeFailure("donorSourceBoundaryIntersectsPerson")

    edge = np.zeros(output_shape, dtype=bool)
    edge[:border, :] = True
    edge[-border:, :] = True
    edge[:, :border] = True
    edge[:, -border:] = True
    output_edge_contact = bool(np.any(donor_region & edge))
    if output_edge_contact:
        raise CompositeFailure("donorOutputBoundaryIntersectsPerson")

    alpha = warped_matte
    if feather_sigma > 0.0:
        alpha = filters.gaussian(
            alpha,
            sigma=feather_sigma,
            mode="nearest",
            preserve_range=True,
        ).astype(np.float32)
    alpha = np.clip(alpha, 0.0, 1.0)
    alpha[~valid_donor] = 0.0
    composite = warped_donor * alpha[..., None] + base * (1.0 - alpha[..., None])

    locations = np.argwhere(donor_region)
    minimum_y, minimum_x = np.min(locations, axis=0)
    maximum_y, maximum_x = np.max(locations, axis=0)
    projected = model(source_xy)
    residuals = np.linalg.norm(projected - destination_xy, axis=1)
    metrics = DonorCompositeMetrics(
        matched_features=len(matches),
        registration_inliers=int(np.count_nonzero(inliers)),
        inlier_ratio=float(np.mean(inliers)),
        median_reprojection_error=float(np.median(residuals[inliers])),
        p95_reprojection_error=float(np.percentile(residuals[inliers], 95)),
        donor_min_x=int(minimum_x),
        donor_min_y=int(minimum_y),
        donor_max_x=int(maximum_x),
        donor_max_y=int(maximum_y),
        donor_pixel_fraction=float(np.mean(donor_region)),
        donor_output_edge_contact=output_edge_contact,
        donor_source_boundary_person_intersection=source_boundary_intersection,
        valid_donor_fraction=float(np.mean(valid_donor)),
        output_width=output_shape[1],
        output_height=output_shape[0],
    )
    return DonorCompositeResult(
        image=np.clip(composite, 0.0, 1.0),
        debug_overlay=_donor_debug_overlay(composite, alpha, footprint_boundary),
        donor_to_base=np.asarray(model.params),
        donor_alpha=alpha,
        metrics=metrics,
    )


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

    seam_path, seam_cost = choose_protected_seam(
        side_one,
        warped_side_two,
        valid_donor,
        protected,
        search_range=search_range,
        feather_width=feather_width,
    )
    alpha = _source_alpha(output_shape, seam_path, feather_width, valid_donor)
    source_boundary = _source_boundary(alpha)
    source_boundary_intersection = bool(np.any(source_boundary & protected))
    if source_boundary_intersection:
        raise CompositeFailure("sourceBoundaryCrossesProtectedPerson")
    composite = warped_side_two * alpha[..., None] + side_one * (1.0 - alpha[..., None])

    projected = model(source_xy)
    residuals = np.linalg.norm(projected - destination_xy, axis=1)

    rows, columns = np.indices(output_shape)
    seam_band = np.abs(columns - seam_path[:, None]) <= max(1, feather_width // 2)
    seam_steps = np.diff(seam_path).astype(np.float32)
    seam_x = int(np.median(seam_path))
    metrics = CompositeMetrics(
        matched_features=len(matches),
        registration_inliers=int(np.count_nonzero(inliers)),
        inlier_ratio=float(np.mean(inliers)),
        median_reprojection_error=float(np.median(residuals[inliers])),
        p95_reprojection_error=float(np.percentile(residuals[inliers], 95)),
        seam_x=seam_x,
        seam_min_x=int(np.min(seam_path)),
        seam_max_x=int(np.max(seam_path)),
        seam_length=float(np.sum(np.sqrt(1.0 + seam_steps * seam_steps))),
        seam_cost=seam_cost,
        seam_person_intersection=bool(np.any(seam_band & protected)),
        source_boundary_person_intersection=source_boundary_intersection,
        valid_donor_fraction=float(np.mean(valid_donor)),
        output_width=output_shape[1],
        output_height=output_shape[0],
    )
    return CompositeResult(
        image=np.clip(composite, 0.0, 1.0),
        debug_overlay=_debug_overlay(composite, protected, seam_path, feather_width),
        side_two_to_side_one=np.asarray(model.params),
        source_alpha=alpha,
        metrics=metrics,
    )
