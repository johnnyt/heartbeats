<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  clicks?: number
}>()

// ---------- Geometry ----------
const CENTER = { x: 400, y: 215 }
const RADIUS = 135
const RING_STROKE = 16
const ARC_STROKE = 20
const ITEM_R = 7
const NODE_R = 17
const VNODE_R = 5

// ---------- Colors ----------
const HUE: Record<string, string> = {
  A: '#818cf8', // indigo
  B: '#2dd4bf', // teal
  C: '#fbbf24', // amber
  D: '#fb7185', // rose
  E: '#34d399', // emerald
}
const GRAY = 'rgba(148, 163, 184, 0.35)'

// ---------- Node positions (degrees clockwise from 12 o'clock) ----------
const NODE_ANGLE: Record<string, number> = { A: 0, B: 90, C: 180, D: 270, E: 45 }

// ---------- Items (16 deterministic positions in degrees CW from 12) ----------
const ITEMS: { id: string; angle: number }[] = [
  // A's arc (270..360)
  { id: 'a1', angle: 285 },
  { id: 'a2', angle: 315 },
  { id: 'a3', angle: 340 },
  { id: 'a4', angle: 355 },
  // B's arc (0..90)
  { id: 'b1', angle: 30 },   // reassigns to E in Frame 4
  { id: 'b2', angle: 55 },
  { id: 'b3', angle: 72 },
  { id: 'b4', angle: 85 },
  // C's arc (90..180)
  { id: 'c1', angle: 100 },
  { id: 'c2', angle: 125 },
  { id: 'c3', angle: 150 },
  { id: 'c4', angle: 172 },
  // D's arc (180..270)
  { id: 'd1', angle: 195 },
  { id: 'd2', angle: 218 },
  { id: 'd3', angle: 240 },
  { id: 'd4', angle: 262 },
]

// sub-42 at 4 o'clock-ish
const SUB42_ANGLE = 120

// ---------- Helpers ----------
function pt(angleDeg: number, r: number = RADIUS) {
  const rad = (angleDeg * Math.PI) / 180
  return {
    x: CENTER.x + r * Math.sin(rad),
    y: CENTER.y - r * Math.cos(rad),
  }
}

function arcPath(angleStart: number, angleEnd: number, r: number = RADIUS) {
  const a = pt(angleStart, r)
  const b = pt(angleEnd, r)
  let sweepDeg = angleEnd - angleStart
  if (sweepDeg < 0) sweepDeg += 360
  const largeArc = sweepDeg > 180 ? 1 : 0
  return `M ${a.x} ${a.y} A ${r} ${r} 0 ${largeArc} 1 ${b.x} ${b.y}`
}

type Layout = '4' | '5' | '4-noB'
function ownerOf(angle: number, layout: Layout): string {
  let live: [string, number][]
  if (layout === '4')      live = [['A', 0], ['B', 90], ['C', 180], ['D', 270]]
  else if (layout === '5') live = [['A', 0], ['E', 45], ['B', 90], ['C', 180], ['D', 270]]
  else                     live = [['A', 0], ['C', 180], ['D', 270]]
  const sorted = [...live].sort((a, b) => a[1] - b[1])
  for (const [id, na] of sorted) {
    if (na >= angle) return id
  }
  return sorted[0][0]
}

// ---------- Frame ----------
// 0 — Frame 1: A only, sub-42 hashed
// 1 — Frame 2: walk clockwise → A owns
// 2 — Frame 3: B/C/D appear, 16 items distributed
// 3 — Frame 4: E added between A and B, 1/16 reassigned
// 4 — Frame 5: reset to 4-node baseline (E gone, B back to full arc)
// 5 — Frame 6: B removed, 4/16 reassigned to C
// 6 — Frame 7: zoom out → vnodes
const frame = computed(() => Math.min(6, Math.max(0, props.clicks ?? 0)))

// Per-node visibility
const showA = computed(() => frame.value <= 5)
const showB = computed(() => frame.value === 2 || frame.value === 3 || frame.value === 4)
const showC = computed(() => frame.value >= 2 && frame.value <= 5)
const showD = computed(() => frame.value >= 2 && frame.value <= 5)
const showE = computed(() => frame.value === 3)
const showVnodes = computed(() => frame.value === 6)
const showRing = computed(() => frame.value <= 5)

// sub-42 (Frames 1-2)
const showSub42 = computed(() => frame.value <= 1)
const showHashLabel = computed(() => frame.value === 0)
const showWalkArrow = computed(() => frame.value === 1)
const sub42Adopted = computed(() => frame.value >= 1)

// Items
const showItems = computed(() => frame.value >= 2 && frame.value <= 5)
const itemLayout = computed<Layout>(() => {
  if (frame.value === 3) return '5'
  if (frame.value === 5) return '4-noB'
  return '4'  // frames 2 and 4 both show the 4-node baseline
})

// Arcs — explicit per-frame
const arcs = computed(() => {
  const out: { d: string; color: string; desat: boolean; key: string }[] = []
  const f = frame.value
  if (f === 2 || f === 4) {
    // 4-node baseline (Frame 3 and Frame 5/reset both look like this)
    const suffix = f === 2 ? 'f3' : 'f5'
    out.push({ d: arcPath(270, 360), color: HUE.A, desat: false, key: `A-${suffix}` })
    out.push({ d: arcPath(0, 90),    color: HUE.B, desat: false, key: `B-${suffix}` })
    out.push({ d: arcPath(90, 180),  color: HUE.C, desat: false, key: `C-${suffix}` })
    out.push({ d: arcPath(180, 270), color: HUE.D, desat: false, key: `D-${suffix}` })
  } else if (f === 3) {
    // E inserted — A/C/D desaturated to call out they didn't change
    out.push({ d: arcPath(270, 360), color: HUE.A, desat: true,  key: 'A-f4' })
    out.push({ d: arcPath(0, 45),    color: HUE.E, desat: false, key: 'E-f4' })
    out.push({ d: arcPath(45, 90),   color: HUE.B, desat: false, key: 'B-f4' })
    out.push({ d: arcPath(90, 180),  color: HUE.C, desat: true,  key: 'C-f4' })
    out.push({ d: arcPath(180, 270), color: HUE.D, desat: true,  key: 'D-f4' })
  } else if (f === 5) {
    // B removed — C swallows B's arc
    out.push({ d: arcPath(270, 360), color: HUE.A, desat: false, key: 'A-f6' })
    out.push({ d: arcPath(0, 180),   color: HUE.C, desat: false, key: 'C-f6' })
    out.push({ d: arcPath(180, 270), color: HUE.D, desat: false, key: 'D-f6' })
  }
  return out
})

// Counter
const counterShown = computed(() => frame.value >= 2 && frame.value <= 5)
const counterValue = computed(() => {
  if (frame.value === 2) return '16 · A:4 B:4 C:4 D:4'
  if (frame.value === 3) return 'reassigned: 1 / 16'
  if (frame.value === 4) return '16 · A:4 B:4 C:4 D:4'
  if (frame.value === 5) return 'reassigned: 4 / 16'
  return ''
})
const counterSub = computed(() => {
  if (frame.value === 3) return 'mod-N would move ~12/16'
  if (frame.value === 4) return 'back to 4-node baseline'
  if (frame.value === 5) return "only B's arc redistributed"
  return ''
})

// Vnodes
const VNODES: { angle: number; node: string }[] = (() => {
  const out: { angle: number; node: string }[] = []
  const nodes = ['A', 'B', 'C', 'D']
  for (let i = 0; i < 128; i++) {
    const angle = (i * 137.5) % 360
    out.push({ angle, node: nodes[i % 4] })
  }
  return out
})()
</script>

<template>
  <div class="hash-ring">
    <svg viewBox="0 0 800 440" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

      <!-- ===== Base gray ring ===== -->
      <circle
        :class="['fade', { shown: showRing }]"
        :cx="CENTER.x" :cy="CENTER.y" :r="RADIUS"
        fill="none" :stroke="GRAY" :stroke-width="RING_STROKE"
      />

      <!-- ===== Ownership arcs ===== -->
      <g>
        <path
          v-for="arc in arcs"
          :key="arc.key"
          :d="arc.d"
          :stroke="arc.color"
          :stroke-width="ARC_STROKE"
          fill="none"
          stroke-linecap="round"
          :class="['arc-fade', { desat: arc.desat }]"
        />
      </g>

      <!-- ===== Vnode confetti (Frame 6) ===== -->
      <g :class="['fade', { shown: showVnodes }]">
        <circle
          v-for="(v, i) in VNODES"
          :key="i"
          :cx="pt(v.angle).x" :cy="pt(v.angle).y" :r="VNODE_R"
          :fill="HUE[v.node]"
        />
      </g>

      <!-- ===== Nodes (explicit per-node visibility) ===== -->
      <g :class="['fade', { shown: showA }]">
        <circle :cx="pt(NODE_ANGLE.A).x" :cy="pt(NODE_ANGLE.A).y" :r="NODE_R" :fill="HUE.A" />
        <text :x="pt(NODE_ANGLE.A).x" :y="pt(NODE_ANGLE.A).y - NODE_R - 8" text-anchor="middle" class="node-label">A</text>
      </g>
      <g :class="['fade', { shown: showB }]">
        <circle :cx="pt(NODE_ANGLE.B).x" :cy="pt(NODE_ANGLE.B).y" :r="NODE_R" :fill="HUE.B" />
        <text :x="pt(NODE_ANGLE.B).x + NODE_R + 10" :y="pt(NODE_ANGLE.B).y + 5" text-anchor="start" class="node-label">B</text>
      </g>
      <g :class="['fade', { shown: showC }]">
        <circle :cx="pt(NODE_ANGLE.C).x" :cy="pt(NODE_ANGLE.C).y" :r="NODE_R" :fill="HUE.C" />
        <text :x="pt(NODE_ANGLE.C).x" :y="pt(NODE_ANGLE.C).y + NODE_R + 18" text-anchor="middle" class="node-label">C</text>
      </g>
      <g :class="['fade', { shown: showD }]">
        <circle :cx="pt(NODE_ANGLE.D).x" :cy="pt(NODE_ANGLE.D).y" :r="NODE_R" :fill="HUE.D" />
        <text :x="pt(NODE_ANGLE.D).x - NODE_R - 10" :y="pt(NODE_ANGLE.D).y + 5" text-anchor="end" class="node-label">D</text>
      </g>
      <g :class="['fade', { shown: showE }]">
        <circle :cx="pt(NODE_ANGLE.E).x" :cy="pt(NODE_ANGLE.E).y" :r="NODE_R" :fill="HUE.E" />
        <text :x="pt(NODE_ANGLE.E).x + NODE_R + 6" :y="pt(NODE_ANGLE.E).y - 8" text-anchor="start" class="node-label">E</text>
      </g>

      <!-- ===== sub-42 (Frames 1-2 only) ===== -->
      <g :class="['fade', { shown: showSub42 }]">
        <!-- Walk arrow (Frame 2) -->
        <path
          :class="['walk-arrow', { shown: showWalkArrow }]"
          :d="arcPath(SUB42_ANGLE, 360, RADIUS - 30)"
          stroke="#fbbf24" stroke-width="2.5" fill="none"
          stroke-dasharray="6 4"
          marker-end="url(#arrow-head)"
        />
        <!-- The dot -->
        <circle
          :cx="pt(SUB42_ANGLE).x" :cy="pt(SUB42_ANGLE).y" :r="ITEM_R + 2"
          :class="['sub42-dot', { adopted: sub42Adopted }]"
        />
        <text
          :x="pt(SUB42_ANGLE, RADIUS + 28).x"
          :y="pt(SUB42_ANGLE, RADIUS + 28).y + 4"
          text-anchor="middle"
          class="sub42-label"
        >sub-42</text>
        <!-- Hash label (Frame 1 only) -->
        <text
          :class="['hash-label', { shown: showHashLabel }]"
          x="400" y="410" text-anchor="middle"
        >hash("sub-42") = 0x8a91…</text>
      </g>

      <!-- ===== 16 items (Frames 3-5) ===== -->
      <g :class="['fade', { shown: showItems }]">
        <circle
          v-for="item in ITEMS"
          :key="item.id"
          :cx="pt(item.angle).x" :cy="pt(item.angle).y" :r="ITEM_R"
          :fill="HUE[ownerOf(item.angle, itemLayout)]"
          class="item"
        />
      </g>

      <!-- ===== Counter widget (top-right) ===== -->
      <g :class="['fade', { shown: counterShown }]" transform="translate(610, 14)">
        <rect x="0" y="0" width="175" height="68" rx="8" class="counter-bg" />
        <text x="87" y="20" text-anchor="middle" class="counter-label">items</text>
        <text x="87" y="44" text-anchor="middle" class="counter-value">{{ counterValue }}</text>
        <text x="87" y="60" text-anchor="middle" class="counter-sub">{{ counterSub }}</text>
      </g>

      <!-- ===== Frame 6 caption ===== -->
      <g :class="['fade', { shown: showVnodes }]">
        <text x="400" y="410" text-anchor="middle" class="caption-text">
          ~128 vnodes per real node — load redistributes across <tspan class="caption-emph">every</tspan> survivor
        </text>
      </g>

      <!-- ===== Arrow marker ===== -->
      <defs>
        <marker id="arrow-head" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
          <path d="M 0,0 L 6,3 L 0,6 Z" fill="#fbbf24" />
        </marker>
      </defs>
    </svg>
  </div>
</template>

<style scoped>
.hash-ring {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Generic fade — opacity 0 by default, opacity 1 when .shown is added */
.fade {
  opacity: 0;
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.fade.shown { opacity: 1; }

/* Arcs use a separate fade-in rule so each new arc fades in from 0 every render */
.arc-fade {
  opacity: 0.85;
  transition: filter 500ms cubic-bezier(0.4, 0, 0.2, 1);
  animation: arc-in 700ms cubic-bezier(0.4, 0, 0.2, 1) both;
}
.arc-fade.desat {
  filter: saturate(0.25) brightness(0.85);
}
@keyframes arc-in {
  from { opacity: 0; }
  to   { opacity: 0.85; }
}

.node-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 17px;
  font-weight: 700;
  fill: rgba(226, 232, 240, 0.95);
}

.sub42-dot {
  fill: rgba(226, 232, 240, 0.6);
  stroke: rgba(226, 232, 240, 0.9);
  stroke-width: 1.5;
  transition: fill 600ms cubic-bezier(0.4, 0, 0.2, 1),
              stroke 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.sub42-dot.adopted {
  fill: #818cf8;
  stroke: #c7d2fe;
}
.sub42-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgba(226, 232, 240, 0.85);
}
.hash-label {
  opacity: 0;
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  fill: rgba(251, 191, 36, 0.85);
  transition: opacity 400ms cubic-bezier(0.4, 0, 0.2, 1);
}
.hash-label.shown { opacity: 1; }

.walk-arrow {
  opacity: 0;
  transition: opacity 500ms cubic-bezier(0.4, 0, 0.2, 1);
}
.walk-arrow.shown { opacity: 1; }

.item {
  transition: fill 600ms cubic-bezier(0.4, 0, 0.2, 1);
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.4));
}

.counter-bg {
  fill: rgba(15, 23, 42, 0.75);
  stroke: rgba(148, 163, 184, 0.4);
  stroke-width: 1;
}
.counter-label {
  font-size: 11px;
  font-family: 'JetBrains Mono', monospace;
  fill: rgba(148, 163, 184, 0.9);
  text-transform: uppercase;
  letter-spacing: 0.1em;
}
.counter-value {
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  font-weight: 700;
  fill: rgb(251, 191, 36);
}
.counter-sub {
  font-family: 'Inter', sans-serif;
  font-size: 10px;
  font-style: italic;
  fill: rgba(226, 232, 240, 0.7);
}
.caption-text {
  font-family: 'Inter', sans-serif;
  font-size: 15px;
  fill: rgba(226, 232, 240, 0.85);
}
.caption-emph {
  fill: rgb(251, 191, 36);
  font-weight: 700;
}
</style>
