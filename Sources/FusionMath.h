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
#endif
