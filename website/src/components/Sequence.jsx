import { Markers } from '@/components/Figure';

// A sequence diagram from data, in the site's diagram style (dg-* classes, so it
// reads in light and dark).
//
//   lanes: [{ key, title, sub?, variant? }]
//   steps: [{ from, to, label, sub?, kind? }]
//     from === to  -> a note box on that lane (what that party does)
//     kind: 'reply' (dashed: redirects and responses), 'accent' (the result
//           that matters), 'deny' (a refusal, red)
export default function Sequence({ id, title, lanes, steps, width = 960 }) {
    const pad = 90;
    const gap = lanes.length > 1 ? (width - pad * 2) / (lanes.length - 1) : 0;
    const x = {};
    lanes.forEach((l, i) => { x[l.key] = pad + i * gap; });

    const top = 86;
    const rows = [];
    let y = top + 26;
    steps.forEach((s) => {
        const self = s.from === s.to;
        const h = self ? (s.sub ? 52 : 38) : (s.sub ? 58 : 46);
        rows.push({ ...s, y, self, h });
        y += h;
    });
    const height = y + 14;

    return (
        <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-labelledby={`${id}-t`}>
            <title id={`${id}-t`}>{title}</title>
            <Markers />
            {lanes.map((l) => (
                <g key={l.key}>
                    <rect x={x[l.key] - 78} y="12" width="156" height="56" rx="6"
                        className={`dg-box${l.variant ? ` dg-box--${l.variant}` : ''}`} />
                    <text x={x[l.key]} y="36" textAnchor="middle" className="dg-title">{l.title}</text>
                    {l.sub ? <text x={x[l.key]} y="54" textAnchor="middle" className="dg-mono">{l.sub}</text> : null}
                    <line x1={x[l.key]} y1="68" x2={x[l.key]} y2={height - 6} className="dg-life" />
                </g>
            ))}
            {rows.map((s, i) => {
                const n = i + 1;
                const step = (
                    <g>
                        <circle cx="22" cy={s.y} r="10" className="dg-step" />
                        <text x="22" y={s.y + 4} textAnchor="middle" className="dg-step-t">{n}</text>
                    </g>
                );
                if (s.self) {
                    // ~7.2px per body character, ~7px per mono character at these sizes.
                    const w = Math.max(s.label.length * 7.2, (s.sub || '').length * 7) + 32;
                    const cx = Math.min(Math.max(x[s.from], w / 2 + 4), width - w / 2 - 4);
                    const variant = s.kind === 'deny' ? 'red' : s.kind === 'accent' ? 'accent'
                        : (lanes.find((l) => l.key === s.from)?.variant || 'muted');
                    return (
                        <g key={n}>
                            {step}
                            <rect x={cx - w / 2} y={s.y - 15} width={w} height={s.sub ? 40 : 28} rx="4"
                                className={`dg-box dg-box--${variant}`} />
                            <text x={cx} y={s.y + (s.sub ? 1 : 3)} textAnchor="middle" className="dg-text">{s.label}</text>
                            {s.sub ? <text x={cx} y={s.y + 18} textAnchor="middle" className="dg-mono">{s.sub}</text> : null}
                        </g>
                    );
                }
                const x1 = x[s.from];
                const x2 = x[s.to];
                const dir = x2 > x1 ? 1 : -1;
                const cls = s.kind === 'reply' ? 'dg-line--dash' : s.kind === 'accent' ? 'dg-line--accent'
                    : s.kind === 'deny' ? 'dg-line--red' : 'dg-line';
                const head = s.kind === 'accent' ? 'url(#ah-acc)' : s.kind === 'deny' ? 'url(#ah-red)' : 'url(#ah)';
                const mid = (x1 + x2) / 2;
                return (
                    <g key={n}>
                        {step}
                        <line x1={x1} y1={s.y} x2={x2 - dir * 2} y2={s.y} className={cls} markerEnd={head} />
                        <text x={mid} y={s.y - 8} textAnchor="middle" className="dg-text">{s.label}</text>
                        {s.sub ? <text x={mid} y={s.y + 17} textAnchor="middle" className="dg-mono">{s.sub}</text> : null}
                    </g>
                );
            })}
        </svg>
    );
}
