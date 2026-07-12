#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iFableTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// The spark from fable.zig: body (x, y, radius, rotation), eight arm-length
// multipliers, and shed thought-sparks (12 arcs of 6 points, 2 per vec4).
uniform vec4 iFableBody;
uniform vec2 iFableVel;
uniform vec4 iArm[2];
uniform vec4 iSparkPts[36];
uniform vec4 iSparkMeta[12]; // per spark: (head, tail, env, glint)
uniform float iBass;
uniform float iMid;
uniform float iTreble;
uniform float iEnergy;
uniform float iBeat;
uniform float iBright;

out vec4 fragColor;

// ---------- noise ----------

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// ---------- palette ----------

// Claude coral, warmed toward the theme so the familiar belongs here.
vec3 coral() {
    vec3 base = vec3(0.85, 0.47, 0.34);
    vec3 accent = (iPaletteSize > 1) ? iPalette[1] : base;
    return mix(base, accent, 0.22);
}

// ---------- geometry ----------

float segDist(vec2 p, vec2 a, vec2 b, out float h) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

vec2 sparkPt(int i) {
    vec4 v = iSparkPts[i >> 1];
    return ((i & 1) == 0) ? v.xy : v.zw;
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.012, 0.014, 0.024);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88);
    vec3 cc = coral();

    // Quiet room for the spark to live in.
    float vig = 1.0 - 0.35 * length(uv - 0.5);
    vec3 col = bg * (0.85 * vig + iBass * 0.04);

    vec3 light = vec3(0.0);

    vec2 body = iFableBody.xy;
    float R = iFableBody.z;
    float rot = iFableBody.w;
    vec2 dp = fc - body;
    float body_r2 = dot(dp, dp);
    float reach = R * 4.2;

    if (body_r2 < reach * reach) {
        // Warm halo: presence before form. Bias-subtracted so it lands on
        // exactly zero at the reach boundary (reach/R is fixed, so the
        // kernel's edge value is the constant exp(-4.2²/6.5) ≈ 0.0662).
        light += cc * max(exp(-body_r2 / (R * R * 6.5)) - 0.0662, 0.0) * 0.24;

        // Motion wisp: gliding leaves a comet trail behind the body,
        // stretched opposite the velocity and fading with distance.
        float speed = length(iFableVel);
        if (speed > 30.0) {
            vec2 back = -iFableVel / speed;
            float wisp_len = min(speed * 0.35, R * 3.0);
            float h;
            float d = segDist(fc, body, body + back * wisp_len, h);
            float ww = R * 0.5 * (1.0 - h * 0.7);
            float amt = smoothstep(30.0, 220.0, speed);
            light += cc * exp(-d * d / (ww * ww * 2.0)) * (1.0 - h) * amt * 0.35;
        }

        // Eight tapered arms — the asterisk. Opposing pairs share a band,
        // so with music this is a radial equalizer breathing in coral.
        float d_min = 1e5;
        float h_min = 0.0;
        for (int k = 0; k < 8; k++) {
            float ang = rot + float(k) * 0.78539816; // tau/8
            vec2 dir = vec2(cos(ang), sin(ang));
            float len = R * iArm[k >> 2][k & 3];
            float h;
            float d = segDist(fc, body + dir * R * 0.20, body + dir * len, h);
            // Tapered to a sharp point, like the asterisk's rays.
            float w = R * 0.105 * (1.0 - h * 0.78) + 0.6;
            float sd = d - w;
            if (sd < d_min) {
                d_min = sd;
                h_min = h;
            }
        }
        float fill = smoothstep(1.4, -1.4, d_min);
        // Arms brighten toward the tips; the star breathes on beats.
        vec3 arm_c = mix(cc, mix(cc, fg, 0.55), h_min * 0.45);
        light += arm_c * fill * (0.95 + iBeat * 0.4);
        light += cc * exp(-max(d_min, 0.0) * 0.10) * 0.30;

        // A near-white heart.
        light += mix(fg, vec3(1.0), 0.5) * exp(-body_r2 / (R * R * 0.045)) * 1.3;

        // Ideas in orbit: six faint motes circling, quicker with the mids.
        float osp = iFableTime * (0.45 + iMid * 1.3);
        for (int i = 0; i < 6; i++) {
            float oa = osp + float(i) * 1.0471976; // tau/6
            float orad = R * (1.75 + 0.12 * sin(iFableTime * 0.8 + float(i) * 2.3));
            vec2 op = body + vec2(cos(oa), sin(oa)) * orad;
            vec2 od = fc - op;
            float or2 = dot(od, od);
            float tw = 0.7 + 0.3 * sin(iFableTime * 5.0 + float(i) * 1.9);
            light += cc * exp(-or2 / 26.0) * tw * (0.35 + iTreble * 0.6);
        }
    }

    // Thought-sparks: each stroke writes itself outward from the arm tip
    // (head advances), then dissolves tail-first while it drifts away —
    // the thought forms, then lets go.
    for (int s = 0; s < 12; s++) {
        vec4 M = iSparkMeta[s]; // (head, tail, env, glint)
        if (M.z < 0.02) continue;

        // Origin glint: a brief flash where the thought left the arm.
        if (M.w > 0.02) {
            vec2 o = sparkPt(s * 6);
            vec2 od = fc - o;
            float or2 = dot(od, od);
            if (or2 < 400.0) {
                light += mix(cc, vec3(1.0), 0.55) * exp(-or2 / 28.0) * M.w * 1.2;
            }
        }

        for (int j = 0; j < 5; j++) {
            float vis = clamp(M.x - float(j), 0.0, 1.0);
            if (vis <= 0.0) break; // head hasn't reached this segment
            float tail_fade = clamp(1.0 - (M.y - float(j)), 0.0, 1.0);
            if (tail_fade <= 0.0) continue; // already dissolved
            vec2 a = sparkPt(s * 6 + j);
            vec2 b = mix(a, sparkPt(s * 6 + j + 1), vis);
            vec2 lo = min(a, b) - 26.0;
            vec2 hi = max(a, b) + 26.0;
            if (fc.x < lo.x || fc.x > hi.x || fc.y < lo.y || fc.y > hi.y) continue;
            float h;
            float d = segDist(fc, a, b, h);
            // Thin toward the trailing end; the writing head burns hotter.
            float t = (float(j) + h * vis) / 5.0;
            float w = 1.6 * (1.0 - t * 0.6);
            float head_hot = (vis < 1.0) ? 1.5 : 1.0;
            float cut = exp(-26.0 * 0.30 / w);
            light += mix(cc, fg, 0.4) * (exp(-d * 0.30 / w) - cut) *
                M.z * tail_fade * head_hot * (1.0 - t * 0.4) * 0.9;
        }
    }

    // Soft Reinhard keeps the coral warm where the glow stacks.
    col += light * iBright / (1.0 + 0.30 * light * iBright);

    // Beats warm the whole room, faintly.
    col += cc * iBeat * 0.03 * vig;

    // Fine grain so the dark field never looks flat.
    col += (hash21(fc + fract(iFableTime) * 100.0) - 0.5) * 0.012;

    fragColor = vec4(col, 1.0);
}
