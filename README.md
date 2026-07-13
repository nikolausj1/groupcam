# groupCam

groupCam is an iPhone app that guides two people through taking complementary group photos, then combines the authentic source pixels into one photograph containing everyone.

The current milestone is the Phase 0A capture recorder: portrait/landscape camera layouts, Photo 1 lens selection and pinch zoom, locked Photo 2 framing, 1/3/5-frame sequences, capture-state feedback, motion logging, and an onion-skin guide for the second photographer.

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

## Product documents

- `groupCam - PRD.md`
- `groupCam - Naming Research.md`
- `Benchmark Protocol and Rubric.md`
- `Composite Engine Spike Plan.md`
- `Privacy and Data Lifecycle.md`
