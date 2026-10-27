#ifndef UC_FUSION_MATH_H
#define UC_FUSION_MATH_H
// Shared scalar math: the Metal kernel and host regression tests execute the
// same exposure/variance policy, rather than testing a disconnected replica.
static inline float UCSmoothRamp(float low,float high,float value) {
    float t=(value-low)/(high-low);t=t<0 ? 0:(t>1 ? 1:t);
    return t*t*(3-2*t);
}
static inline float UCHDRExposureWeight(float low,float high,float scale) {
    float weight=1-UCSmoothRamp(0.92f,0.99f,high);
    return scale>1 ? weight*UCSmoothRamp(0.001f,0.012f,low):weight;
}
static inline float UCRAWVarianceSignal(float anchorMean,float candidateMean) {
    float signal=anchorMean>candidateMean*0.5f ? anchorMean:candidateMean*0.5f;
    return signal>0 ? signal:0;
}
#ifdef __METAL_VERSION__
#define UC_EXP metal::exp
#else
#include <math.h>
#define UC_EXP expf
#endif
static inline float UCSRPosition(float index,float phaseOffset,float origin,float scale) {
    return origin+(index+phaseOffset)/scale-phaseOffset;
}
static inline float UCSRWeight(float dx,float dy) { return UC_EXP(-(dx*dx+dy*dy)/(2*0.42f*0.42f)); }
// A temporal point must be bright in both aligned frames. With measurable
// displacement a sensor-fixed impulse explains the unwarped patch better and
// is vetoed. At exactly zero motion the two hypotheses are indistinguishable;
// preserve a consistent point rather than claiming a false classification.
static inline int UCTemporalPoint(float peak,float upper,float alignedPeak,float alignedUpper,float sigma,float displacement,float alignedError,float stationaryError) {
    if (peak<=upper+6*sigma || alignedPeak<=alignedUpper+4*sigma) return 0;
    float tolerance=peak*0.5f+8*sigma;
    float difference=peak-alignedPeak;if(difference<0) difference=-difference;
    if(difference>tolerance) return 0;
    if(displacement>0.15f && stationaryError+sigma*sigma<alignedError*0.8f) return 0;
    return 1;
}
#undef UC_EXP
#endif
