import Link from 'next/link';

function formatDate(iso) {
    return new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
}

export default function ArticleLayout({ kind, kindHref, item, children }) {
    return (
        <article>
            <header className="article-head">
                <div className="container-x">
                    <p className="breadcrumb-x"><Link href={kindHref}>{kind}</Link></p>
                    <h1 className="display-x" style={{ maxWidth: '22ch' }}>{item.title}</h1>
                    <p className="lead-x">{item.summary}</p>
                    <div className="article-meta">
                        <span>{formatDate(item.date)}</span>
                        {item.readMinutes ? <span>{item.readMinutes} min read</span> : null}
                        {item.audience ? <span>For {item.audience}</span> : null}
                    </div>
                    <div style={{ marginTop: '0.75rem' }}>
                        {(item.tags || []).map((t) => <span key={t} className="tag">{t}</span>)}
                    </div>
                </div>
            </header>
            <div className="container-x article-body">
                <div className="prose">{children}</div>
            </div>
        </article>
    );
}

export function ListCard({ href, item, kind }) {
    return (
        <Link href={href} className="card-x">
            <span className="card-x__meta">{kind} · {formatDate(item.date)}</span>
            <h3>{item.title}</h3>
            <p>{item.summary}</p>
            <div>{(item.tags || []).slice(0, 4).map((t) => <span key={t} className="tag">{t}</span>)}</div>
            <span className="card-x__foot">Read →</span>
        </Link>
    );
}
