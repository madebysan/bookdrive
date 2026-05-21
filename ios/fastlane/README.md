fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios preflight

```sh
[bundle exec] fastlane ios preflight
```

Local preflight: build settings, privacy manifest, icon alpha, support URLs

### ios create_app_store_record

```sh
[bundle exec] fastlane ios create_app_store_record
```

Create or verify the App Store Connect app record

### ios release_status

```sh
[bundle exec] fastlane ios release_status
```

Read-only App Store release status check

### ios set_free_pricing

```sh
[bundle exec] fastlane ios set_free_pricing
```

Set App Store pricing to free with USA as the base territory

### ios set_app_store_availability

```sh
[bundle exec] fastlane ios set_app_store_availability
```

Set App Store availability for all current and future territories

### ios build_simulator

```sh
[bundle exec] fastlane ios build_simulator
```

Build a simulator sanity check

### ios provision_app_store

```sh
[bundle exec] fastlane ios provision_app_store
```

Create or download the App Store provisioning profile

### ios build_app_store

```sh
[bundle exec] fastlane ios build_app_store
```

Archive an App Store candidate

### ios upload_testflight

```sh
[bundle exec] fastlane ios upload_testflight
```

Upload an already-built App Store candidate to TestFlight

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload App Store metadata without binary or screenshots

### ios upload_app_privacy

```sh
[bundle exec] fastlane ios upload_app_privacy
```

Upload App Privacy answers from fastlane/app_privacy_details.json

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload App Store screenshots without submitting for review

### ios submit_app_store_review

```sh
[bundle exec] fastlane ios submit_app_store_review
```

Submit the current App Store candidate for review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
