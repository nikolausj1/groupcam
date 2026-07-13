# groupCam

groupCam is an iPhone app that guides two people through taking complementary group photos, then combines the authentic source pixels into one photograph containing everyone.

The current milestone is the Phase 0A capture recorder: physical-lens selection, 1/3/5-frame sequences, capture-state feedback, motion logging, and an onion-skin guide for the second photographer.

## Build

1. Install Xcode 26 and XcodeGen.
2. Run `xcodegen generate`.
3. Open `groupCam.xcodeproj`, choose an iPhone target, and run.

Camera behavior must be tested on a physical iPhone. The simulator uses generated scene fixtures so navigation and state handling remain testable.

## Product documents

- `groupCam - PRD.md`
- `groupCam - Naming Research.md`
- `Benchmark Protocol and Rubric.md`
- `Composite Engine Spike Plan.md`
- `Privacy and Data Lifecycle.md`

