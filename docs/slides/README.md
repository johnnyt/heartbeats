# Heartbeats — Slides

[Slidev](https://sli.dev) deck for the talk *Spreading Long-Running Workloads Across an Elixir Cluster*.

Outline source: [`../talk-outline.md`](../talk-outline.md).

## Run locally

```sh
cd docs/slides
npm install
npm run dev
```

Opens `http://localhost:3030`. Press `o` for overview, `p` for presenter mode.

## Layout

- `slides.md` — main entry point. Sections delimited by `---`.
- `components/` — Vue components for custom diagrams (e.g. the ring).
- `pages/` — optional multi-file slides (imported from `slides.md`).
- `public/` — static assets.

## Building

```sh
npm run build          # static site → dist/
npm run export         # PDF export (requires Playwright)
```
