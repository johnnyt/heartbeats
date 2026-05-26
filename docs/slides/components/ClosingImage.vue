<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  clicks?: number
}>()

// 0 = opener echo (twin ?'s)
// 1 = resolved: ring overlay + :erpc labels, caption
const frame = computed(() => Math.min(1, Math.max(0, props.clicks ?? 0)))
const resolved = computed(() => frame.value >= 1)

// ---------- Layout (mirrors PlacementQuestion.vue, compressed) ----------
const VIEW_W = 800
const VIEW_H = 340

// Fixed worker layout — matches Diagram 1
const TENANT_COLORS = ['#a78bfa', '#38bdf8', '#34d399']
const WORKERS_PER_NODE = [
  [0, 1, 2, 0],
  [1, 2, 0, 1],
  [2, 0, 1, 2],
  [0, 2, 1, 0],
]
const DOT_OFFSETS = [
  { x: -16, y: -14 },
  { x:  16, y: -14 },
  { x: -16, y:  12 },
  { x:  16, y:  12 },
]
const NODE_LABELS = ['a@', 'b@', 'c@', 'd@']

// Ring overlay — centered on cluster
const RING_CENTER = { x: 400, y: 250 }
const RING_RADIUS = 140
</script>

<template>
  <div class="closing-image">
    <svg :viewBox="`0 0 ${VIEW_W} ${VIEW_H}`" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

      <!-- ===== Translucent ring overlay (visible in resolved state) ===== -->
      <circle
        :cx="RING_CENTER.x" :cy="RING_CENTER.y" :r="RING_RADIUS"
        :class="['ring-overlay', { shown: resolved }]"
      />
      <!-- Ring vnode dots scattered around the circle -->
      <g :class="['vnode-dots', { shown: resolved }]">
        <circle
          v-for="i in 48"
          :key="i"
          :cx="RING_CENTER.x + RING_RADIUS * Math.sin((i * 137.5 * Math.PI) / 180)"
          :cy="RING_CENTER.y - RING_RADIUS * Math.cos((i * 137.5 * Math.PI) / 180)"
          r="3"
          :fill="['#a78bfa', '#38bdf8', '#34d399', '#fbbf24'][(i - 1) % 4]"
          class="vnode-dot"
        />
      </g>

      <!-- ===== Clouds + arrows ===== -->
      <!-- "register" cloud (top-left) -->
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
      <!-- Question mark — pulsing, fades out on resolve -->
      <text :class="['q-mark', { gone: resolved, pulse: !resolved }]" x="215" y="115" text-anchor="middle">?</text>
      <!-- Left ? → Ring.owner/1 -->
      <text :class="['erpc-label', { shown: resolved }]" x="215" y="115" text-anchor="middle">
        Ring.owner/1
      </text>

      <!-- "talk to me" cloud (top-right) -->
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
      <text :class="['q-mark', { gone: resolved, pulse: !resolved }]" x="585" y="115" text-anchor="middle">?</text>
      <!-- Right ? → :erpc.call -->
      <text :class="['erpc-label', { shown: resolved }]" x="585" y="115" text-anchor="middle">
        :erpc.call
      </text>

      <!-- ===== Cluster (always visible) ===== -->
      <g class="cluster" transform="translate(80, 190)">
        <g
          v-for="(workers, i) in WORKERS_PER_NODE"
          :key="i"
          :transform="`translate(${i * 180}, 0)`"
        >
          <rect x="0" y="0" width="140" height="120" rx="10" class="node-body" />
          <rect x="0" y="0" width="140" height="6" rx="3" class="node-stripe" />
          <g transform="translate(70, 60)">
            <circle
              v-for="(t, j) in workers"
              :key="j"
              :cx="DOT_OFFSETS[j].x"
              :cy="DOT_OFFSETS[j].y"
              r="8"
              :fill="TENANT_COLORS[t]"
              class="worker"
            />
          </g>
          <text x="70" y="112" text-anchor="middle" class="node-label">{{ NODE_LABELS[i] }}</text>
        </g>
      </g>

      <!-- ===== Closing caption ===== -->
      <g :class="['caption', { shown: resolved }]">
        <text :x="VIEW_W / 2" :y="VIEW_H - 10" text-anchor="middle" class="caption-text">
          these primitives — <tspan class="caption-emph">that's the whole talk</tspan>
        </text>
      </g>

      <!-- Arrowhead marker -->
      <defs>
        <marker id="arrowhead" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
          <path d="M 0,0 L 8,3 L 0,6 Z" class="arrowhead-fill" />
        </marker>
      </defs>
    </svg>
  </div>
</template>

<style scoped>
.closing-image {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Ring overlay */
.ring-overlay {
  fill: none;
  stroke: rgba(251, 191, 36, 0.0);
  stroke-width: 22;
  transition: stroke 800ms cubic-bezier(0.4, 0, 0.2, 1);
}
.ring-overlay.shown {
  stroke: rgba(251, 191, 36, 0.18);
}
.vnode-dots {
  opacity: 0;
  transition: opacity 900ms cubic-bezier(0.4, 0, 0.2, 1);
}
.vnode-dots.shown { opacity: 0.7; }
.vnode-dot {
  filter: drop-shadow(0 0 4px rgba(251, 191, 36, 0.4));
}

/* Clouds + arrows */
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
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
  opacity: 1;
}
.q-mark.gone { opacity: 0; }

@keyframes q-pulse {
  0%, 100% { opacity: 0.6; transform: scale(1); }
  50%      { opacity: 1;   transform: scale(1.15); }
}
.pulse {
  animation: q-pulse 1.4s ease-in-out infinite;
  transform-origin: center;
  transform-box: fill-box;
}

/* :erpc / Ring.owner labels */
.erpc-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 18px;
  font-weight: 700;
  fill: rgb(52, 211, 153);
  opacity: 0;
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
  transition-delay: 400ms;
}
.erpc-label.shown { opacity: 1; }

/* Cluster */
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

/* Caption */
.caption {
  opacity: 0;
  transition: opacity 500ms cubic-bezier(0.4, 0, 0.2, 1);
  transition-delay: 800ms;
}
.caption.shown { opacity: 1; }
.caption-text {
  font-family: 'Inter', sans-serif;
  font-size: 18px;
  fill: rgba(226, 232, 240, 0.85);
}
.caption-emph {
  fill: rgb(251, 191, 36);
  font-weight: 700;
  font-style: italic;
}
</style>
