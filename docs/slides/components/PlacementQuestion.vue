<script setup lang="ts">
defineProps<{
  clicks?: number
}>()

// Fixed layout so frames are deterministic — no random per-render reshuffle.
// 4 nodes, 4 workers each, colored by tenant (3 tenants).
const tenants = ['#a78bfa', '#38bdf8', '#34d399'] // violet, sky, emerald
const workersPerNode = [
  [0, 1, 2, 0],
  [1, 2, 0, 1],
  [2, 0, 1, 2],
  [0, 2, 1, 0],
]
const dotOffsets = [
  { x: -16, y: -18 },
  { x:  16, y: -18 },
  { x: -16, y:  14 },
  { x:  16, y:  14 },
]
const nodeLabels = ['a@', 'b@', 'c@', 'd@']
</script>

<template>
  <div class="placement-question">
    <svg viewBox="0 0 800 340" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">
      <!-- ===== Twin-question state (clouds + arrows + two ?s) ===== -->
      <g :class="['twin-state', { gone: (clicks ?? 0) >= 1 }]">
        <!-- "register?" cloud, top-left -->
        <g transform="translate(80, 10)">
          <path
            d="M 20,40 Q 0,40 0,25 Q 0,10 20,10 Q 25,-2 45,0 Q 65,-2 75,10 Q 100,10 100,25 Q 100,40 80,40 Z"
            class="cloud"
          />
          <text x="50" y="27" text-anchor="middle" class="cloud-label">register?</text>
        </g>
        <!-- Arrow from register cloud -->
        <path
          d="M 165,55 Q 200,115 290,175"
          class="arrow"
          marker-end="url(#arrowhead)"
          fill="none"
        />
        <!-- Pulsing ? near arrow midpoint -->
        <text x="215" y="115" text-anchor="middle" class="q-mark pulse">?</text>

        <!-- "talk to me?" cloud, top-right -->
        <g transform="translate(610, 10)">
          <path
            d="M 20,40 Q 0,40 0,25 Q 0,10 20,10 Q 25,-2 45,0 Q 65,-2 75,10 Q 100,10 100,25 Q 100,40 80,40 Z"
            class="cloud"
          />
          <text x="50" y="27" text-anchor="middle" class="cloud-label">talk to me?</text>
        </g>
        <!-- Arrow from talk-to-me cloud -->
        <path
          d="M 635,55 Q 600,115 510,175"
          class="arrow"
          marker-end="url(#arrowhead)"
          fill="none"
        />
        <!-- Pulsing ? near arrow midpoint -->
        <text x="585" y="115" text-anchor="middle" class="q-mark pulse">?</text>
      </g>

      <!-- ===== Single-? state (after click) ===== -->
      <g :class="['single-state', { shown: (clicks ?? 0) >= 1 }]">
        <text x="400" y="100" text-anchor="middle" class="q-mark q-mark-lg">?</text>
        <text x="400" y="140" text-anchor="middle" class="placement-label">placement</text>
      </g>

      <!-- ===== Cluster (always visible) ===== -->
      <g class="cluster" transform="translate(80, 190)">
        <g
          v-for="(workers, i) in workersPerNode"
          :key="i"
          :transform="`translate(${i * 180}, 0)`"
        >
          <!-- Node body — slightly shorter for the tighter viewBox -->
          <rect x="0" y="0" width="140" height="120" rx="10" class="node-body" />
          <!-- Top stripe -->
          <rect x="0" y="0" width="140" height="6" rx="3" class="node-stripe" />
          <!-- Worker dots -->
          <g transform="translate(70, 60)">
            <circle
              v-for="(t, j) in workers"
              :key="j"
              :cx="dotOffsets[j].x"
              :cy="dotOffsets[j].y"
              r="8"
              :fill="tenants[t]"
              class="worker"
            />
          </g>
          <!-- Node label -->
          <text x="70" y="112" text-anchor="middle" class="node-label">{{ nodeLabels[i] }}</text>
        </g>
      </g>

      <!-- Arrowhead marker -->
      <defs>
        <marker
          id="arrowhead"
          markerWidth="10"
          markerHeight="10"
          refX="8"
          refY="3"
          orient="auto"
        >
          <path d="M 0,0 L 8,3 L 0,6 Z" class="arrowhead-fill" />
        </marker>
      </defs>
    </svg>
  </div>
</template>

<style scoped>
.placement-question {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Cluster nodes */
.node-body {
  fill: rgba(148, 163, 184, 0.08);
  stroke: rgba(148, 163, 184, 0.45);
  stroke-width: 1.5;
}
.node-stripe {
  fill: rgba(148, 163, 184, 0.6);
}
.node-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  fill: rgba(226, 232, 240, 0.7);
}
.worker {
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.3));
}

/* Clouds */
.cloud {
  fill: rgba(148, 163, 184, 0.1);
  stroke: rgba(148, 163, 184, 0.6);
  stroke-width: 1.5;
  stroke-dasharray: 4 3;
}
.cloud-label {
  font-size: 18px;
  fill: rgba(226, 232, 240, 0.9);
  font-style: italic;
}

/* Arrows */
.arrow {
  stroke: rgba(251, 191, 36, 0.7);
  stroke-width: 2.5;
  stroke-linecap: round;
}
.arrowhead-fill {
  fill: rgba(251, 191, 36, 0.85);
}

/* Question marks */
.q-mark {
  font-size: 48px;
  font-weight: 700;
  fill: rgb(251, 191, 36);
  font-family: 'Inter', sans-serif;
}
.q-mark-lg {
  font-size: 96px;
}
.placement-label {
  font-size: 22px;
  fill: rgb(251, 191, 36);
  font-family: 'JetBrains Mono', monospace;
  letter-spacing: 0.05em;
}

/* Pulse animation on the twin question marks */
@keyframes q-pulse {
  0%, 100% { opacity: 0.6; transform: scale(1); }
  50%      { opacity: 1;   transform: scale(1.15); }
}
.pulse {
  animation: q-pulse 1.4s ease-in-out infinite;
  transform-origin: center;
  transform-box: fill-box;
}

/* State transitions */
.twin-state,
.single-state {
  transition: opacity 700ms cubic-bezier(0.4, 0, 0.2, 1);
}
.twin-state          { opacity: 1; }
.twin-state.gone     { opacity: 0; pointer-events: none; }
.single-state        { opacity: 0; }
.single-state.shown  { opacity: 1; }
</style>
