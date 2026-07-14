# groupCam

groupCam is an iPhone app that guides two people through taking complementary group photos, then combines the authentic source pixels into one photograph containing everyone.

The current milestone is the Phase 0B prototype: portrait/landscape capture, Photo 1 lens selection and pinch zoom, locked Photo 2 framing, automatic best-frame selection, on-device person-instance analysis, bidirectional registration/compositing, source-edge rejection, and a cautious result/retake review flow. The composite is currently a 2K-long-edge diagnostic preview; full-resolution rendering and keeper-grade matting remain open work.

## Build

1. Install Xcode 26 and XcodeGen.
2. Run `xcodegen generate`.
3. Open `groupCam.xcodeproj`, choose an iPhone target, and run.

Camera behavior must be tested on a physical iPhone. The simulator uses generated scene fixtures so navigation and state handling remain testable.

## Reference compositor

The Phase 0B baseline uses committed non-person fixtures and a deterministic background-registration/protected-seam harness:

```bash
python3 -m unittest discover -s Tests/reference_compositor -v
python3 -m Tools.reference_compositor.cli \
  Fixtures/Synthetic/opposite_edges/side_one.png \
  Fixtures/Synthetic/opposite_edges/side_two.png \
  /tmp/groupcam-composite.png \
  --mask-one Fixtures/Synthetic/opposite_edges/protected_side_one.png \
  --mask-two Fixtures/Synthetic/opposite_edges/protected_side_two.png \
  --seam-start 0.57 --seam-end 0.69
```

This is an experiment harness, not the production engine. It establishes measurable registration and seam behavior before any more complex local warp or third-party iOS dependency is selected.

To test the safer single-person insertion path, add a donor mask in side-two coordinates:

```bash
python3 -m Tools.reference_compositor.cli \
  Fixtures/Synthetic/opposite_edges/side_one.png \
  Fixtures/Synthetic/opposite_edges/side_two.png \
  /tmp/groupcam-donor-composite.png \
  --mask-one Fixtures/Synthetic/opposite_edges/protected_side_one.png \
  --mask-two Fixtures/Synthetic/opposite_edges/protected_side_two.png \
  --donor-instance-mask Fixtures/Synthetic/opposite_edges/donor_photographer_a_side_two.png
```

## Product documents

- `groupCam - PRD.md`
- `groupCam - Naming Research.md`
- `Benchmark Protocol and Rubric.md`
- `Composite Engine Spike Plan.md`
- `Privacy and Data Lifecycle.md`
