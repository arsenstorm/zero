import Foundation

/// The dithered backdrop the Mac's new task page and the phone's empty inbox draw: a planet's lit edge against the sky,
/// as a grid of dots in four levels per colour with ordered (Bayer) dithering, on the page's own colour. Metal source,
/// compiled at run time by the system (the build needs no Metal toolchain); each app draws it in a Metal view.
public enum Dither {
    /// What the shader is given: the drawable's size and a dot's cell in pixels, the page's colour, and how far it has
    /// come in (0 none of it, 1 all: the dots arrive in a sweep).
    public struct Uniforms {
        public var size: SIMD2<Float>
        public var cell: Float
        public var dark: Float
        public var ground: SIMD4<Float>
        public var reveal: Float
        /// A rounded rectangle (x, y, width, height in pixels; none, zero width) drawn as the dots blur to rather than
        /// as dots, fading back to dots over `feather` beyond it: frosted glass under what sits there (the composer).
        public var frost: SIMD4<Float>
        public var frostRadius: Float
        public var feather: Float
        public init(size: SIMD2<Float>, cell: Float, dark: Bool, ground: SIMD4<Float>, reveal: Float = 1,
                    frost: SIMD4<Float> = .zero, frostRadius: Float = 0, feather: Float = 0) {
            self.size = size; self.cell = cell; self.dark = dark ? 1 : 0; self.ground = ground; self.reveal = reveal
            self.frost = frost; self.frostRadius = frostRadius; self.feather = feather
        }
    }

    public static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 size; float cell; float dark; float4 ground; float reveal; float4 frost; float frostRadius; float feather; };
    struct Point { float4 position [[position]]; };

    // One triangle covering the view.
    vertex Point dither_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return Point { float4(p * 2 - 1, 0, 1) };
    }

    float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3 - 2 * f);
        return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
    }
    float fbm(float2 p) {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < 5; i++) { sum += amplitude * noise(p); p = p * 2.03 + 17.0; amplitude *= 0.5; }
        return sum;
    }

    // The scene at a point (x across, scaled to the height; y down, 0 to 1).
    float3 scene(float2 p) {
        // A planet far below and to the right; its lit edge crosses the page from upper left to lower right.
        float d = length(p - float2(1.55, 2.45)) - 2.0;
        float wobble = 0.035 * (fbm(p * 4) - 0.5);
        float edge = d + wobble;
        float sky = smoothstep(0.0, 0.02, edge);
        // Sky: deep blue, brighter near the atmosphere, streaked.
        float streaks = fbm(float2(p.x * 2.5 + p.y * 1.5, p.y * 9));
        float3 blue = mix(float3(0.02, 0.05, 0.14), float3(0.20, 0.42, 0.85), exp(-max(edge, 0.0) * 3.2)) * (0.55 + 0.8 * streaks);
        // The planet: dark, faintly textured, darker away from its edge.
        float3 ground = float3(0.16, 0.10, 0.12) * (0.3 + 1.2 * fbm(p * 9)) * (0.45 + 0.55 * exp(min(edge, 0.0) * 3));
        float3 colour = mix(ground, blue, sky);
        // The edge burning: white-hot at its line, orange then red around it.
        float glow = exp(-abs(edge) * 22) * (0.7 + 0.6 * fbm(p * 12));
        float halo = exp(-abs(edge - 0.02) * 6) * (0.6 + 0.8 * fbm(p * 5 + 3));
        colour += mix(float3(0.85, 0.30, 0.08), float3(0.40, 0.62, 1.0), sky) * halo * 0.45 + float3(1.0, 0.40, 0.10) * glow + float3(1.0, 0.85, 0.65) * pow(glow, 3.0);
        return colour;
    }

    constant float bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

    fragment float4 dither_fragment(Point in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 cell = floor(in.position.xy / u.cell);
        float2 within = fract(in.position.xy / u.cell);
        // The scene by the view's shorter side. A tall view (a phone) has it lower, the planet's edge crossing its lower
        // half, so words in its middle are on the sky rather than the glow.
        float2 centre = (cell + 0.5) * u.cell;
        float side = min(u.size.x, u.size.y);
        float2 p = centre / side - float2(0, max(u.size.y - u.size.x, 0.0) * 0.8 / side);
        float2 q = centre / u.size;
        int2 b = int2(cell) & 3;
        float threshold = (bayer[b.y * 4 + b.x] + 0.5) / 16;
        // Coming in: a cell appears once a sweep from the top left reaches it, a little sooner or later by its
        // place in the dither, so the dots arrive scattered rather than as a hard line.
        float along = clamp((q.x + q.y) * 0.5, 0.0, 1.0);
        if (0.6 * along + 0.4 * threshold > u.reveal) { return float4(u.ground.rgb, 1); }
        float3 colour = clamp(scene(p), 0.0, 1.0);
        // Fades out toward the foot, where the composer is.
        colour *= 1 - 0.6 * smoothstep(0.5, 1.0, q.y);
        // Four levels of brightness, the steps between them dithered, each dot in its patch's own colour: dithered
        // channel by channel, the three rounded apart and a blue sky threw out green and pink dots, like a screen's
        // subpixels seen up close.
        float bright = max(colour.r, max(colour.g, colour.b));
        float3 levels = bright > 0.001 ? colour / bright * (floor(bright * 3 + threshold) / 3) : float3(0);
        // Each cell a dot, a gap around it.
        float inside = step(within.x, 0.72) * step(within.y, 0.72);
        // Frosted where the composer is, fading back over its edge: what the dots blur to, not the dots. A dot covers
        // 0.72² of its cell, so that's the share of its colour a blur keeps.
        float frosted = 0;
        if (u.frost.z > 0) {
            float2 extent = u.frost.zw * 0.5;
            float2 off = abs(in.position.xy - (u.frost.xy + extent)) - (extent - u.frostRadius);
            float outside = length(max(off, 0.0)) + min(max(off.x, off.y), 0.0) - u.frostRadius;
            frosted = 1 - smoothstep(0.0, u.feather, outside);
        }
        const float share = 0.5184;
        if (u.dark > 0.5) {
            // Dark: lit dots on the page's colour.
            float lit = inside * step(0.01, levels.r + levels.g + levels.b);
            float3 dotted = mix(u.ground.rgb, max(u.ground.rgb, levels), lit);
            // Smoked glass: the colour through it, half way back to the page's dark, so white words on it always read
            // (the glow behind came through light grey).
            float3 blurred = mix(u.ground.rgb, max(u.ground.rgb, colour), share * 0.5);
            return float4(mix(dotted, blurred, frosted), 1);
        }
        // Light: paper everywhere but around the planet's edge, the one bright thing as in the dark: printed blue
        // above it, warm at its line, orange-red below, fading out both ways. (The dark scene printed on white covered
        // the page in a flat tint, its brightest part left blank.)
        float d = length(p - float2(1.55, 2.45)) - 2.0;
        float e = d + 0.035 * (fbm(p * 4) - 0.5);
        float t = clamp(exp(-abs(e) * 7.0) * (0.7 + 0.6 * fbm(p * 6)) * (1 - 0.6 * smoothstep(0.5, 1.0, q.y)), 0.0, 1.0);
        float3 core = float3(1.0, 0.72, 0.30), above = float3(0.22, 0.42, 0.95), below = float3(0.92, 0.30, 0.12);
        float3 ink = e > 0 ? mix(core, above, smoothstep(0.0, 0.10, e)) : mix(core, below, smoothstep(0.0, 0.06, -e));
        float inked = inside * step(threshold, t);
        float3 dotted = mix(u.ground.rgb, ink, inked * (0.5 + 0.45 * t));
        // Frosted white: the colour through it, a little paler, so dark words on it always read.
        float3 blurred = mix(u.ground.rgb, ink, share * t * (0.5 + 0.45 * t) * 0.7);
        return float4(mix(dotted, blurred, frosted), 1);
    }
    """
}
