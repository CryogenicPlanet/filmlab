#include <CoreImage/CoreImage.h>
using namespace metal;

// Colour stages around the measured 3D LUT. All run in Core Image's working space, which the
// renderer sets to linear Rec.2020, the same space the LUTs were fitted in.

namespace {
    float3 srgb_decode(float3 e) {
        return select(pow((e + 0.055) / 1.055, float3(2.4)), e / 12.92, e <= 0.04045);
    }
    float3 srgb_encode(float3 l) {
        return select(1.055 * pow(max(l, 0.0), float3(1.0 / 2.4)) - 0.055, l * 12.92, l <= 0.0031308);
    }
    float bump(float x, float centre, float width) {
        float t = (x - centre) / width;
        return max(0.0, 1.0 - t * t);
    }
}

extern "C" {
namespace coreimage {

// Scene-linear Rec.2020 -> shaper domain [0,1]: per-channel gains (exposure, WB shift), then log2 around mid grey.
float4 filmlabShaper(sample_t s, float3 gains, float midGrey, float logLo, float logHi) {
    float3 lin = max(s.rgb * gains, float3(midGrey * exp2(logLo)));
    float3 enc = (log2(lin / midGrey) - logLo) / (logHi - logLo);
    return float4(clamp(enc, 0.0, 1.0), s.a);
}

// LUT output (sRGB-encoded) -> recipe tone/colour tweaks -> linear Rec.2020 for Core Image colour management.
float4 filmlabFinish(sample_t s, float highlights, float shadows, float color, float chrome) {
    float3 e = clamp(s.rgb, 0.0, 1.0);
    float3 lin = srgb_decode(e);

    // Colour-chrome-like: deepen saturated colours.
    float mx = max(lin.r, max(lin.g, lin.b));
    float mn = min(lin.r, min(lin.g, lin.b));
    float sat = mx > 1e-5 ? (mx - mn) / mx : 0.0;
    lin *= 1.0 - chrome * 0.07 * smoothstep(0.35, 1.0, sat);

    // Tone: Fuji-style highlight/shadow on encoded luma. Positive = harder (brighter highlights / darker shadows).
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float ye = srgb_encode(float3(y)).x;
    float ye2 = clamp(ye + highlights * 0.045 * bump(ye, 0.80, 0.25) - shadows * 0.045 * bump(ye, 0.22, 0.22), 0.0, 1.0);
    float y2 = srgb_decode(float3(ye2)).x;
    lin *= y > 1e-6 ? y2 / y : 1.0;

    // Colour (saturation) around luminance.
    float yl = dot(lin, float3(0.2126, 0.7152, 0.0722));
    lin = max(mix(float3(yl), lin, 1.0 + color * 0.12), 0.0);

    // Linear sRGB -> linear Rec.2020.
    const float3x3 toRec2020 = float3x3(
        float3(0.6274, 0.0691, 0.0164),
        float3(0.3293, 0.9195, 0.0880),
        float3(0.0433, 0.0114, 0.8956));
    return float4(toRec2020 * lin, s.a);
}

// Apple-processed (display-referred) frames, already linearised by Core Image -> ProRAW-equivalent linear.
// Per-channel cubic in log2 stops around mid grey, fitted from viewfinder/RAW pairs shot on the iPhone 17 Pro.
float4 filmlabPreviewLinearize(sample_t s, float4 cr, float4 cg, float4 cb) {
    float3 t = clamp(log2(max(s.rgb, float3(0.18 * exp2(-9.0))) / 0.18), -9.0, 4.0);
    float3 y = float3(
        cr.x + t.r * (cr.y + t.r * (cr.z + t.r * cr.w)),
        cg.x + t.g * (cg.y + t.g * (cg.z + t.g * cg.w)),
        cb.x + t.b * (cb.y + t.b * (cb.z + t.b * cb.w)));
    return float4(0.18 * exp2(y), s.a);
}

// Per-channel log2, for geometric-mean exposure and white-balance matching.
float4 filmlabLogRGB(sample_t s) {
    return float4(log2(max(s.rgb, float3(1e-5))), 1.0);
}

// Film-like grain: zero-mean luminance noise, strongest in the midtones.
float4 filmlabGrain(sample_t s, sample_t noise, float amount) {
    float y = dot(s.rgb, float3(0.2627, 0.6780, 0.0593));
    float ye = srgb_encode(float3(clamp(y, 0.0, 1.0))).x;
    float mask = 4.0 * ye * (1.0 - ye);
    float n = (noise.r + noise.g + noise.b) / 3.0 - 0.5;
    return float4(s.rgb * (1.0 + n * 2.0 * amount * mask), s.a);
}

}
}
