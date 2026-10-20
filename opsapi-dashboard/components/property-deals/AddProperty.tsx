'use client';

/**
 * "Add property" for a deal that has none yet. One field: Google's new
 * PlaceAutocompleteElement (Places API New — NOT the legacy Autocomplete widget,
 * which needs the deprecated "Places API" turned on). Picking a suggestion fills
 * the street, town, postcode and coordinates; saving creates the property
 * (POST /properties also geocodes server-side as a fallback) and links it to the
 * deal, so the map pin and AI research start.
 *
 * Needs NEXT_PUBLIC_GOOGLE_MAPS_API_KEY with "Maps JavaScript API" and
 * "Places API (New)" enabled on the Google Cloud project.
 */
import React, { useEffect, useRef, useState } from 'react';
import { useJsApiLoader } from '@react-google-maps/api';
import { Plus, MapPin } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Modal } from '@/components/ui';
import { pdService, pdErrorText } from '@/services/property-deals.service';

const LIBRARIES: 'places'[] = ['places'];
const KEY = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '';
// @react-google-maps/api has ONE global loader: every useJsApiLoader call must pass
// identical options. Keep this id (and libraries) in step with MapView's loader
// (MAP_ID = 'property-deals-deal-finder'), or it throws "Loader must not be called
// again with different options" when both a map and this modal have mounted.
const LOADER_ID = 'property-deals-deal-finder';
const NEEDS_NEW_API = 'Turn on the "Places API (New)" for this Google Maps key, then reload.';

interface PropertyDraft { address_line1: string; town?: string; postcode?: string; lat?: number; lng?: number }
interface AddrComponent { longText?: string; shortText?: string; types?: string[] }

/** Build the create payload from a (new) Places result's fields. */
function draftFromPlace(
  components: AddrComponent[],
  location: unknown,
  formatted?: string,
  name?: string,
): PropertyDraft | null {
  const part = (type: string) => {
    const c = components.find((x) => (x.types || []).includes(type));
    return c ? c.longText || c.shortText || undefined : undefined;
  };
  const line1 =
    [part('street_number'), part('route')].filter(Boolean).join(' ') ||
    name ||
    (formatted ? formatted.split(',')[0] : undefined) ||
    '';
  if (!line1) return null;
  const loc = location as { lat?: number | (() => number); lng?: number | (() => number) } | null;
  const num = (v: number | (() => number) | undefined) =>
    typeof v === 'function' ? v() : typeof v === 'number' ? v : undefined;
  return {
    address_line1: line1,
    town: part('postal_town') || part('locality') || part('administrative_area_level_2'),
    postcode: part('postal_code'),
    lat: loc ? num(loc.lat) : undefined,
    lng: loc ? num(loc.lng) : undefined,
  };
}

export default function AddProperty({ dealId, onAdded }: { dealId: string; onAdded: () => void }) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<PropertyDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const hostRef = useRef<HTMLDivElement | null>(null);
  const { isLoaded } = useJsApiLoader({ id: LOADER_ID, googleMapsApiKey: KEY, libraries: LIBRARIES });

  const reset = () => { setDraft(null); setErr(null); };

  // Mount the new PlaceAutocompleteElement into the modal while it is open.
  useEffect(() => {
    if (!open || !isLoaded || !hostRef.current) return;
    const host = hostRef.current;
    /* eslint-disable @typescript-eslint/no-explicit-any */
    const places = (window as any).google?.maps?.places;
    if (!places?.PlaceAutocompleteElement) { setErr(NEEDS_NEW_API); return; }
    let el: any;
    try {
      el = new places.PlaceAutocompleteElement({ includedRegionCodes: ['gb'] });
    } catch {
      setErr(NEEDS_NEW_API);
      return;
    }
    el.style.width = '100%';
    // The element is a web component; its shadow DOM otherwise follows the OS dark mode
    // (black input) regardless of the app's light theme. Pin it to light so it matches the modal.
    el.style.colorScheme = 'light';
    host.appendChild(el);
    const onSelect = async (ev: any) => {
      try {
        // Current API: gmp-select → ev.placePrediction.toPlace(); transitional: gmp-placeselect → ev.place.
        const place = ev.place || (ev.placePrediction && ev.placePrediction.toPlace());
        if (!place) return;
        await place.fetchFields({ fields: ['addressComponents', 'location', 'formattedAddress', 'displayName'] });
        const d = draftFromPlace(
          place.addressComponents || [],
          place.location,
          place.formattedAddress,
          typeof place.displayName === 'string' ? place.displayName : undefined,
        );
        if (d) { setDraft(d); setErr(null); } else { setErr('Could not read that address. Try another.'); }
      } catch {
        setErr('Could not read that address. Try another.');
      }
    };
    el.addEventListener('gmp-select', onSelect);
    el.addEventListener('gmp-placeselect', onSelect);
    /* eslint-enable @typescript-eslint/no-explicit-any */
    return () => {
      el.removeEventListener('gmp-select', onSelect);
      el.removeEventListener('gmp-placeselect', onSelect);
      if (host.contains(el)) host.removeChild(el);
    };
  }, [open, isLoaded]);

  const save = async () => {
    if (!draft) return;
    setSaving(true);
    try {
      const prop = (await pdService.createProperty({
        address_line1: draft.address_line1,
        town: draft.town,
        postcode: draft.postcode,
        lat: draft.lat,
        lng: draft.lng,
      })).data;
      await pdService.updateDeal(dealId, { property_uuid: prop.uuid });
      toast.success('Property added');
      setOpen(false);
      reset();
      onAdded();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setOpen(true)}>
        Add property
      </Button>
      <Modal
        isOpen={open}
        onClose={() => { setOpen(false); reset(); }}
        title="Add the property"
        description="Start typing the address and pick it from the list — we’ll pin it on the map and start the research."
      >
        <div className="space-y-4">
          {!KEY ? (
            <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              Address search isn’t configured. Set <code className="rounded bg-amber-100 px-1">NEXT_PUBLIC_GOOGLE_MAPS_API_KEY</code>.
            </p>
          ) : !isLoaded ? (
            <p className="text-sm text-secondary-500">Loading address search…</p>
          ) : (
            <label className="block">
              <span className="mb-1 block text-sm font-medium text-secondary-700">Address</span>
              {/* Google's new PlaceAutocompleteElement is mounted here. */}
              <div ref={hostRef} />
            </label>
          )}

          {err && <p className="text-sm text-error-600">{err}</p>}

          {draft && (
            <div className="flex items-start gap-2 rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm">
              <MapPin className="mt-0.5 h-4 w-4 shrink-0 text-primary-500" aria-hidden />
              <div className="min-w-0">
                <div className="font-medium text-secondary-900">{draft.address_line1}</div>
                <div className="text-secondary-500">
                  {[draft.town, draft.postcode].filter(Boolean).join(' · ') || 'We’ll place it from the address when you save.'}
                </div>
              </div>
            </div>
          )}

          <div className="flex justify-end gap-2">
            <Button variant="outline" size="sm" onClick={() => { setOpen(false); reset(); }}>Cancel</Button>
            <Button size="sm" isLoading={saving} disabled={!draft} onClick={save}>Add property</Button>
          </div>
        </div>
      </Modal>
    </>
  );
}
