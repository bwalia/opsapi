'use client';

import { useState } from 'react';

export default function CopyButton({ value, label }) {
    const [state, setState] = useState('Copy');
    async function copy() {
        try {
            await navigator.clipboard.writeText(value);
            setState('Copied');
        } catch (e) {
            setState('Select and copy');
        }
        setTimeout(() => setState('Copy'), 1800);
    }
    return (
        <button type="button" className="copy-btn" onClick={copy} aria-label={`Copy ${label}`}>{state}</button>
    );
}
