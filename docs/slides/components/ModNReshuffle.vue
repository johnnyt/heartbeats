<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  clicks?: number
}>()

const reshuffled = computed(() => (props.clicks ?? 0) >= 1)

// ---------- Layout ----------
const VIEW_W = 800
const VIEW_H = 420

const COL_W = 110
const COL_H = 260
const COL_TOP = 60

// 3 cols centered around x=400, 4 cols centered around x=400
const COLS_3 = [225, 345, 465]            // shown when reshuffled = false
const COLS_4 = [165, 285, 405, 525]       // shown when reshuffled = true
const COL_OFFSCREEN_X = 880               // 4th column slides in from here (well past the viewBox)

// ---------- Items ----------
// 12 items with stable IDs and colors. hash(i) = i for simplicity.
const ITEM_COLORS = [
  '#818cf8', // 0 indigo
  '#38bdf8', // 1 sky
  '#34d399', // 2 emerald
  '#fbbf24', // 3 amber
  '#fb7185', // 4 rose
  '#2dd4bf', // 5 teal
  '#a78bfa', // 6 violet
  '#a3e635', // 7 lime
  '#fb923c', // 8 orange
  '#22d3ee', // 9 cyan
  '#e879f9', // 10 fuchsia
  '#facc15', // 11 yellow
]

const ITEMS = Array.from({ length: 12 }, (_, i) => ({ id: i, color: ITEM_COLORS[i] }))

// Compute (column index, slot index within column) for each item under mod-N
function placement(itemId: number, n: number): { col: number; slot: number } {
  const col = itemId % n
  // Slot is determined by item's order among items mapped to this column
  let slot = 0
  for (let k = 0; k < itemId; k++) {
    if (k % n === col) slot++
  }
  return { col, slot }
}

const SLOT_GAP = 56          // vertical pixels between items
const SLOT_TOP_OFFSET = 50   // first slot's y offset within the column

function itemPos(itemId: number, n: number): { x: number; y: number; colIndex: number } {
  const { col, slot } = placement(itemId, n)
  const colCenters = n === 3 ? COLS_3 : COLS_4
  const x = colCenters[col] + COL_W / 2
  const y = COL_TOP + SLOT_TOP_OFFSET + slot * SLOT_GAP
  return { x, y, colIndex: col }
}

// Items moved? An item moves if its column changes between mod-3 and mod-4.
function moved(itemId: number): boolean {
  return placement(itemId, 3).col !== placement(itemId, 4).col
}

const movedCount = ITEMS.filter((it) => moved(it.id)).length  // 9

// ---------- Computed item state for current frame ----------
const itemStates = computed(() => {
  const n = reshuffled.value ? 4 : 3
  return ITEMS.map((it) => {
    const pos = itemPos(it.id, n)
    return { ...it, ...pos, hasMoved: reshuffled.value && moved(it.id) }
  })
})

// Column positions for the current frame
const columnPositions = computed(() => {
  if (reshuffled.value) return COLS_4
  return COLS_3
})

// 4th column x — slides in from off-canvas
const fourthColX = computed(() => (reshuffled.value ? COLS_4[3] : COL_OFFSCREEN_X))

// Column labels
const COL_LABELS_3 = ['a@', 'b@', 'c@']
const COL_LABELS_4 = ['a@', 'b@', 'c@', 'd@']
</script>

<template>
  <div class="mod-n-reshuffle">
    <svg :viewBox="`0 0 ${VIEW_W} ${VIEW_H}`" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">

      <!-- ===== Existing 3 columns (always present, may shift left when 4th joins) ===== -->
      <g v-for="(_, i) in 3" :key="`col-${i}`" :class="['column-shift']" :transform="`translate(${columnPositions[i]}, ${COL_TOP})`">
        <rect x="0" y="0" :width="COL_W" :height="COL_H" rx="8" class="col-body" />
        <rect x="0" y="0" :width="COL_W" height="5" rx="2.5" class="col-stripe" />
        <text
          :x="COL_W / 2" :y="COL_H + 28"
          text-anchor="middle"
          class="col-label"
        >{{ reshuffled ? COL_LABELS_4[i] : COL_LABELS_3[i] }}</text>
      </g>

      <!-- ===== 4th column (slides in) ===== -->
      <g class="column-shift" :transform="`translate(${fourthColX}, ${COL_TOP})`">
        <rect x="0" y="0" :width="COL_W" :height="COL_H" rx="8" class="col-body col-new" />
        <rect x="0" y="0" :width="COL_W" height="5" rx="2.5" class="col-stripe col-new-stripe" />
        <text
          :x="COL_W / 2" :y="COL_H + 28"
          text-anchor="middle"
          class="col-label col-new-label"
        >d@</text>
      </g>

      <!-- ===== Items ===== -->
      <g class="items">
        <g
          v-for="item in itemStates"
          :key="item.id"
          :class="['item', { moved: item.hasMoved }]"
          :transform="`translate(${item.x}, ${item.y})`"
        >
          <circle r="18" :fill="item.color" class="item-dot" />
          <text text-anchor="middle" y="5" class="item-label">{{ item.id }}</text>
        </g>
      </g>

      <!-- ===== Counter widget (top-right) ===== -->
      <g transform="translate(595, 16)" class="counter">
        <rect x="0" y="0" width="190" height="62" rx="8" :class="['counter-bg', { alert: reshuffled }]" />
        <text x="95" y="22" text-anchor="middle" class="counter-label">items</text>
        <text x="95" y="48" text-anchor="middle" :class="['counter-value', { alert: reshuffled }]">
          {{ reshuffled ? `reassigned: ${movedCount} / 12` : '12 · placed' }}
        </text>
      </g>

      <!-- ===== Caption (appears after reshuffle) ===== -->
      <g :class="['caption', { shown: reshuffled }]">
        <text :x="VIEW_W / 2" :y="VIEW_H - 8" text-anchor="middle" class="caption-text">
          deterministic <tspan class="caption-strike">≠</tspan> stable
        </text>
      </g>
    </svg>
  </div>
</template>

<style scoped>
.mod-n-reshuffle {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Columns */
.column-shift {
  transition: transform 700ms cubic-bezier(0.4, 0, 0.2, 1);
}
.col-body {
  fill: rgba(148, 163, 184, 0.08);
  stroke: rgba(148, 163, 184, 0.4);
  stroke-width: 1.5;
}
.col-stripe {
  fill: rgba(148, 163, 184, 0.55);
}
.col-new {
  stroke: rgba(52, 211, 153, 0.7);
}
.col-new-stripe {
  fill: rgba(52, 211, 153, 0.85);
}
.col-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 16px;
  fill: rgba(226, 232, 240, 0.85);
}
.col-new-label {
  fill: rgba(52, 211, 153, 0.95);
  font-weight: 700;
}

/* Items */
.item {
  transition: transform 800ms cubic-bezier(0.4, 0, 0.2, 1);
}
.item-dot {
  filter: drop-shadow(0 1px 3px rgba(0, 0, 0, 0.45));
  transition: stroke 400ms ease, stroke-width 400ms ease;
  stroke: rgba(0, 0, 0, 0);
  stroke-width: 0;
}
.item.moved .item-dot {
  stroke: rgba(251, 113, 133, 0.95);
  stroke-width: 3;
  animation: moved-pulse 800ms cubic-bezier(0.4, 0, 0.2, 1) 600ms 1 both;
}
@keyframes moved-pulse {
  0%   { filter: drop-shadow(0 0 0 rgba(251, 113, 133, 0)); }
  50%  { filter: drop-shadow(0 0 12px rgba(251, 113, 133, 0.7)); }
  100% { filter: drop-shadow(0 1px 3px rgba(0, 0, 0, 0.45)); }
}
.item-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  font-weight: 700;
  fill: rgba(15, 23, 42, 0.85);
  pointer-events: none;
}

/* Counter */
.counter-bg {
  fill: rgba(15, 23, 42, 0.75);
  stroke: rgba(148, 163, 184, 0.4);
  stroke-width: 1;
  transition: stroke 400ms ease, fill 400ms ease;
}
.counter-bg.alert {
  stroke: rgba(251, 113, 133, 0.85);
  animation: alert-flash 700ms cubic-bezier(0.4, 0, 0.2, 1) 1 both;
}
@keyframes alert-flash {
  0%   { fill: rgba(251, 113, 133, 0.5); }
  100% { fill: rgba(15, 23, 42, 0.75); }
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
  font-size: 16px;
  font-weight: 700;
  fill: rgb(251, 191, 36);
  transition: fill 500ms ease;
}
.counter-value.alert {
  fill: rgb(251, 113, 133);
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
  font-size: 22px;
  font-style: italic;
  font-weight: 600;
  fill: rgba(251, 113, 133, 0.95);
}
.caption-strike {
  fill: rgb(251, 113, 133);
  font-weight: 800;
}
</style>
