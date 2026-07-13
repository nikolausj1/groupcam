# groupCam Benchmark Protocol and Rubric

Status: frozen protocol target for the Phase 0B reference compositor and Phase 2 on-device prototype gate.

## 1. Test unit and freeze rule

A benchmark session is one initial two-sided capture plus at most one app-requested guided retake. The app build, device configuration, engine recipe, thresholds, and rubric must be frozen before the gated run. A material engine or threshold change requires a new 30-session evaluation run; earlier sessions become development data.

Phase 0B evaluates the initial-attempt gate. Phase 2 evaluates the complete initial-plus-guided-retake gate after app failure classification and retake guidance exist.

## 2. Pre-registered evaluation set

Use exactly 30 consented sessions:

| Group size | 1x | 0.5x | Total |
|---|---:|---:|---:|
| 2 people | 4 | 2 | 6 |
| 3-6 people | 8 | 4 | 12 |
| 7-12 people | 8 | 4 | 12 |
| **Total** | **20** | **10** | **30** |

Across the set, with overlap permitted, include indoor and outdoor scenes plus representative backlight, low-detail backgrounds, glasses, detailed or edge-lit hair, mild shared-group motion, and alignment error near the accepted boundary. Use at least 20 distinct groups, and do not let one group contribute more than two gated sessions. Pets are supplemental and outside the denominator. If a minor appears, the written guardian-consent rule in `Privacy and Data Lifecycle.md` applies.

Extra sessions may be used for development, calibration, and debugging. They must be labeled before evaluation and never substituted into the frozen 30-session denominator after results are known.

## 3. Capture protocol

1. Record opaque session ID, build, device, iOS version, physical lens, orientation, lighting, group size, and applicable challenge tags.
2. Give participants only the production onboarding and prompts; do not provide verbal technique coaching.
3. Capture side one and side two, retaining monotonic capture events, synchronized Core Motion samples, and source metadata.
4. If the app requests a correction during Phase 2, allow exactly one guided retake and record its failure reason.
5. Save the app decision, selected frame IDs, stage timings, dimensions, and image-free quality metrics.
6. Give reviewers only the output and neutral session ID—not source order, masks, seam, app decision, or failure history.

## 4. Keeper definition and human rubric

Three reviewers inspect every candidate fit-to-screen and at 100% zoom.

Any of these is an immediate prohibited-defect failure:

- missing or duplicated person;
- identity or facial-feature alteration;
- visibly deformed face, body, hand, clothing, or accessory;
- seam crossing a protected face/body region;
- protected person cropped out.

Reviewers score each remaining dimension from 0 to 2:

| Dimension | 0 | 1 | 2 |
|---|---|---|---|
| Seam and edges | Blocking artifact | Noticeable but keepable | Not materially noticeable |
| Background alignment/parallax | Blocking | Noticeable but keepable | Natural |
| Color/exposure continuity | Blocking | Noticeable but keepable | Natural |
| Crop/straighten/safe margins | Blocking | Acceptable compromise | Strong composition |
| Sharpness/overall photographic naturalness | Blocking | Keepable | Natural |

A reviewer approves only when there is no prohibited defect, no dimension scores 0, the total is at least 8/10, and they answer yes to: “Would you keep or share this as the group photo?” A human keeper requires approval by at least two of three blinded reviewers.

## 5. Quality gates

- Initial attempt: at least 24/30 human keepers.
- Within one guided retake in Phase 2: at least 29/30 human keepers.
- Zero candidates labeled successful may contain a prohibited person defect.
- At least `ceil(0.90 × automated-pass count)` automated passes must be human keepers.
- When the safe crop contains at least 12,000,000 source pixels, output must contain at least 12,000,000 pixels without upscaling solely to pass the gate; otherwise preserve the largest safe source crop.
- Report keeper rate, prohibited defects, size, and timing separately by physical lens and group-size band.

## 6. Performance and reliability

On Justin's iPhone 16 Pro Max reference device:

- Use nearest-rank p95 across all 30 sessions. Final side-two photo callback to preview must be at most 10 seconds.
- Run 30 default three-asset PhotoKit transactions. Save tap to confirmed PhotoKit completion p95 must be at most 20 seconds.
- Complete one airplane-mode flow for each lens/group-size combination—six flows total—with no processing network dependency.
- Complete ten consecutive full-resolution sessions, six at 1x and four at 0.5x, without crash, jetsam, corrupt output, or silent resolution reduction.

## 7. Deliverables

- frozen build and engine configuration;
- image-free session manifest without names or persistent biometric data;
- blinded reviewer sheets and adjudicated outcomes;
- aggregate keeper, defect, timing, resolution, and subgroup report;
- image-free failure-category backlog.

