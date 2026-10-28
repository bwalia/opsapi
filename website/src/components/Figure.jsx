// A themed diagram frame. Children are the <svg> body; every colour comes
// from the dg-* classes in globals.scss so diagrams read in light and dark.
export default function Figure({ caption, minWidth = 720, children, id }) {
    return (
        <figure className="figure-x" id={id}>
            <div className="figure-x__frame" style={{ '--fig-min': `${minWidth}px` }}>{children}</div>
            {caption ? <figcaption>{caption}</figcaption> : null}
        </figure>
    );
}

// Arrowhead markers to drop inside an <svg>; reference with
// markerEnd="url(#ah)" (neutral), "url(#ah-acc)" (accent) or "url(#ah-red)".
export function Markers() {
    return (
        <defs>
            <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
                <path d="M0,0 L10,5 L0,10 z" className="dg-head" />
            </marker>
            <marker id="ah-acc" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
                <path d="M0,0 L10,5 L0,10 z" className="dg-head--accent" />
            </marker>
            <marker id="ah-red" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
                <path d="M0,0 L10,5 L0,10 z" className="dg-head--red" />
            </marker>
        </defs>
    );
}

// Box with a title and optional sub-lines, centred.
export function Box({ x, y, w, h, title, lines = [], variant = '', rx = 6 }) {
    const cx = x + w / 2;
    const total = 1 + lines.length;
    const startY = y + h / 2 - ((total - 1) * 17) / 2 + 5;
    return (
        <g>
            <rect x={x} y={y} width={w} height={h} rx={rx} className={`dg-box${variant ? ` dg-box--${variant}` : ''}`} />
            <text x={cx} y={startY} textAnchor="middle" className="dg-title">{title}</text>
            {lines.map((l, i) => (
                <text key={i} x={cx} y={startY + 17 * (i + 1)} textAnchor="middle" className="dg-mono">{l}</text>
            ))}
        </g>
    );
}

export function Table({ head, rows }) {
    return (
        <div className="table-wrap">
            <table className="table-x">
                <thead><tr>{head.map((h) => <th key={h}>{h}</th>)}</tr></thead>
                <tbody>
                    {rows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j}>{c}</td>)}</tr>)}
                </tbody>
            </table>
        </div>
    );
}
