import Link from 'next/link';
import { SITE } from '@/content/site';
import Logo from './Logo';

export default function SiteFooter() {
    return (
        <footer className="site-footer">
            <div className="container-x">
                <div className="footer-grid">
                    <div>
                        <Link href="/" className="brand" aria-label="OpsAPI home">
                            <Logo className="brand__mark" />
                            <span className="brand__name" style={{ color: 'var(--band-ink)' }}>OpsAPI</span>
                        </Link>
                        <p style={{ marginTop: '1rem', fontSize: '0.92rem', maxWidth: '36ch' }}>
                            One self-hosted API for sign-in, workspaces and business modules. OpenResty, Lua and PostgreSQL.
                        </p>
                    </div>
                    <div>
                        <h4>Product</h4>
                        <ul>
                            <li><Link href="/features/">Features</Link></li>
                            <li><Link href="/architecture/">Architecture</Link></li>
                            <li><Link href="/demo/">Live demo</Link></li>
                        </ul>
                    </div>
                    <div>
                        <h4>Learn</h4>
                        <ul>
                            <li><Link href="/technotes/">Technotes</Link></li>
                            <li><Link href="/blog/">Blog</Link></li>
                            <li><a href={`${SITE.github}#readme`}>README</a></li>
                        </ul>
                    </div>
                    <div>
                        <h4>Code</h4>
                        <ul>
                            <li><a href={SITE.github}>GitHub</a></li>
                            <li><a href={SITE.dockerHub}>Docker Hub</a></li>
                            <li><a href={`${SITE.github}/tree/main/sdk/typescript`}>TypeScript SDK</a></li>
                        </ul>
                    </div>
                </div>
                <div className="footer-base">OpsAPI is open source on GitHub. Built and run by Workstation.</div>
            </div>
        </footer>
    );
}
