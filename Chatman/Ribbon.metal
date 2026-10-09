#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The ribbon behind Chatman: a band of fine lines twisting down the screen, folding over
// itself where it turns, with dust coming off its sides. See `Ribbon.swift` for what it is
// and why it is drawn here rather than in a canvas.
//
// Every pixel works out for itself whether it is on a line. Across the band, each line sits
// at a fixed place u, from -1 at one edge to 1 at the other, and at a height y the line is at
//
//     x = centre + width·u + fold·(u³ − u)
//
// The middle term is the band facing you, the last one the band turned away and seen in
// perspective: as it twists edge-on, `width` goes through nought and `fold` is at its
// largest, and the band folds over itself — lines cross, crowd together into bright creases,
// and come out the other side in reverse order. Finding which lines pass through a pixel is
// solving that cubic for u, which gives one answer where the band lies flat and three where
// it is folded: three layers of band, all drawn.

namespace {
    constant float tau = 6.28318530718;

    // How many lines the band is made of.
    constant float lines = 84.0;

    struct Band {
        float centre;
        float width;   // signed: through nought where the band is edge-on
        float fold;
        float facing;  // which way it is turned, from -1 to 1
    };

    Band bandAt(float v, float screen, float4 phase) {
        Band band;
        band.centre = screen * (0.54
            + 0.25 * sin(tau * (0.58 * v - phase.x))
            + 0.07 * sin(tau * (1.31 * v + phase.y) + 1.3));
        float turn = tau * (0.5 * v - phase.z) + 0.6 * sin(tau * phase.w);
        float reach = screen * (0.31 + 0.05 * sin(tau * (0.8 * v + phase.y)));
        band.width = reach * cos(turn);
        band.fold = 0.42 * reach * sin(turn);
        band.facing = sin(turn);
        return band;
    }

    float across(Band b, float u) {
        return b.centre + b.width * u + b.fold * (u * u * u - u);
    }

    float squared(float x) {
        return x * x;
    }

    float cubeRoot(float x) {
        return sign(x) * pow(abs(x), 1.0 / 3.0);
    }

    float hash(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
}

// - position: where this pixel is, in points.
// - size: the view, in points.
// - phase: where four slow clocks are, each between nought and one. Kept on the phone and
//   passed in rather than worked out here, because a shader counts in single precision and
//   the seconds since 2001 don't fit in one.
// - specks: how far the dust has drifted, and a clock for its twinkling, both already
//   wrapped so that the jump back to the start lands exactly where it began.
// - depth: how far the screen in front has scrolled.
// - ground, wash: the page, and the breath of colour across it.
// - ink: the lines. accent: the light in the creases, and the dust nearest to them.
// - amounts: x the lines (the light dial), y the creases' light and the wash (the glow
//   dial), z one in the dark and nought in the light.
[[ stitchable ]] half4 ribbon(
    float2 position, half4 current,
    float2 size, float4 phase, float2 specks, float depth,
    half4 ground, half4 wash, half4 ink, half4 accent, float3 amounts
) {
    float presence = amounts.x;
    float glow = amounts.y;
    bool dark = amounts.z > 0.5;

    // A little of the scroll, so the band hangs at a distance behind the list.
    float y = position.y + depth * 0.12;
    float v = y / size.y;
    float x = position.x;

    // The page, washed with colour down the middle.
    float middle = exp(-squared((x / size.x - 0.5) / 0.55)) * exp(-squared((v - 0.5) / 0.6));
    float3 colour = mix(float3(ground.rgb), float3(wash.rgb), clamp(glow * middle * (dark ? 0.9 : 0.75), 0.0, 1.0));

    Band here = bandAt(v, size.x, phase);
    Band below = bandAt(v + 1.0 / size.y, size.x, phase);
    float reach = size.x * 0.31;

    // Which lines pass through this pixel: the cubic, solved.
    float roots[3];
    int found = 0;
    if (abs(here.fold) < 0.002 * reach) {
        if (abs(here.width) > 0.0001) { roots[0] = (x - here.centre) / here.width; found = 1; }
    } else {
        float p = (here.width - here.fold) / here.fold;
        float q = (here.centre - x) / here.fold;
        float d = q * q / 4.0 + p * p * p / 27.0;
        if (d > 0.0) {
            float s = sqrt(d);
            roots[0] = cubeRoot(-q / 2.0 + s) + cubeRoot(-q / 2.0 - s);
            found = 1;
        } else {
            float r = sqrt(-p / 3.0);
            float angle = acos(clamp(-q / (2.0 * r * r * r), -1.0, 1.0));
            for (int k = 0; k < 3; k++) {
                roots[k] = 2.0 * r * cos((angle + tau * float(k)) / 3.0);
            }
            found = 3;
        }
    }

    float pitch = 2.0 / (lines - 1.0);
    float lit = 0.0;
    float creased = 0.0;

    for (int k = 0; k < found; k++) {
        float u = roots[k];
        if (abs(u) > 1.02) continue;

        // How far apart neighbouring lines are here, across the line rather than across the
        // screen — the lines lean, and a leaning line measured sideways looks fatter.
        float spread = here.width + here.fold * (3.0 * u * u - 1.0);
        float slope = across(below, u) - across(here, u);
        float apart = abs(spread) * pitch / sqrt(1.0 + slope * slope);

        float off = abs(fract((u + 1.0) / pitch + 0.5) - 0.5) * apart;

        // A line a third of a point wide, softened over another half. Softer than it could
        // be: glass laid over a band of hard hairlines samples them coarsely, and what comes
        // through is a pattern of stripes rather than a blur.
        float drawn = 1.0 - smoothstep(0.14, 0.62, off);
        // Lines closer together than a point can't be drawn one by one: what is left is how
        // much of the space they cover, which is what the eye sees anyway — and where the
        // band creases, that is a bright seam.
        float covered = clamp(0.66 / max(apart, 0.0001), 0.0, 1.0);
        float line = mix(drawn, covered, smoothstep(1.6, 0.7, apart));

        // The side turned towards you a little brighter, as if the band had a front.
        float facing = 0.6 + 0.4 * (0.5 + 0.5 * u * here.facing);
        // Thinning out at the two edges, so it has no hard outline.
        float edge = 1.0 - smoothstep(0.88, 1.02, abs(u));

        lit += line * facing * edge;
        // How edge-on the band is just here: where the lines crowd, the light catches.
        creased += line * edge * (1.0 - smoothstep(0.0, 0.3 * reach, abs(spread)));
    }
    lit = min(lit, 1.4);
    creased = clamp(creased, 0.0, 1.0);

    float lineAlpha = lit * (dark ? 0.18 + 0.8 * presence : 0.14 + 0.6 * presence);
    float3 lineColour = mix(float3(ink.rgb), float3(accent.rgb), clamp(creased * 0.85, 0.0, 1.0));
    colour = mix(colour, lineColour, clamp(lineAlpha, 0.0, 1.0));

    // The warm light where it turns: round the middle of the band, as wide as the fold.
    float turning = 1.0 - smoothstep(0.0, 0.5, abs(here.width) / reach);
    float halo = turning * exp(-squared((x - here.centre) / (10.0 + 0.55 * abs(here.fold))));
    if (dark) {
        colour += float3(accent.rgb) * (halo * 0.24 + creased * 0.14) * glow * 1.6;
    } else {
        colour = mix(colour, float3(accent.rgb), clamp((halo * 0.22 + creased * 0.2) * glow * 1.6, 0.0, 1.0));
    }

    // Dust: at most one speck in every square of seven points, thick along the band's two
    // edges and round the turn, thinning out into a few strays anywhere. Squares are counted
    // in a column that repeats every thousand of them — seven thousand points — so the drift
    // can wrap at exactly that without anything moving.
    float cell = 7.0;
    float2 drifting = float2(x, y - specks.x);
    float2 index = floor(drifting / cell);
    float2 key = float2(index.x, fmod(fmod(index.y, 1000.0) + 1000.0, 1000.0));
    float2 spot = (index + 0.15 + 0.7 * float2(hash(key), hash(key + 17.0))) * cell;
    float gap = length(drifting - spot);

    float leftEdge = across(here, -1.0);
    float rightEdge = across(here, 1.0);
    float side = min(abs(x - leftEdge), abs(x - rightEdge));
    // Further out on the outside of a bend than on the inside, the way dust is thrown off.
    float thrown = 14.0 + 30.0 * turning + 18.0 * hash(key + 5.0);
    float near = exp(-squared(side / thrown));
    float inside = (x - min(leftEdge, rightEdge)) * (max(leftEdge, rightEdge) - x) > 0.0 ? 1.0 : 0.0;
    float density = 0.62 * near + 0.1 * inside + 0.22 * halo + 0.03;

    if (hash(key + 31.0) < density) {
        float big = hash(key + 47.0);
        float radius = 0.3 + 0.5 * big * big + 0.25 * near;
        // A whole number of twinkles an hour, so the clock wrapping at the hour is seamless.
        float rate = floor(300.0 + 900.0 * hash(key + 59.0));
        float twinkle = 0.4 + 0.6 * (0.5 + 0.5 * sin(tau * (rate * specks.y + hash(key + 71.0))));
        float speck = (1.0 - smoothstep(radius - 0.25, radius + 0.35, gap)) * twinkle
            * (0.35 + 0.9 * presence);
        float3 dust = mix(float3(ink.rgb), float3(accent.rgb), clamp(halo * 0.8 + hash(key + 83.0) * 0.3, 0.0, 1.0));
        colour = mix(colour, dust, clamp(speck * (dark ? 0.9 : 0.6), 0.0, 1.0));
    }

    return half4(half3(colour), 1.0);
}
