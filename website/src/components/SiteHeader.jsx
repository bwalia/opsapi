'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState } from 'react';
import { SITE } from '@/content/site';
import Logo from './Logo';

export default function SiteHeader() {
    const pathname = usePathname() || '/';
    const [open, setOpen] = useState(false);
    const [theme, setTheme] = useState(null);

    useEffect(() => setOpen(false), [pathname]);
    useEffect(() => {
        setTheme(document.documentElement.getAttribute('data-theme'));
    }, []);

    function toggleTheme() {
        const current = theme || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
        const next = current === 'dark' ? 'light' : 'dark';
        document.documentElement.setAttribute('data-theme', next);
        try { localStorage.setItem('opsapi-theme', next); } catch (e) { /* storage blocked: still switches for this visit */ }
        setTheme(next);
    }

    return (
        <header className="site-header">
            <div className="container-x site-header__inner">
                <Link href="/" className="brand" aria-label="OpsAPI home">
                    <Logo className="brand__mark" />
                    <span className="brand__name">OpsAPI</span>
                </Link>
                <ul id="site-nav" className={`nav-links${open ? ' is-open' : ''}`}>
                    {SITE.nav.map((item) => (
                        <li key={item.href}>
                            <Link href={item.href} aria-current={pathname.startsWith(item.href) ? 'page' : undefined}>
                                {item.label}
                            </Link>
                        </li>
                    ))}
                </ul>
                <div className="nav-actions">
                    <a className="icon-btn" href={SITE.github} target="_blank" rel="noopener" aria-label="OpsAPI on GitHub">
                        <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
                    </a>
                    <button type="button" className="icon-btn" onClick={toggleTheme} aria-label="Switch light or dark theme">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
                    </button>
                    <button type="button" className="icon-btn menu-btn" onClick={() => setOpen(!open)}
                        aria-expanded={open} aria-controls="site-nav" aria-label="Menu">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
                    </button>
                </div>
            </div>
        </header>
    );
}
