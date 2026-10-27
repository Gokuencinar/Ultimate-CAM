#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SOURCES=(
  Sources/SuperResolution.swift
  Sources/LensCalibration.swift
  Sources/HybridZSL.swift
  Sources/PortraitDepth.swift
  Sources/BayerScratchStorage.swift
  Sources/DNGMetadata.swift
  Sources/SensorBayerFrame.swift
  Sources/NightTonePlan.swift
  Sources/CameraFailure.swift
  Sources/ResearchWiener.swift
  Sources/CaptureRotation.swift
  Sources/CaptureMetadata.swift
  Sources/SphereViewerRenderer.swift
  Sources/SphereGeometry.swift
  Sources/SphereMetadata.swift
  Sources/SphereProcessor.swift
  Sources/MultiBandStitcher.swift
  Sources/PanoramaProcessor.swift
  Sources/PortraitProcessor.swift
  Sources/PreviewAnalysis.swift
  Sources/MovieConfiguration.swift
  Sources/MovieRecordedAsset.swift
  Sources/AdaptiveHDR.swift
  Sources/PNGLUT.swift
  Sources/PhotoCapturePolicy.swift
  Sources/WeightedTemporalMerger.swift
  Sources/ImportedPhotoProcessor.swift
  Sources/ColorRecipe.swift
  Sources/HDRCapturePlan.swift
  Sources/HDRProcessor.swift
  Sources/JPEGRenderer.swift
  Sources/NightCapturePlan.swift
  Sources/ProcessingCancellation.swift
  Sources/PreviewDecoder.swift
  Sources/ProcessingOptions.swift
  Sources/CubeLUT.swift
  Sources/ProcessingProfiles.swift
  Sources/AdvancedProcessor.swift
  Sources/LocalAlignment.swift
  Sources/NoiseAwareMerger.swift
  Sources/ImageStatistics.swift
  Sources/BurstProcessor.swift
  Sources/MetalBurstProcessor.swift
  Sources/CaptureProgress.swift
  Sources/PreviewReferenceSelector.swift
  Sources/TemporalFrameBuffer.swift
  Sources/PhotoModePolicy.swift
)
case "${1:-all}" in
  gpu) checks=(MetalGPUChecks MetalChecks PanoramaChecks SphereChecks) ;;
  rest) checks=(PortChecks ProcessorChecks MovieChecks SpectralChecks) ;;
  all) checks=(ComputationalChecks MetalGPUChecks MetalChecks PortChecks ProcessorChecks MovieChecks PanoramaChecks SphereChecks SpectralChecks) ;;
  *) echo "Usage: $0 [all|gpu|rest]" >&2; exit 2 ;;
esac
for check in "${checks[@]}"; do
  xcrun --sdk macosx swiftc -O -import-objc-header Sources/FusionMath.h "${SOURCES[@]}" "Tests/$check.swift" -o "build/$check"
  "build/$check"
done
