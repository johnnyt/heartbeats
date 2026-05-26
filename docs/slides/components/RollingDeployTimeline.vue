<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  clicks?: number
}>()

const playing = computed(() => (props.clicks ?? 0) >= 1)

// ---------- Layout ----------
const VIEW_W = 800
const VIEW_H = 440

const TL_X0 = 90         // timeline left edge (leaves room for "workers" label)
const TL_X1 = 750        // timeline right edge
const TL_W = TL_X1 - TL_X0   // 680
const TOTAL_SEC = 20         // total wall-clock seconds depicted
const SWEEP_DUR_S = 5        // presentation duration of the sweep

const LANE_H = 30
const LANE_GAP = 12
const LANES_TOP = 55

// Each restart cycle is 5 seconds: cordon (0.5) → drain (1.5) → restart (2.0) → settle (1.0)
// Order: B at t=0, C at t=5, D at t=10, A at t=15
const NODES = [
  { id: 'A', cycleStart: 15 },
  { id: 'B', cycleStart: 0 },
  { id: 'C', cycleStart: 5 },
  { id: 'D', cycleStart: 10 },
]

// Worker-count graph area
const WC_Y_TOP = 290
const WC_Y_BOTTOM = 380
const WC_LINE_Y = 320      // the flat worker-count line lives here

// ---------- Helpers ----------
function secToX(sec: number): number {
  return TL_X0 + (sec / TOTAL_SEC) * TL_W
}

function laneY(index: number): number {
  return LANES_TOP + index * (LANE_H + LANE_GAP)
}

// Build the segments for one node's lane
type State = 'active' | 'cordon' | 'drain' | 'restart' | 'settle'
const STATE_COLOR: Record<State, string> = {
  active:  '#34d399', // emerald
  cordon:  '#fbbf24', // amber
  drain:   '#fb923c', // orange
  restart: '#94a3b8', // slate
  settle:  '#34d399', // back to emerald
}

function segmentsFor(cycleStart: number): { state: State; from: number; to: number }[] {
  const out: { state: State; from: number; to: number }[] = []
  const cs = cycleStart
  if (cs > 0) out.push({ state: 'active', from: 0, to: cs })
  out.push({ state: 'cordon',  from: cs,       to: cs + 0.5 })
  out.push({ state: 'drain',   from: cs + 0.5, to: cs + 2.0 })
  out.push({ state: 'restart', from: cs + 2.0, to: cs + 4.0 })
  out.push({ state: 'settle',  from: cs + 4.0, to: cs + 5.0 })
  if (cs + 5 < TOTAL_SEC) out.push({ state: 'active', from: cs + 5, to: TOTAL_SEC })
  return out
}

const lanes = NODES.map((n, i) => ({
  id: n.id,
  y: laneY(i),
  segments: segmentsFor(n.cycleStart),
}))

// Tick marks every 5 seconds
const TICKS = [0, 5, 10, 15, 20]
</script>

<template>
  <div class="rolling-deploy-timeline">
    <svg
      :viewBox="`0 0 ${VIEW_W} ${VIEW_H}`"
      class="w-full h-auto"
      xmlns="http://www.w3.org/2000/svg"
      :style="{ '--sweep-dur': `${SWEEP_DUR_S}s`, '--sweep-end-x': `${TL_W}px` }"
    >
      <!-- Clip path: width animated via CSS when .playing is set. Both
           presenter and audience views toggle .playing simultaneously, so
           the animation start is synced. -->
      <defs>
        <clipPath id="sweep-clip">
          <rect
            :class="['sweep-rect', { playing }]"
            :x="TL_X0" y="0" :height="VIEW_H"
          />
        </clipPath>
      </defs>

      <!-- ===== Static structure (lane labels, ticks, axis) ===== -->

      <!-- Lane backgrounds (dim, always visible) -->
      <rect
        v-for="lane in lanes"
        :key="`bg-${lane.id}`"
        :x="TL_X0" :y="lane.y"
        :width="TL_W" :height="LANE_H"
        rx="4"
        class="lane-bg"
      />

      <!-- Lane labels -->
      <text
        v-for="lane in lanes"
        :key="`label-${lane.id}`"
        :x="TL_X0 - 12"
        :y="lane.y + LANE_H / 2 + 5"
        text-anchor="end"
        class="lane-label"
      >{{ lane.id }}</text>

      <!-- Tick marks -->
      <g class="ticks">
        <g v-for="t in TICKS" :key="`tick-${t}`">
          <line
            :x1="secToX(t)" :x2="secToX(t)"
            :y1="LANES_TOP - 6" :y2="WC_Y_BOTTOM + 4"
            class="tick-line"
          />
          <text
            :x="secToX(t)" :y="WC_Y_BOTTOM + 20"
            text-anchor="middle"
            class="tick-label"
          >{{ t }}s</text>
        </g>
      </g>

      <!-- Worker-count baseline (gray reference line, always visible) -->
      <line
        :x1="TL_X0" :x2="TL_X1"
        :y1="WC_LINE_Y" :y2="WC_LINE_Y"
        class="wc-baseline"
        stroke-dasharray="3 4"
      />

      <!-- Worker-count y-axis label -->
      <text
        :x="TL_X0 - 12" :y="WC_LINE_Y + 5"
        text-anchor="end"
        class="wc-axis-label"
      >workers</text>
      <text
        :x="TL_X0 - 12" :y="WC_LINE_Y - 12"
        text-anchor="end"
        class="wc-axis-value"
      >50</text>

      <!-- ===== Animated content (revealed by the growing clip rect) ===== -->
      <g clip-path="url(#sweep-clip)">

        <!-- Gantt segments -->
        <g
          v-for="lane in lanes"
          :key="`segs-${lane.id}`"
        >
          <rect
            v-for="(seg, j) in lane.segments"
            :key="j"
            :x="secToX(seg.from)"
            :y="lane.y"
            :width="secToX(seg.to) - secToX(seg.from)"
            :height="LANE_H"
            :fill="STATE_COLOR[seg.state]"
            class="segment"
          />
        </g>

        <!-- The flat worker-count line — the whole point of the slide -->
        <line
          :x1="TL_X0" :x2="TL_X1"
          :y1="WC_LINE_Y" :y2="WC_LINE_Y"
          class="wc-line"
        />

        <!-- Subtle area fill below the line to ground it visually -->
        <rect
          :x="TL_X0" :y="WC_LINE_Y"
          :width="TL_W" :height="WC_Y_BOTTOM - WC_LINE_Y"
          class="wc-fill"
        />
      </g>

      <!-- ===== Playhead — wrapped in a <g> so CSS transform moves it ===== -->
      <g :class="['playhead-wrap', { playing }]">
        <line
          :x1="TL_X0" :x2="TL_X0"
          :y1="LANES_TOP - 8" :y2="WC_Y_BOTTOM + 4"
          class="playhead-line"
        />
      </g>

      <!-- ===== Legend (static, top-right) ===== -->
      <g transform="translate(380, 20)" class="legend">
        <g v-for="(item, i) in [
          { state: 'active',  label: 'active' },
          { state: 'cordon',  label: 'cordoned' },
          { state: 'drain',   label: 'draining' },
          { state: 'restart', label: 'restarting' },
        ]" :key="i" :transform="`translate(${i * 95}, 0)`">
          <rect x="0" y="0" width="12" height="12" rx="2" :fill="STATE_COLOR[item.state as State]" />
          <text x="18" y="10" class="legend-label">{{ item.label }}</text>
        </g>
      </g>

      <!-- ===== Punchline caption (appears at end of sweep) ===== -->
      <g :class="['caption', { shown: playing }]">
        <text
          :x="(TL_X0 + TL_X1) / 2"
          :y="WC_LINE_Y - 28"
          text-anchor="middle"
          class="caption-text"
        >active workers — flat the whole way</text>
      </g>
    </svg>
  </div>
</template>

<style scoped>
.rolling-deploy-timeline {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Lane backgrounds */
.lane-bg {
  fill: rgba(148, 163, 184, 0.08);
  stroke: rgba(148, 163, 184, 0.2);
  stroke-width: 1;
}
.lane-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  font-weight: 700;
  fill: rgba(226, 232, 240, 0.85);
}

/* Tick marks */
.tick-line {
  stroke: rgba(148, 163, 184, 0.25);
  stroke-width: 1;
}
.tick-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 11px;
  fill: rgba(148, 163, 184, 0.7);
}

/* Worker-count line */
.wc-baseline {
  stroke: rgba(148, 163, 184, 0.3);
  stroke-width: 1;
}
.wc-line {
  stroke: #fbbf24;
  stroke-width: 3;
  filter: drop-shadow(0 0 4px rgba(251, 191, 36, 0.4));
}
.wc-fill {
  fill: rgba(251, 191, 36, 0.06);
}
.wc-axis-label {
  font-family: 'Inter', sans-serif;
  font-size: 11px;
  fill: rgba(148, 163, 184, 0.7);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.wc-axis-value {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  font-weight: 700;
  fill: rgba(251, 191, 36, 0.9);
}

/* Gantt segments */
.segment {
  filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.25));
}

/* ---------- Sweep animation (driven by .playing class) ---------- */

/* Clip rect: width grows from 0 to TL_W over SWEEP_DUR_S.
   CSS-animating SVG attribute width works in modern browsers, and
   crucially it's triggered by class change (synced across views) rather
   than mount time (which Slidev can fire early during slide pre-render). */
.sweep-rect {
  width: 0;
}
.sweep-rect.playing {
  animation: sweep-grow var(--sweep-dur, 5s) linear forwards;
}
@keyframes sweep-grow {
  from { width: 0; }
  to   { width: var(--sweep-end-x, 660px); }
}

/* Playhead: a wrapping <g> we transform via CSS so the line moves with the
   clip's right edge. */
.playhead-wrap {
  opacity: 0;
  transform: translateX(0);
}
.playhead-wrap.playing {
  opacity: 1;
  animation: playhead-sweep var(--sweep-dur, 5s) linear forwards;
}
@keyframes playhead-sweep {
  from { transform: translateX(0); }
  to   { transform: translateX(var(--sweep-end-x, 660px)); }
}
.playhead-line {
  stroke: rgba(226, 232, 240, 0.85);
  stroke-width: 1.5;
  stroke-dasharray: 4 3;
}

/* Legend */
.legend-label {
  font-family: 'Inter', sans-serif;
  font-size: 11px;
  fill: rgba(226, 232, 240, 0.75);
}

/* Caption */
.caption {
  opacity: 0;
  transition: opacity 400ms cubic-bezier(0.4, 0, 0.2, 1);
  transition-delay: 4.5s;  /* land near the end of the sweep */
}
.caption.shown { opacity: 1; }
.caption-text {
  font-family: 'Inter', sans-serif;
  font-size: 14px;
  font-style: italic;
  fill: rgba(251, 191, 36, 0.95);
  font-weight: 600;
}
</style>
