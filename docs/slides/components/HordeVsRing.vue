<script setup lang="ts">
defineProps<{
  clicks?: number
}>()

// Node positions for the LEFT panel — small markers around a big cloud.
const hordeNodes = [
  { id: 'a', x: 300, y: 55,  label: 'a@' },
  { id: 'b', x: 70,  y: 365, label: 'b@' },
  { id: 'c', x: 530, y: 365, label: 'c@' },
]

// Node positions for the RIGHT panel — big nodes, each owns its own ring.
const ringNodes = [
  { id: 'a', x: 230, y: 20,  label: 'a@' },
  { id: 'b', x: 20,  y: 250, label: 'b@' },
  { id: 'c', x: 440, y: 250, label: 'c@' },
]
</script>

<template>
  <div class="horde-vs-ring">
    <div class="grid grid-cols-2 gap-6 mt-2">

      <!-- ============================================================ -->
      <!-- LEFT PANEL: Horde + CRDT gossip                              -->
      <!-- ============================================================ -->
      <div class="panel">
        <div class="panel-title text-amber-400">Horde · CRDT</div>
        <svg viewBox="0 0 600 420" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

          <!-- Gossip ellipse (background) -->
          <ellipse
            :class="['gossip-cloud', { thickened: (clicks ?? 0) >= 1 }]"
            cx="300" cy="220" rx="210" ry="100"
          />
          <text x="300" y="125" text-anchor="middle" class="gossip-label">CRDT gossip</text>

          <!-- Gossip lines between nodes (dashed, animated flow) -->
          <line x1="300" y1="80" x2="80"  y2="345" class="gossip-line" />
          <line x1="80"  y1="365" x2="520" y2="365" class="gossip-line" />
          <line x1="300" y1="80" x2="520" y2="345" class="gossip-line" />

          <!-- Three small nodes -->
          <g v-for="n in hordeNodes" :key="n.id" :transform="`translate(${n.x - 30}, ${n.y - 20})`">
            <rect x="0" y="0" width="60" height="40" rx="6" class="small-node-body" />
            <rect x="0" y="0" width="60" height="3" rx="1.5" class="small-node-stripe" />
            <text x="30" y="27" text-anchor="middle" class="small-node-label">{{ n.label }}</text>
          </g>

          <!-- Duplicate pids — both pulsing yellow during convergence window -->
          <g class="pid-duplicate pid-1">
            <rect x="155" y="195" width="140" height="26" rx="4" class="pid-warn-body" />
            <text x="225" y="213" text-anchor="middle" class="pid-warn-text">worker(sub-42)</text>
            <text x="225" y="183" text-anchor="middle" class="pid-host-hint">on a@</text>
          </g>

          <g :class="['pid-duplicate', 'pid-2', { dying: (clicks ?? 0) >= 1 }]">
            <rect x="305" y="245" width="140" height="26" rx="4" class="pid-warn-body" />
            <text x="375" y="263" text-anchor="middle" class="pid-warn-text">worker(sub-42)</text>
            <text x="375" y="285" text-anchor="middle" class="pid-host-hint">on c@</text>
            <!-- Strike-through (visible after convergence resolves) -->
            <line v-if="(clicks ?? 0) >= 1" x1="305" y1="245" x2="445" y2="271" class="death-stroke" />
            <line v-if="(clicks ?? 0) >= 1" x1="445" y1="245" x2="305" y2="271" class="death-stroke" />
          </g>

          <!-- Caption (visible at click >= 1) -->
          <text
            :class="['caption-warn', { shown: (clicks ?? 0) >= 1 }]"
            x="300" y="405" text-anchor="middle"
          >
            convergence window = duplicate work
          </text>
        </svg>
      </div>

      <!-- ============================================================ -->
      <!-- RIGHT PANEL: libring + :erpc                                 -->
      <!-- ============================================================ -->
      <div class="panel">
        <div class="panel-title text-emerald-400">libring + :erpc</div>
        <svg viewBox="0 0 600 420" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

          <!-- Three big "self-contained" nodes, each with its own ring -->
          <g v-for="n in ringNodes" :key="n.id" :transform="`translate(${n.x}, ${n.y})`">
            <!-- Node body -->
            <rect x="0" y="0" width="140" height="125" rx="10" class="big-node-body" />
            <rect x="0" y="0" width="140" height="5" rx="2.5" class="big-node-stripe" />

            <!-- Node label at top -->
            <text x="70" y="24" text-anchor="middle" class="big-node-label">{{ n.label }}</text>

            <!-- Mini-ring inside the node -->
            <g transform="translate(70, 70)">
              <circle cx="0" cy="0" r="25" class="mini-ring" />
              <!-- ring positions: a at top, b at lower-right, c at lower-left -->
              <circle cx="0"   cy="-25" r="4" class="ring-marker-a" />
              <circle cx="21.7" cy="12.5" r="7" class="ring-marker-b" />
              <circle cx="-21.7" cy="12.5" r="4" class="ring-marker-c" />
              <!-- Inner label: "sub-42" near the B marker -->
              <text x="0" y="3" text-anchor="middle" class="ring-key">sub-42</text>
            </g>

            <!-- Bottom answer: "→ b@" -->
            <text x="70" y="110" text-anchor="middle" class="ring-answer">→ b@</text>
          </g>

          <!-- Caption (visible at click >= 1) -->
          <text
            :class="['caption-good', { shown: (clicks ?? 0) >= 1 }]"
            x="300" y="405" text-anchor="middle"
          >
            same answer from each node — no gossip needed
          </text>
        </svg>
      </div>

    </div>
  </div>
</template>

<style scoped>
.horde-vs-ring {
  font-family: 'Inter', system-ui, sans-serif;
}

.panel {
  display: flex;
  flex-direction: column;
}
.panel-title {
  font-family: 'JetBrains Mono', monospace;
  font-size: 1.1rem;
  font-weight: 600;
  text-align: center;
  margin-bottom: 0.5rem;
  letter-spacing: 0.05em;
}

/* ===== LEFT: Horde ===== */

.gossip-cloud {
  fill: rgba(251, 191, 36, 0.05);
  stroke: rgba(251, 191, 36, 0.35);
  stroke-width: 1.5;
  stroke-dasharray: 6 4;
  transition: all 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.gossip-cloud.thickened {
  stroke-width: 2.5;
  stroke-dasharray: 3 2;
  stroke: rgba(251, 191, 36, 0.65);
  fill: rgba(251, 191, 36, 0.08);
}
.gossip-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgba(251, 191, 36, 0.65);
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.gossip-line {
  stroke: rgba(148, 163, 184, 0.35);
  stroke-width: 1;
  stroke-dasharray: 4 4;
  animation: gossip-flow 6s linear infinite;
}
@keyframes gossip-flow {
  to { stroke-dashoffset: -32; }
}

.small-node-body {
  fill: rgba(148, 163, 184, 0.1);
  stroke: rgba(148, 163, 184, 0.55);
  stroke-width: 1.2;
}
.small-node-stripe {
  fill: rgba(148, 163, 184, 0.6);
}
.small-node-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  fill: rgba(226, 232, 240, 0.9);
}

.pid-warn-body {
  fill: rgba(251, 191, 36, 0.18);
  stroke: rgba(251, 191, 36, 0.85);
  stroke-width: 1.4;
}
.pid-warn-text {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgb(254, 240, 138);
}
.pid-host-hint {
  font-family: 'JetBrains Mono', monospace;
  font-size: 11px;
  fill: rgba(251, 191, 36, 0.7);
  letter-spacing: 0.04em;
}
.pid-duplicate {
  animation: warn-pulse 1.6s ease-in-out infinite;
  transform-origin: center;
  transform-box: fill-box;
}
@keyframes warn-pulse {
  0%, 100% { opacity: 0.85; }
  50%      { opacity: 1; }
}
.pid-2 {
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.pid-2.dying {
  opacity: 0.35;
  animation: none;
}
.death-stroke {
  stroke: rgba(244, 63, 94, 0.85);
  stroke-width: 2;
}

.caption-warn {
  font-family: 'JetBrains Mono', monospace;
  font-size: 15px;
  fill: rgba(251, 191, 36, 0.95);
  letter-spacing: 0.02em;
  opacity: 0;
  transition: opacity 500ms ease-in-out 200ms;
}
.caption-warn.shown { opacity: 1; }

/* ===== RIGHT: libring ===== */

.big-node-body {
  fill: rgba(52, 211, 153, 0.04);
  stroke: rgba(52, 211, 153, 0.45);
  stroke-width: 1.5;
}
.big-node-stripe {
  fill: rgba(52, 211, 153, 0.7);
}
.big-node-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 16px;
  fill: rgba(226, 232, 240, 0.95);
}

.mini-ring {
  fill: none;
  stroke: rgba(148, 163, 184, 0.55);
  stroke-width: 1.5;
}
.ring-marker-a, .ring-marker-c {
  fill: rgba(148, 163, 184, 0.85);
}
.ring-marker-b {
  fill: rgb(52, 211, 153);
  filter: drop-shadow(0 0 5px rgba(52, 211, 153, 0.7));
}
.ring-key {
  font-family: 'JetBrains Mono', monospace;
  font-size: 9px;
  fill: rgba(226, 232, 240, 0.75);
}
.ring-answer {
  font-family: 'JetBrains Mono', monospace;
  font-size: 14px;
  fill: rgb(52, 211, 153);
  font-weight: 600;
}

.caption-good {
  font-family: 'JetBrains Mono', monospace;
  font-size: 15px;
  fill: rgba(52, 211, 153, 0.95);
  letter-spacing: 0.02em;
  opacity: 0;
  transition: opacity 500ms ease-in-out 200ms;
}
.caption-good.shown { opacity: 1; }
</style>
