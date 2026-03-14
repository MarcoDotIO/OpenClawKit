# Testing and Validation

The package ships with unit, end-to-end, Apple-platform, and Linux runtime
validation paths. The same scripts used locally are also consumed by CI.

## Recommended Local Gate

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/lint-swift.sh
Scripts/check-networking-concurrency.sh
swift test
Scripts/build-docs-site.sh
./Scripts/build-ios-example.sh
./Scripts/test-ios-example.sh
./Scripts/build-tvos-example.sh
```

## Linux in Docker

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 Scripts/build-linux-runtime.sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 Scripts/check-networking-concurrency.sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 Scripts/test-linux-runtime.sh
```

## CI and Docs Publishing

The main CI workflow validates Swift builds, tests, Apple example builds, and
SwiftLint. The documentation workflow builds this Swift-DocC site on pull
requests and deploys it to GitHub Pages after successful pushes to `main`.
