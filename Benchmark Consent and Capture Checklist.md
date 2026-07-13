# groupCam Benchmark Consent and Capture Checklist

Use this template only for private prototype testing. It documents informed permission and the agreed data handling; it is not a substitute for legal advice where local law requires a specific release.

Do not put completed forms, participant names, signatures, or private session images in Dropbox, `_inbox`, GitHub, or this project folder. Store completed records with the corresponding corpus session in the approved encrypted local folder.

## Study details

- Project: groupCam private technical prototype
- Purpose: test whether two real group photos can be aligned and combined naturally on-device
- Project owner: Justin Nikolaus
- Implementation access: Justin and the implementation agent operating locally on Justin's Mac
- Human reviewers: ____________________ and ____________________
- Session ID: ____________________
- Capture date: ____________________
- Final deletion deadline: ____________________

## What participants agree to

I understand that:

- groupCam will capture two short rear-camera photo sequences of this group;
- source photos, capture metadata, and motion/timing logs will be transferred to Justin's FileVault-protected Mac for private technical evaluation;
- Justin, the local implementation agent, and the two reviewers named above may inspect the photos at full resolution;
- the photos will not be published, placed in a code repository or cloud project folder, used to train an AI model, sold, or reused for an unrelated purpose;
- only anonymous/image-free aggregate results and wholly synthetic fixtures may be committed to the project repository;
- participation is voluntary, and I may decline without consequence;
- I may request withdrawal before aggregate benchmark publication by contacting Justin and identifying the session ID;
- on withdrawal, or by the stated deletion deadline, the app-managed and Mac corpus copies will be deleted; secure physical overwrite of flash storage is not promised.

## Adult participants

Each adult who appears in either source sequence must sign before capture.

| Printed name | Signature | Date |
|---|---|---|
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |

## Minors

Complete one row for every minor who appears in either sequence. A parent or legal guardian must sign before capture.

| Minor's first name or code | Guardian printed name | Guardian signature | Date |
|---|---|---|---|
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |

## Operator pre-capture checklist

- [ ] Every visible adult signed above.
- [ ] Every visible minor has guardian authorization above.
- [ ] No non-consenting bystander is identifiable in the frame.
- [ ] The two named reviewers and deletion deadline are filled in.
- [ ] The group received only the app's normal capture instructions, not extra coaching.
- [ ] The app's in-session consent confirmation is enabled.

## Capture record

- Group-size band: [ ] 2 people  [ ] 3-6 people  [ ] 7-12 people
- Physical lens: [ ] 1x  [ ] 0.5x
- Orientation: [ ] portrait  [ ] landscape
- Environment: [ ] indoor  [ ] outdoor
- Challenge tags: [ ] backlit  [ ] low-detail background  [ ] glasses  [ ] detailed/edge-lit hair  [ ] mild group motion  [ ] alignment boundary
- Initial session completed: [ ] yes  [ ] hard capture/configuration failure
- Corpus Export transferred directly to the approved encrypted local folder: [ ] yes
- Export verified, then app-private session deleted: [ ] yes

## Corpus intake checklist on the Mac

- [ ] Session folder is inside the approved non-cloud corpus root.
- [ ] Folder name uses only the opaque session ID.
- [ ] The single ZIP package passes `unzip -t`; its source HEIFs open and the manifest contains capture events and Core Motion samples.
- [ ] Completed consent record is stored with access restricted to the approved reviewers.
- [ ] No copy remains in Downloads, AirDrop staging, Dropbox, iCloud Drive, `_inbox`, or the repository.
- [ ] Deletion deadline is entered in the private corpus register.
