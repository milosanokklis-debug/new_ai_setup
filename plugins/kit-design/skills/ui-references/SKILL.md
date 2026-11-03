---
name: ui-references
description: Curated animation and design reference sites with when to use each, plus the rules for borrowing from them (check the licence, honour prefers-reduced-motion). Use when looking for motion, easing, animated-component or design inspiration, or before copying a component from a gallery.
---
# UI references

Fetch these with WebFetch when you need the real page; do not quote them from memory.

| Site | Use it when |
|---|---|
| https://motion.dev/docs | Animating with Motion (motion/react, vanilla JS): API, springs, gestures, layout animation. |
| https://gsap.com/docs/v3/ | Timelines, ScrollTrigger and complex sequenced animation with GSAP. |
| https://animations.dev | Learning how to choose animation, timing and easing for UI that feels right. |
| https://easings.net | Picking a named easing function and seeing its curve. |
| https://cubic-bezier.com | Tuning a custom cubic-bezier curve and previewing it. |
| https://lottiefiles.com | Finding ready-made Lottie animations (icons, illustrations, loaders). |
| https://rive.app | Interactive, state-driven vector animation (Rive runtime). |
| https://magicui.design | Animated React/Tailwind components for landing pages. |
| https://ui.aceternity.com | Showy animated React/Tailwind components and effects. |
| https://reactbits.dev | Animated React components, backgrounds and text effects. |
| https://animata.design | Small animated Tailwind components with copyable code. |
| https://tympanus.net/codrops/ | Tutorials and demos for advanced CSS/WebGL/scroll effects. |
| https://web.dev/articles/prefers-reduced-motion | Why and how to honour reduced motion (web.dev guidance). |
| https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion | The prefers-reduced-motion media query reference (MDN). |

## Rules

- Check a component's licence before copying it. Read the repo or site licence; some galleries restrict commercial use, redistribution or have paid tiers. If it is unclear, say so and ask instead of copying.
- Always respect prefers-reduced-motion. Any animation you add must have a reduced-motion path: remove or shorten movement (keep opacity or colour changes), and stop autoplay and parallax.
- Prefer what the project already uses (its animation library, its tokens) over adding a new dependency for one effect.
