<script setup lang="ts">
defineProps<{
  clicks?: number
}>()

const nodes = [
  { id: 'a', x: 400, y: 50,  label: 'a@' },
  { id: 'b', x: 120, y: 320, label: 'b@' },
  { id: 'c', x: 680, y: 320, label: 'c@' },
]
</script>

<template>
  <div class="register-race">
    <svg viewBox="0 0 800 460" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">
      <!-- ===== Shared center lock (visible in states 0 + 1) ===== -->
      <g :class="['center-lock', { gone: (clicks ?? 0) >= 2 }]">
        <rect x="370" y="170" width="60" height="60" rx="8" class="lock-body" />
        <text x="400" y="208" text-anchor="middle" class="lock-icon">🔒</text>
        <text x="400" y="252" text-anchor="middle" class="lock-label">
          {{ (clicks ?? 0) >= 1 ? 'owned: a@' : ':global registry' }}
        </text>
      </g>

      <!-- ===== Race envelopes (visible only at click 0) ===== -->
      <g :class="['race-envelopes', { gone: (clicks ?? 0) >= 1 }]">
        <g class="envelope env-a">
          <rect x="365" y="105" width="70" height="22" rx="4" class="env-body" />
          <text x="400" y="120" text-anchor="middle" class="env-text">register/2</text>
        </g>
        <g class="envelope env-b">
          <rect x="200" y="255" width="70" height="22" rx="4" class="env-body" />
          <text x="235" y="270" text-anchor="middle" class="env-text">register/2</text>
        </g>
        <g class="envelope env-c">
          <rect x="530" y="255" width="70" height="22" rx="4" class="env-body" />
          <text x="565" y="270" text-anchor="middle" class="env-text">register/2</text>
        </g>
      </g>

      <!-- ===== Race result badges (visible at click >= 1, gone at netsplit) ===== -->
      <g :class="['race-results', { shown: (clicks ?? 0) >= 1 && (clicks ?? 0) < 2 }]">
        <!-- A: winner (to the right of A) -->
        <g transform="translate(465, 37)">
          <rect x="0" y="0" width="90" height="26" rx="13" class="badge-win" />
          <text x="45" y="17" text-anchor="middle" class="badge-text">✓ owns it</text>
        </g>
        <!-- B: error (below b@) -->
        <g transform="translate(45, 370)">
          <rect x="0" y="0" width="250" height="28" rx="14" class="badge-err" />
          <text x="125" y="18" text-anchor="middle" class="badge-text">{:error, :already_registered}</text>
        </g>
        <!-- C: error (below c@) -->
        <g transform="translate(505, 370)">
          <rect x="0" y="0" width="250" height="28" rx="14" class="badge-err" />
          <text x="125" y="18" text-anchor="middle" class="badge-text">{:error, :already_registered}</text>
        </g>
      </g>

      <!-- ===== Netsplit state (click 2) ===== -->
      <g :class="['netsplit', { shown: (clicks ?? 0) === 2 }]">
        <path
          d="M 30,180 L 110,165 L 90,195 L 200,175 L 180,205 L 310,180 L 290,210 L 420,185 L 400,215 L 530,190 L 510,220 L 620,195 L 600,225 L 710,200 L 690,230 L 770,210"
          class="lightning"
          fill="none"
        />
        <text x="400" y="130" text-anchor="middle" class="partition-label">partition 1</text>
        <text x="400" y="258" text-anchor="middle" class="partition-label">partition 2</text>

        <!-- A's local lock + worker -->
        <g transform="translate(465, 25)">
          <rect x="0" y="0" width="44" height="44" rx="6" class="lock-body" />
          <text x="22" y="29" text-anchor="middle" class="lock-icon-sm">🔒</text>
        </g>
        <g transform="translate(525, 35)">
          <rect x="0" y="0" width="130" height="22" rx="4" class="pid-body" />
          <text x="65" y="16" text-anchor="middle" class="pid-text">pid #&lt;A.0.1&gt;</text>
        </g>

        <!-- {B,C}'s shared lock + worker -->
        <g transform="translate(378, 268)">
          <rect x="0" y="0" width="44" height="44" rx="6" class="lock-body" />
          <text x="22" y="29" text-anchor="middle" class="lock-icon-sm">🔒</text>
        </g>
        <g transform="translate(180, 278)">
          <rect x="0" y="0" width="130" height="22" rx="4" class="pid-body" />
          <text x="65" y="16" text-anchor="middle" class="pid-text">pid #&lt;B.0.1&gt;</text>
        </g>

        <text x="400" y="445" text-anchor="middle" class="caption-neutral">
          both partitions register the same name
        </text>
      </g>

      <!-- ===== Heal + murder state (click 3) ===== -->
      <g :class="['heal', { shown: (clicks ?? 0) >= 3 }]">
        <g transform="translate(370, 170)">
          <rect x="0" y="0" width="60" height="60" rx="8" class="lock-body" />
          <text x="30" y="38" text-anchor="middle" class="lock-icon">🔒</text>
        </g>

        <g transform="translate(525, 35)">
          <rect x="0" y="0" width="130" height="22" rx="4" class="pid-body" />
          <text x="65" y="16" text-anchor="middle" class="pid-text">pid #&lt;A.0.1&gt;</text>
        </g>

        <g class="dying-pid">
          <rect x="0" y="0" width="130" height="22" rx="4" class="pid-body-dying" />
          <text x="65" y="16" text-anchor="middle" class="pid-text-dying">pid #&lt;B.0.1&gt;</text>
          <line x1="0" y1="0" x2="130" y2="22" class="death-stroke" />
          <line x1="130" y1="0" x2="0" y2="22" class="death-stroke" />
        </g>

        <text x="400" y="445" text-anchor="middle" class="caption-murder">
          name uniqueness, by murder.
        </text>
      </g>

      <!-- ===== Nodes (always visible) ===== -->
      <g v-for="n in nodes" :key="n.id" :transform="`translate(${n.x - 50}, ${n.y - 30})`">
        <rect x="0" y="0" width="100" height="70" rx="8" class="node-body" />
        <rect x="0" y="0" width="100" height="5" rx="2.5" class="node-stripe" />
        <text x="50" y="45" text-anchor="middle" class="node-label">{{ n.label }}</text>
      </g>
    </svg>
  </div>
</template>

<style scoped>
.register-race {
  font-family: 'Inter', system-ui, sans-serif;
}

/* Nodes */
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
  font-size: 18px;
  fill: rgba(226, 232, 240, 0.85);
}

/* Lock */
.lock-body {
  fill: rgba(251, 191, 36, 0.08);
  stroke: rgba(251, 191, 36, 0.7);
  stroke-width: 1.5;
}
.lock-icon {
  font-size: 28px;
}
.lock-icon-sm {
  font-size: 20px;
}
.lock-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgba(226, 232, 240, 0.7);
}

/* Envelopes */
.env-body {
  fill: rgba(56, 189, 248, 0.15);
  stroke: rgba(56, 189, 248, 0.7);
  stroke-width: 1.2;
}
.env-text {
  font-family: 'JetBrains Mono', monospace;
  font-size: 11px;
  fill: rgba(186, 230, 253, 0.95);
}

/* Race result badges */
.badge-win {
  fill: rgba(52, 211, 153, 0.2);
  stroke: rgba(52, 211, 153, 0.85);
  stroke-width: 1.2;
}
.badge-err {
  fill: rgba(244, 63, 94, 0.18);
  stroke: rgba(244, 63, 94, 0.75);
  stroke-width: 1.2;
}
.badge-text {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgba(226, 232, 240, 0.95);
}

/* Lightning bolt */
.lightning {
  stroke: rgba(251, 191, 36, 0.9);
  stroke-width: 3;
  stroke-linecap: round;
  stroke-linejoin: round;
  filter: drop-shadow(0 0 6px rgba(251, 191, 36, 0.6));
  animation: lightning-flicker 1.8s ease-in-out infinite;
}
@keyframes lightning-flicker {
  0%, 100% { opacity: 0.9; }
  50%      { opacity: 0.55; }
}
.partition-label {
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
  fill: rgba(251, 191, 36, 0.75);
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

/* Pids */
.pid-body {
  fill: rgba(167, 139, 250, 0.18);
  stroke: rgba(167, 139, 250, 0.7);
  stroke-width: 1.2;
}
.pid-text {
  font-family: 'JetBrains Mono', monospace;
  font-size: 12px;
  fill: rgba(221, 214, 254, 0.95);
}
.pid-body-dying {
  fill: rgba(244, 63, 94, 0.25);
  stroke: rgba(244, 63, 94, 0.85);
  stroke-width: 1.5;
}
.pid-text-dying {
  font-family: 'JetBrains Mono', monospace;
  font-size: 12px;
  fill: rgba(254, 205, 211, 0.95);
}
.death-stroke {
  stroke: rgba(244, 63, 94, 0.9);
  stroke-width: 2;
}
.dying-pid {
  animation: death-shake 0.7s cubic-bezier(0.4, 0, 0.2, 1) 0.2s 1 forwards;
  transform: translate(180px, 278px);
}
@keyframes death-shake {
  0%   { transform: translate(180px, 278px) scale(1);     opacity: 1; }
  25%  { transform: translate(436px, 278px) scale(1.05);  opacity: 0.9; }
  50%  { transform: translate(444px, 278px) scale(1.05);  opacity: 0.9; }
  75%  { transform: translate(180px, 278px) scale(1);     opacity: 0.7; }
  100% { transform: translate(180px, 278px) scale(0.95);  opacity: 0.5; }
}

/* Captions */
.caption-neutral {
  font-size: 18px;
  fill: rgba(226, 232, 240, 0.75);
  font-style: italic;
}
.caption-murder {
  font-size: 22px;
  fill: rgb(251, 191, 36);
  font-weight: 700;
  letter-spacing: 0.02em;
}

/* State transitions */
.center-lock,
.race-envelopes,
.race-results,
.netsplit,
.heal {
  transition: opacity 600ms cubic-bezier(0.4, 0, 0.2, 1);
}
.center-lock        { opacity: 1; }
.center-lock.gone   { opacity: 0; pointer-events: none; }
.race-envelopes        { opacity: 1; }
.race-envelopes.gone   { opacity: 0; pointer-events: none; }
.race-results          { opacity: 0; pointer-events: none; }
.race-results.shown    { opacity: 1; }
.netsplit              { opacity: 0; pointer-events: none; }
.netsplit.shown        { opacity: 1; }
.heal                  { opacity: 0; pointer-events: none; }
.heal.shown            { opacity: 1; }
</style>
