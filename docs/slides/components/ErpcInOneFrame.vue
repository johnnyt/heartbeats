<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  clicks?: number
}>()

// 0 = two nodes, idle
// 1 = call arrow appears, a@ → b@
// 2 = b@ runs the function (spinner inside b@)
// 3 = return arrow + caption
const frame = computed(() => Math.min(3, Math.max(0, props.clicks ?? 0)))

// ---------- Layout ----------
const VIEW_W = 800
const VIEW_H = 420

const NODE_W = 280
const NODE_H = 200
const NODE_Y = 110

const A_X = 60
const B_X = VIEW_W - NODE_W - A_X    // 460

const A_CENTER_X = A_X + NODE_W / 2
const B_CENTER_X = B_X + NODE_W / 2
const NODE_CENTER_Y = NODE_Y + NODE_H / 2

// Arrows live above (call) and below (return) the nodes
const CALL_ARROW_Y = NODE_Y - 20
const RET_ARROW_Y = NODE_Y + NODE_H + 20

// Arrow endpoint x coords (slight inset from node edges)
const ARROW_FROM_A = A_X + NODE_W - 8
const ARROW_TO_B = B_X + 8
const ARROW_FROM_B = B_X + 8
const ARROW_TO_A = A_X + NODE_W - 8

// Computed visibility
const showCall = computed(() => frame.value >= 1)
const showRunning = computed(() => frame.value === 2)
const showReturn = computed(() => frame.value >= 3)
const showCaption = computed(() => frame.value >= 3)
</script>

<template>
  <div class="erpc-frame">
    <svg :viewBox="`0 0 ${VIEW_W} ${VIEW_H}`" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

      <!-- ===== Nodes (BEAM lozenges) ===== -->
      <g class="node">
        <rect :x="A_X" :y="NODE_Y" :width="NODE_W" :height="NODE_H" rx="24" class="node-body" />
        <rect :x="A_X" :y="NODE_Y" :width="NODE_W" height="6" rx="3" class="node-stripe stripe-a" />
        <text
          :x="A_CENTER_X" :y="NODE_CENTER_Y + 8"
          text-anchor="middle"
          class="node-label"
        >a@127.0.0.1</text>
      </g>

      <g class="node">
        <rect :x="B_X" :y="NODE_Y" :width="NODE_W" :height="NODE_H" rx="24" class="node-body" />
        <rect :x="B_X" :y="NODE_Y" :width="NODE_W" height="6" rx="3" class="node-stripe stripe-b" />
        <text
          :x="B_CENTER_X" :y="NODE_CENTER_Y + 8"
          text-anchor="middle"
          :class="['node-label', { running: showRunning }]"
        >b@127.0.0.1</text>

        <!-- Spinner inside b@ when it's running -->
        <g
          v-if="showRunning"
          :transform="`translate(${B_CENTER_X}, ${NODE_CENTER_Y - 38})`"
          class="spinner"
        >
          <circle r="14" class="spinner-track" />
          <g>
            <circle r="14" class="spinner-arc" />
            <animateTransform
              attributeName="transform"
              attributeType="XML"
              type="rotate"
              from="0 0 0"
              to="360 0 0"
              dur="0.9s"
              repeatCount="indefinite"
            />
          </g>
        </g>
      </g>

      <!-- ===== Call arrow (above) ===== -->
      <g :class="['arrow-group', { shown: showCall }]">
        <line
          :x1="ARROW_FROM_A" :y1="CALL_ARROW_Y"
          :x2="ARROW_TO_B"   :y2="CALL_ARROW_Y"
          class="arrow-line call-arrow"
          marker-end="url(#arrow-amber)"
        />
        <g :transform="`translate(${(ARROW_FROM_A + ARROW_TO_B) / 2}, ${CALL_ARROW_Y - 22})`">
          <rect x="-130" y="-14" width="260" height="26" rx="4" class="label-bg" />
          <text x="0" y="4" text-anchor="middle" class="arrow-label">:erpc.call(b, Mod, :fun, [arg])</text>
        </g>
      </g>

      <!-- ===== Return arrow (below) ===== -->
      <g :class="['arrow-group', { shown: showReturn }]">
        <line
          :x1="ARROW_FROM_B" :y1="RET_ARROW_Y"
          :x2="ARROW_TO_A"   :y2="RET_ARROW_Y"
          class="arrow-line return-arrow"
          marker-end="url(#arrow-emerald)"
        />
        <g :transform="`translate(${(ARROW_FROM_B + ARROW_TO_A) / 2}, ${RET_ARROW_Y + 28})`">
          <rect x="-60" y="-14" width="120" height="26" rx="4" class="label-bg label-bg-emerald" />
          <text x="0" y="4" text-anchor="middle" class="arrow-label return-label">{:ok, value}</text>
        </g>
      </g>

      <!-- ===== Caption ===== -->
      <g :class="['caption', { shown: showCaption }]">
        <text :x="VIEW_W / 2" :y="VIEW_H - 18" text-anchor="middle" class="caption-text">
          no service discovery · no auth handshake · no JSON · no HTTP — <tspan class="caption-emph">just call a function</tspan>
        </text>
      </g>

      <!-- Arrow markers -->
      <defs>
        <marker id="arrow-amber" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
          <path d="M 0,0 L 8,3 L 0,6 Z" fill="rgb(251, 191, 36)" />
        </marker>
        <marker id="arrow-emerald" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
          <path d="M 0,0 L 8,3 L 0,6 Z" fill="rgb(52, 211, 153)" />
        </marker>
      </defs>
    </svg>
  </div>
</template>

<style scoped>
.erpc-frame {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Nodes */
.node-body {
  fill: rgba(148, 163, 184, 0.08);
  stroke: rgba(148, 163, 184, 0.5);
  stroke-width: 1.5;
}
.node-stripe { }
.stripe-a { fill: #818cf8; }
.stripe-b { fill: #2dd4bf; }
.node-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 22px;
  font-weight: 700;
  fill: rgba(226, 232, 240, 0.9);
  transition: fill 400ms ease;
}
.node-label.running {
  fill: rgb(251, 191, 36);
}

/* Spinner */
.spinner-track {
  fill: none;
  stroke: rgba(148, 163, 184, 0.25);
  stroke-width: 3;
}
.spinner-arc {
  fill: none;
  stroke: rgb(251, 191, 36);
  stroke-width: 3;
  stroke-linecap: round;
  /* circumference of r=14 ≈ 88; show ~22 (one-quarter), hide the rest */
  stroke-dasharray: 22 66;
}

/* Arrows */
.arrow-group {
  opacity: 0;
  transition: opacity 500ms cubic-bezier(0.4, 0, 0.2, 1);
}
.arrow-group.shown { opacity: 1; }

.arrow-line {
  stroke-width: 3;
  stroke-linecap: round;
}
.call-arrow   { stroke: rgb(251, 191, 36); }
.return-arrow { stroke: rgb(52, 211, 153); }

.label-bg {
  fill: rgba(15, 23, 42, 0.92);
  stroke: rgba(251, 191, 36, 0.85);
  stroke-width: 1;
}
.label-bg-emerald {
  stroke: rgba(52, 211, 153, 0.85);
}
.arrow-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  font-weight: 700;
  fill: rgb(251, 191, 36);
}
.return-label {
  fill: rgb(52, 211, 153);
}

/* Caption */
.caption {
  opacity: 0;
  transition: opacity 500ms cubic-bezier(0.4, 0, 0.2, 1);
  transition-delay: 200ms;
}
.caption.shown { opacity: 1; }
.caption-text {
  font-family: 'Inter', sans-serif;
  font-size: 14px;
  fill: rgba(226, 232, 240, 0.85);
}
.caption-emph {
  fill: rgb(251, 191, 36);
  font-weight: 700;
  font-style: italic;
}
</style>
