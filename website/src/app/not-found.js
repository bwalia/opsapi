import Link from 'next/link';

export default function NotFound() {
    return (
        <section className="section">
            <div className="container-x">
                <p className="eyebrow">404</p>
                <h1>That page isn't here</h1>
                <p className="lead-x">It may have moved. Try the <Link href="/features/">features</Link>, the <Link href="/technotes/">technotes</Link> or the <Link href="/">home page</Link>.</p>
            </div>
        </section>
    );
}
