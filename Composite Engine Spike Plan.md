# groupCam Composite Engine Spike Plan

Status: Phase 0B/0C implementation plan. Product requirements remain in `groupCam - PRD.md`.

## 1. Purpose

Validate the smallest deterministic, on-device-capable composite pipeline that meets the authenticity and keeper gates before expanding product UI.

Locked invariants:

- on-device processing and no app-controlled image upload;
- only pixels from real source captures;
- no face replacement or generative reconstruction;
- registration driven by stable background;
- no source seam through a protected face/body region;
- proxy decisions map to source-resolution rendering;
- a suspect candidate fails honestly and requests a retake.

Phase 0B freezes cadence, registration, optional local refinement, photographer/donor inference, seam, exposure match, blend, crop, and measurable QA thresholds. Phase 0C decides OpenCV versus native production implementation, pins exact versions/modules, and validates full-resolution device behavior.

## 2. Artifacts

- reproducible macOS command-line reference harness;
- versioned experiment manifest with parameters and algorithm IDs;
- typed stage failures, image-free metrics, and timings;
- local-only overlays for matches, protected regions, donor constraints, seam, crop, and QA failures;
- committed synthetic/non-person fixtures with expected transforms and pass/fail outcomes;
- frozen composite recipe and calibrated QA thresholds;
- blinded review packet and aggregate image-free report.

Private source imagery stays in the approved corpus location described by `Privacy and Data Lifecycle.md`.

## 3. Harness contract

Each interchangeable stage emits an output or typed failure, algorithm/version ID, parameters, elapsed time, image-free metrics, and an optional local-only visualization.

1. Normalize orientation and working color space.
2. Build 1K-2K analysis proxies.
3. Score all side-one/side-two frame pairs jointly.
4. Detect protected people and static-background candidates.
5. Register the scene and measure residual/parallax risk.
6. Infer joining photographers and donor constraints.
7. Select a protected source seam.
8. Match background exposure/color.
9. Blend in 16-bit-float extended-linear Display P3.
10. Straighten and calculate the safe crop.
11. Run measurable automated risk gates.
12. Render/export source-resolution SDR Display P3 HEIF.

## 4. Phase 0B experiments

| ID | Question | Candidates | Decision rule |
|---|---|---|---|
| B1 | Proxy size | 1K, 1.5K, 2K long edge | Smallest that preserves transform/seam/QA decisions |
| B2 | Sequence cadence | 1x1, 3x3, 5x5 frame pairs | Shortest cadence meeting keeper goals |
| B3 | Protected/static masks | Faces; person union; dilated face/body regions | Simplest mask preventing person seams |
| B4 | Global registration | Vision homography; OpenCV SIFT/AKAZE/ORB plus robust homography | Lowest background residual and false success with iOS portability |
| B5 | Robust estimator | RANSAC; USAC/MAGSAC where available | Lowest false-success rate near viewpoint boundary |
| B6 | Local refinement | None; regularized control mesh/APAP-style donor-zone warp | Adopt only for material keeper improvement without body distortion |
| B7 | Photographer inference | Opposite-edge spatial change; person association; one-tap fallback | Highest confidence without persistent identity recognition |
| B8 | Seam | Constrained baseline; dynamic programming; protected graph cut | Simplest method meeting protected-region/naturalness gates |
| B9 | Exposure match | None; robust gain/bias; block/channel compensation | Lowest background discontinuity without changing people |
| B10 | Blend | Hard cut; narrow feather; multiband/Laplacian | Narrowest blend hiding the seam without softening people |
| B11 | Crop | Base crop; largest common region; largest protected safe crop | Retain every person and maximize real source pixels |
| B12 | QA | Registration, parallax, seam, crop, color, sharpness, person consistency | Maximize keepers with zero prohibited defects among passes |
| B13 | Ablation | Remove each selected stage | Keep complexity only when it adds measurable value |

Poisson/gradient-domain cloning is a diagnostic control for small background regions, not a default near people.

## 5. Required measurements

- match count, inlier ratio, median/p95 reprojection residual, transform plausibility, and valid overlap;
- local residual/parallax near the donor zone;
- photographer-association confidence;
- seam length/cost, minimum protected-region distance, and `seamPersonIntersection`;
- color/edge discontinuity, crop containment, retained source area, output pixels, sharpness, clipping, and banding indicators;
- automated pass/false-success rate, human keeper result, prohibited defects, dominant retake reason, and side-two-only salvage decision;
- p50/p95 stage time and peak working-set estimate.

Report product outcomes separately by physical lens and group-size band. Mac timing guides optimization but does not satisfy the iPhone performance gate.

## 6. Phase 0B exit

Freeze algorithm choices and thresholds before scoring the pre-registered 30-session evaluation set. Exit when at least 24/30 initial sessions are human keepers, zero success-labeled results contain a prohibited defect, at least 90% of automated passes are human keepers, and subgroup results are reported. Otherwise revise the capture envelope, retake policy, or engine before UI expansion.

## 7. Phase 0C portability checks

- compile the minimal chosen engine for iOS and record exact modules, versions, notices, and binary-size delta;
- compare transform, source map, seam, crop, QA decision, and output against frozen fixtures;
- run full-resolution 1x and 0.5x device smoke cases;
- measure peak memory, stage time, thermal state, output size, repeated-run stability, and Photos appearance;
- compare untiled rendering against donor-region/tiled rendering;
- validate extended-linear P3 processing and SDR P3 HEIF for clipping and banding.

Exit when the engine runs on iPhone 16 Pro Max, both smoke cases complete without memory failure, reference decisions remain consistent, no protected region is crossed or softened, Photos appearance is acceptable, and the production dependency decision is documented. These smoke cases are diagnostic and do not establish the 30-session p95 performance gate.

## 8. First private diagnostic capture finding

User-directed diagnostic evidence from one private indoor, four-person, 1x landscape session—not admitted to the development corpus and not part of the frozen 30-session gate—established the following. The session remains quarantined until the signed consent record and deletion deadline are verified:

- a worst-face-first selector chose frame 1 from both three-frame sequences; maximizing average face quality alone would have selected a side-one frame containing one materially weaker face;
- Apple Vision found three visible people per side, correctly reflecting one joining photographer and two people common to both captures;
- the handoff introduced roughly 5° roll change, 6° yaw change, and a material projective scale change, yet static-background registration remained viable;
- every straight protected seam was blocked; a curved seam could navigate the people, but the donor footprint boundary still crossed protected subjects and was correctly rejected rather than silently cutting a body;
- evaluating both donor directions was necessary: one direction placed a donor source boundary through the output interior and failed, while the reverse direction passed that gate;
- the native on-device 2K pipeline completed on an iPhone 16 Pro Max in 7.13 seconds in a diagnostic build, selected frame 1 on both sides, detected three people on both sides, and chose side two as the base;
- the result was convincing at fit-to-screen but did not meet the 100%-zoom keeper bar because the scaled Vision instance matte left visible arm/torso and fine-edge artifacts.

Decision: keep native Vision for frame scoring, person-instance discovery, homographic registration, direction selection, and early rejection. Do not label the current output keeper-ready. The next engine experiment is a higher-quality on-device person-matting/refinement stage, measured against hair, arms, clothing, and person-on-person overlap before source-resolution rendering is promoted.
