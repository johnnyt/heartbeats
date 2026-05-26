<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  clicks?: number
}>()

// 0 = initial cluster
// 1 = B fails, :nodedown propagates
// 2 = workers redistribute
const frame = computed(() => Math.min(2, Math.max(0, props.clicks ?? 0)))

// ---------- Layout ----------
const VIEW_W = 800
const VIEW_H = 420

const CARD_W = 150
const CARD_H = 170
const CARD_GAP = 30
const CARDS_Y = 55

// Node card positions (left x of each card)
const NODE_X: Record<string, number> = {
  A: 50,
  B: 50 + CARD_W + CARD_GAP,         // 230
  C: 50 + 2 * (CARD_W + CARD_GAP),   // 410
  D: 50 + 3 * (CARD_W + CARD_GAP),   // 590
}

// Ring-zone color for each node
const HUE: Record<string, string> = {
  A: '#818cf8', // indigo
  B: '#2dd4bf', // teal
  C: '#fbbf24', // amber
  D: '#fb7185', // rose
}

// ---------- Workers ----------
// 16 workers, 4 per node initially.
// id format: "<owner>-<n>" but ownership changes after frame 2.
// Each worker has a stable identity (its id) and a "home color" = its initial owner's hue.
type Worker = { id: string; initial: string; final: string }
const WORKERS: Worker[] = [
  // A's workers — stay on A
  { id: 'a1', initial: 'A', final: 'A' },
  { id: 'a2', initial: 'A', final: 'A' },
  { id: 'a3', initial: 'A', final: 'A' },
  { id: 'a4', initial: 'A', final: 'A' },
  // B's workers — redistribute on B's death (2 → A, 1 → C, 1 → D)
  { id: 'b1', initial: 'B', final: 'A' },
  { id: 'b2', initial: 'B', final: 'C' },
  { id: 'b3', initial: 'B', final: 'D' },
  { id: 'b4', initial: 'B', final: 'A' },
  // C's workers — stay on C
  { id: 'c1', initial: 'C', final: 'C' },
  { id: 'c2', initial: 'C', final: 'C' },
  { id: 'c3', initial: 'C', final: 'C' },
  { id: 'c4', initial: 'C', final: 'C' },
  // D's workers — stay on D
  { id: 'd1', initial: 'D', final: 'D' },
  { id: 'd2', initial: 'D', final: 'D' },
  { id: 'd3', initial: 'D', final: 'D' },
  { id: 'd4', initial: 'D', final: 'D' },
]

// Slot positions within a card (card-local x,y). Up to 6 slots in a 3x2 grid.
const SLOTS: { x: number; y: number }[] = [
  { x: 30,  y: 80  },
  { x: 75,  y: 80  },
  { x: 120, y: 80  },
  { x: 30,  y: 125 },
  { x: 75,  y: 125 },
  { x: 120, y: 125 },
]

// For 4 workers, use slots 0, 2, 3, 5 (corners only) — looks balanced
const FOUR_SLOT_INDICES = [0, 2, 3, 5]

function workerPosition(workerId: string, frameVal: number): { x: number; y: number; visible: boolean } {
  const worker = WORKERS.find((w) => w.id === workerId)!
  const owner = frameVal >= 2 ? worker.final : worker.initial

  // If we're in frame 1 and the worker belongs to B, it's mid-flight — render as floating below
  if (frameVal === 1 && worker.initial === 'B') {
    // Position as small "orphans" hovering below B's card
    const orphanIdx = WORKERS.filter((w) => w.initial === 'B').findIndex((w) => w.id === workerId)
    const xCenter = NODE_X.B + CARD_W / 2
    const xs = [-45, -15, 15, 45].map((dx) => xCenter + dx)
    return { x: xs[orphanIdx], y: CARDS_Y + CARD_H + 50, visible: true }
  }

  if (frameVal === 1 && worker.initial === 'B') {
    return { x: 0, y: 0, visible: false }
  }

  // Determine slot list for this owner at this frame
  const workersOnOwner = WORKERS.filter((w) => {
    if (frameVal >= 2) return w.final === owner
    return w.initial === owner
  })

  const slotList = workersOnOwner.length <= 4
    ? FOUR_SLOT_INDICES
    : [0, 1, 2, 3, 4, 5].slice(0, workersOnOwner.length)

  const idx = workersOnOwner.findIndex((w) => w.id === workerId)
  const slot = SLOTS[slotList[idx]]
  return {
    x: NODE_X[owner] + slot.x,
    y: CARDS_Y + slot.y,
    visible: true,
  }
}

const workerStates = computed(() => {
  return WORKERS.map((w) => {
    const pos = workerPosition(w.id, frame.value)
    return { ...w, ...pos }
  })
})

// Node count display
const nodeCount = (nodeId: string) => {
  if (frame.value <= 1) return WORKERS.filter((w) => w.initial === nodeId).length
  return WORKERS.filter((w) => w.final === nodeId).length
}

// B's visibility
const showB = computed(() => frame.value === 0)
const showBOutline = computed(() => frame.value >= 1)  // grayed-out placeholder

// Envelopes — fly from B's position to A/C/D when frame === 1
const showEnvelopes = computed(() => frame.value === 1)
const envelopeTargets = ['A', 'C', 'D']
function envelopePath(target: string): { from: { x: number; y: number }; to: { x: number; y: number } } {
  return {
    from: { x: NODE_X.B + CARD_W / 2, y: CARDS_Y + CARD_H / 2 },
    to:   { x: NODE_X[target] + CARD_W / 2, y: CARDS_Y + 30 },
  }
}

// Counter
const counterValue = computed(() => {
  if (frame.value === 0) return 'workers: 16 · A:4 B:4 C:4 D:4'
  if (frame.value === 1) return ':nodedown — 4 workers orphaned'
  return 'workers: 16 · A:6 C:5 D:5 · moved: 4 / 16'
})
</script>

<template>
  <div class="nodedown-recovery">
    <svg :viewBox="`0 0 ${VIEW_W} ${VIEW_H}`" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

      <!-- ===== Node cards ===== -->
      <g v-for="id in ['A', 'B', 'C', 'D']" :key="id" :transform="`translate(${NODE_X[id]}, ${CARDS_Y})`">
        <!-- Card body — B fades out, leaves outline -->
        <rect
          x="0" y="0" :width="CARD_W" :height="CARD_H" rx="10"
          :class="['card-body', { dead: id === 'B' && frame >= 1 }]"
          :style="{ '--hue': HUE[id] }"
        />
        <!-- Top stripe (the node's color) -->
        <rect
          x="0" y="0" :width="CARD_W" height="6" rx="3"
          :class="['card-stripe', { dead: id === 'B' && frame >= 1 }]"
          :fill="HUE[id]"
        />
        <!-- Node label -->
        <text
          :x="CARD_W / 2" y="32"
          text-anchor="middle"
          :class="['node-label', { dead: id === 'B' && frame >= 1 }]"
        >{{ id }}@</text>
        <!-- Worker count -->
        <text
          :x="CARD_W / 2" y="55"
          text-anchor="middle"
          :class="['count-label', { dead: id === 'B' && frame >= 1, bumped: id !== 'B' && frame >= 2 }]"
        >{{ id === 'B' && frame >= 1 ? '✕ down' : `${nodeCount(id)} workers` }}</text>
      </g>

      <!-- ===== :nodedown envelopes ===== -->
      <g v-if="showEnvelopes">
        <g
          v-for="target in envelopeTargets"
          :key="`env-${target}`"
          class="envelope"
        >
          <line
            :x1="envelopePath(target).from.x"
            :y1="envelopePath(target).from.y"
            :x2="envelopePath(target).to.x"
            :y2="envelopePath(target).to.y"
            class="envelope-line"
            marker-end="url(#env-arrow)"
          />
          <g :transform="`translate(${(envelopePath(target).from.x + envelopePath(target).to.x) / 2 - 22}, ${(envelopePath(target).from.y + envelopePath(target).to.y) / 2 - 11})`">
            <rect x="0" y="0" width="44" height="22" rx="3" class="envelope-bg" />
            <text x="22" y="15" text-anchor="middle" class="envelope-label">nodedown</text>
          </g>
        </g>
      </g>

      <!-- ===== Workers ===== -->
      <g class="workers">
        <g
          v-for="w in workerStates"
          :key="w.id"
          :class="['worker', { orphaned: frame === 1 && w.initial === 'B' }]"
          :transform="`translate(${w.x}, ${w.y})`"
          :style="{ opacity: w.visible ? 1 : 0 }"
        >
          <circle r="10" :fill="HUE[w.initial]" class="worker-dot" />
        </g>
      </g>

      <!-- ===== Counter widget (bottom) ===== -->
      <g transform="translate(190, 365)" class="counter">
        <rect x="0" y="0" width="420" height="38" rx="8" :class="['counter-bg', { alert: frame === 1, good: frame === 2 }]" />
        <text x="210" y="24" text-anchor="middle" :class="['counter-value', { alert: frame === 1, good: frame === 2 }]">
          {{ counterValue }}
        </text>
      </g>

      <!-- Arrow marker for envelopes -->
      <defs>
        <marker id="env-arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
          <path d="M 0,0 L 6,3 L 0,6 Z" fill="rgba(251, 191, 36, 0.9)" />
        </marker>
      </defs>
    </svg>
  </div>
</template>

<style scoped>
.nodedown-recovery {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Cards */
.card-body {
  fill: rgba(148, 163, 184, 0.08);
  stroke: var(--hue, rgba(148, 163, 184, 0.4));
  stroke-width: 1.5;
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1),
              stroke 600ms cubic-bezier(0.4, 0, 0.2, 1),
              fill 600ms cubic-bezier(0.4, 0, 0.2, 1);
  opacity: 0.95;
}
.card-body.dead {
  fill: rgba(148, 163, 184, 0.02);
  stroke: rgba(148, 163, 184, 0.25);
  stroke-dasharray: 6 4;
}
.card-stripe {
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.card-stripe.dead { opacity: 0.2; }

.node-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 18px;
  font-weight: 700;
  fill: rgba(226, 232, 240, 0.9);
  transition: fill 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.node-label.dead { fill: rgba(148, 163, 184, 0.4); }

.count-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgba(148, 163, 184, 0.85);
  transition: fill 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.count-label.dead { fill: rgba(251, 113, 133, 0.9); font-weight: 700; }
.count-label.bumped {
  fill: rgba(52, 211, 153, 0.95);
  font-weight: 700;
  animation: bump 600ms cubic-bezier(0.4, 0, 0.2, 1) 400ms 1 both;
}
@keyframes bump {
  0%   { transform: scale(1); }
  50%  { transform: scale(1.18); }
  100% { transform: scale(1); }
}

/* Workers */
.worker {
  transition: transform 900ms cubic-bezier(0.4, 0, 0.2, 1),
              opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.worker-dot {
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.45));
}
.worker.orphaned .worker-dot {
  animation: orphan-pulse 1.4s ease-in-out infinite;
}
@keyframes orphan-pulse {
  0%, 100% { transform: scale(1); filter: drop-shadow(0 0 4px rgba(251, 191, 36, 0.5)); }
  50%      { transform: scale(1.15); filter: drop-shadow(0 0 10px rgba(251, 191, 36, 0.85)); }
}

/* Envelopes */
.envelope-line {
  stroke: rgba(251, 191, 36, 0.7);
  stroke-width: 2;
  stroke-dasharray: 5 4;
  animation: env-fade-in 500ms cubic-bezier(0.4, 0, 0.2, 1) both;
}
.envelope-bg {
  fill: rgba(15, 23, 42, 0.95);
  stroke: rgba(251, 191, 36, 0.8);
  stroke-width: 1;
  animation: env-fade-in 500ms cubic-bezier(0.4, 0, 0.2, 1) 200ms both;
}
.envelope-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 11px;
  font-weight: 700;
  fill: rgba(251, 191, 36, 0.95);
  animation: env-fade-in 500ms cubic-bezier(0.4, 0, 0.2, 1) 200ms both;
}
@keyframes env-fade-in {
  from { opacity: 0; }
  to   { opacity: 1; }
}

/* Counter */
.counter-bg {
  fill: rgba(15, 23, 42, 0.78);
  stroke: rgba(148, 163, 184, 0.4);
  stroke-width: 1;
  transition: stroke 500ms ease;
}
.counter-bg.alert { stroke: rgba(251, 113, 133, 0.9); }
.counter-bg.good { stroke: rgba(52, 211, 153, 0.85); }
.counter-value {
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  font-weight: 700;
  fill: rgb(251, 191, 36);
  transition: fill 500ms ease;
}
.counter-value.alert { fill: rgb(251, 113, 133); }
.counter-value.good { fill: rgb(52, 211, 153); }
</style>
