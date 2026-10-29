import { Poppins, Unbounded, JetBrains_Mono } from 'next/font/google';
import 'bootstrap/dist/css/bootstrap.min.css';
import './globals.scss';
import SiteHeader from '@/components/SiteHeader';
import SiteFooter from '@/components/SiteFooter';
import { SITE } from '@/content/site';

const poppins = Poppins({ subsets: ['latin'], display: 'swap', variable: '--ws-font-body', weight: ['400', '500', '600', '700'] });
const unbounded = Unbounded({ subsets: ['latin'], display: 'swap', variable: '--ws-font-display', weight: ['500', '700'] });
const jetbrainsMono = JetBrains_Mono({ subsets: ['latin'], display: 'swap', variable: '--ws-font-mono', weight: ['400', '500'] });

export const metadata = {
    metadataBase: new URL(SITE.url),
    title: { default: 'OpsAPI: one API for auth, tenants and business modules', template: '%s · OpsAPI' },
    description: SITE.description,
    icons: { icon: '/favicon.svg' },
    openGraph: { title: 'OpsAPI', description: SITE.description, url: SITE.url, siteName: 'OpsAPI', type: 'website' },
};

// Light unless the reader chose dark with the toggle; applied before paint so there's no flash.
const themeScript = `try{var t=localStorage.getItem('opsapi-theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t)}catch(e){}`;

export default function RootLayout({ children }) {
    return (
        <html lang="en-GB" className={`${poppins.variable} ${unbounded.variable} ${jetbrainsMono.variable}`} suppressHydrationWarning>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
                <script dangerouslySetInnerHTML={{ __html: themeScript }} />
            </head>
            <body>
                <SiteHeader />
                <main id="main">{children}</main>
                <SiteFooter />
            </body>
        </html>
    );
}
