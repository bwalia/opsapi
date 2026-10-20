'use client';

/**
 * Google Maps view for the Deal finder: click to drop the search pin, a radius
 * circle, one coloured marker per feature (by layer; deals by health).
 * Loaded client-side only. Requires NEXT_PUBLIC_GOOGLE_MAPS_API_KEY (Maps
 * JavaScript API) at build time.
 */
import React, { useCallback, useEffect, useMemo, useRef } from 'react';
import { GoogleMap, useJsApiLoader, Circle, Marker } from '@react-google-maps/api';
import type { MapFeature } from '@/services/property-deals.service';
import { LAYER_COLOURS } from './mapColours';

const HEALTH: Record<string, string> = { red: '#dc2626', amber: '#f59e0b', green: '#16a34a' };
const MAP_ID = 'property-deals-deal-finder';
const LIBRARIES: ('places')[] = ['places'];
// Sparse, meaningful layers get a proper teardrop pin; the dense market layers
// (sold prices can be ~1,000 points) stay as small dots so the map stays readable.
const PIN_LAYERS = new Set(['properties', 'deals', 'leads', 'holdings', 'suppliers', 'company']);

function pinColour(f: MapFeature): string {
  return f.layer === 'deals' && f.deal_health ? HEALTH[f.deal_health] : LAYER_COLOURS[f.layer] || '#334155';
}

/** SVG circle marker as a data-URL so each layer keeps its colour without custom overlays. */
function markerIcon(colour: string, size: number): google.maps.Icon {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
    <circle cx="${size / 2}" cy="${size / 2}" r="${size / 2 - 1}" fill="${colour}" stroke="#fff" stroke-width="2"/>
  </svg>`;
  return {
    url: `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`,
    scaledSize: new google.maps.Size(size, size),
    anchor: new google.maps.Point(size / 2, size / 2),
  };
}

/** A proper teardrop map pin (anchored at its tip), for sparse clickable layers like companies. */
function pinIcon(colour: string, selected: boolean): google.maps.Icon {
  const w = selected ? 34 : 28;
  const h = Math.round(w * 1.4);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 26 36">
    <path d="M13 0.5C6 0.5 0.5 6 0.5 13c0 9 12.5 22.5 12.5 22.5S25.5 22 25.5 13C25.5 6 20 0.5 13 0.5z"
      fill="${colour}" stroke="#fff" stroke-width="1.6"/>
    <circle cx="13" cy="13" r="4.6" fill="#fff"/>
  </svg>`;
  return {
    url: `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`,
    scaledSize: new google.maps.Size(w, h),
    anchor: new google.maps.Point(w / 2, h),
  };
}

type Props = {
  center: { lat: number; lng: number };
  radiusMiles: number;
  features: MapFeature[];
  onPick: (lat: number, lng: number) => void;
  onSelect: (f: MapFeature) => void;
  /** Keyword mode (Companies House): fit the view to the result pins instead of a fixed radius. */
  fitToFeatures?: boolean;
  /** Show the dropped search pin + radius circle, and let a map click move the pin (default true). */
  showSearchPin?: boolean;
  /** The currently-selected feature's uuid, to emphasise its pin. */
  selectedUuid?: string;
  /** Initial zoom (default 10). Higher when arriving focused on one deal via "Show on map". */
  zoom?: number;
};

function GoogleMapView({
  apiKey, center, radiusMiles, features, onPick, onSelect,
  fitToFeatures = false, showSearchPin = true, selectedUuid, zoom = 10,
}: Props & { apiKey: string }) {
  const { isLoaded, loadError } = useJsApiLoader({
    id: MAP_ID,
    googleMapsApiKey: apiKey,
    libraries: LIBRARIES,
  });
  const mapRef = useRef<google.maps.Map | null>(null);

  const onLoad = useCallback((map: google.maps.Map) => { mapRef.current = map; }, []);
  const onUnmount = useCallback(() => { mapRef.current = null; }, []);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !isLoaded || fitToFeatures) return;
    const bounds = map.getBounds();
    if (!bounds || !bounds.contains(center)) map.panTo(center);
  }, [center.lat, center.lng, isLoaded, center, fitToFeatures]);

  // Keyword mode: frame all result pins (they can be anywhere in the UK).
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !isLoaded || !fitToFeatures || features.length === 0) return;
    if (features.length === 1) {
      map.setCenter({ lat: features[0].lat, lng: features[0].lng });
      map.setZoom(13);
      return;
    }
    const bounds = new google.maps.LatLngBounds();
    for (const f of features) bounds.extend({ lat: f.lat, lng: f.lng });
    map.fitBounds(bounds, 56);
  }, [isLoaded, fitToFeatures, features]);

  const mapOptions = useMemo<google.maps.MapOptions>(() => ({
    disableDefaultUI: false,
    streetViewControl: false,
    mapTypeControl: false,
    fullscreenControl: true,
    clickableIcons: false,
  }), []);

  if (loadError) {
    return (
      <div className="flex h-[60vh] min-h-[420px] w-full items-center justify-center rounded-xl border border-red-200 bg-red-50 p-6 text-center text-sm text-red-800">
        Could not load Google Maps. Check the API key and that the Maps JavaScript API is enabled.
      </div>
    );
  }
  if (!isLoaded) {
    return <div className="flex h-[60vh] min-h-[420px] w-full items-center justify-center rounded-xl bg-secondary-50 text-sm text-secondary-500">Loading the map…</div>;
  }

  return (
    <GoogleMap
      mapContainerClassName="h-[60vh] min-h-[420px] w-full rounded-xl"
      center={center}
      zoom={zoom}
      options={mapOptions}
      onLoad={onLoad}
      onUnmount={onUnmount}
      onClick={(e) => {
        if (showSearchPin && e.latLng) onPick(e.latLng.lat(), e.latLng.lng());
      }}
    >
      {showSearchPin && (
        <>
          <Circle
            center={center}
            radius={radiusMiles * 1609.344}
            options={{ strokeColor: '#6366f1', strokeOpacity: 0.8, strokeWeight: 1, fillColor: '#6366f1', fillOpacity: 0.05, clickable: false }}
          />
          <Marker position={center} title="Search pin" zIndex={1000} />
        </>
      )}
      {features.map((f) => {
        const colour = pinColour(f);
        const isPin = PIN_LAYERS.has(f.layer);
        const isSelected = f.uuid === selectedUuid;
        const size = f.layer === 'deals' || f.layer === 'properties' ? 18 : 14;
        return (
          <Marker
            key={`${f.layer}:${f.uuid}`}
            position={{ lat: f.lat, lng: f.lng }}
            icon={isPin ? pinIcon(colour, isSelected) : markerIcon(colour, size)}
            title={f.title}
            zIndex={isPin ? (isSelected ? 600 : 500) : undefined}
            onClick={() => onSelect(f)}
          />
        );
      })}
    </GoogleMap>
  );
}

export default function MapView(props: Props) {
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '';
  if (!apiKey) {
    return (
      <div className="flex h-[60vh] min-h-[420px] w-full items-center justify-center rounded-xl border border-amber-200 bg-amber-50 p-6 text-center text-sm text-amber-900">
        Google Maps is not configured. Set <code className="mx-1 rounded bg-amber-100 px-1">NEXT_PUBLIC_GOOGLE_MAPS_API_KEY</code>
        (Maps JavaScript API) and rebuild the dashboard. For local: add it to <code className="mx-1 rounded bg-amber-100 px-1">opsapi-dashboard/.env.local</code>.
      </div>
    );
  }
  return <GoogleMapView apiKey={apiKey} {...props} />;
}
