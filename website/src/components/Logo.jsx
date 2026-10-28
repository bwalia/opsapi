export default function Logo({ className }) {
    return (
        <svg className={className} viewBox="0 0 64 64" aria-hidden="true">
            <rect width="64" height="64" rx="14" fill="#0b2a2e" />
            <path d="M18 32a14 14 0 1 0 28 0a14 14 0 1 0-28 0" fill="none" stroke="#2fd3b5" strokeWidth="6" />
            <circle cx="46" cy="18" r="6" fill="#f5a524" />
        </svg>
    );
}
