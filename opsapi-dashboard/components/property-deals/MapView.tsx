'use client';

/**
 * Google Maps view for the Deal finder: click to drop the search pin, a radius
 * circle, one coloured marker per feature (by layer; deals by health).
 * Loaded client-side only. Requires NEXT_PUBLIC_GOOGLE_MAPS_API_KEY (Maps
 * JavaScript API) at build time.
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { GoogleMap, useJsApiLoader, Circle, Marker, InfoWindow } from '@react-google-maps/api';
import type { MapFeature } from '@/services/property-deals.service';
import { LAYER_COLOURS } from './mapColours';

const HEALTH: Record<string, string> = { red: '#dc2626', amber: '#f59e0b', green: '#16a34a' };
const MAP_ID = 'property-deals-deal-finder';
const LIBRARIES: ('places')[] = ['places'];

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

type Props = {
  center: { lat: number; lng: number };
  radiusMiles: number;
  features: MapFeature[];
  onPick: (lat: number, lng: number) => void;
  onSelect: (f: MapFeature) => void;
};

function GoogleMapView({ apiKey, center, radiusMiles, features, onPick, onSelect }: Props & { apiKey: string }) {
  const { isLoaded, loadError } = useJsApiLoader({
    id: MAP_ID,
    googleMapsApiKey: apiKey,
    libraries: LIBRARIES,
  });
  const mapRef = useRef<google.maps.Map | null>(null);
  const [hover, setHover] = useState<MapFeature | null>(null);

  const onLoad = useCallback((map: google.maps.Map) => { mapRef.current = map; }, []);
  const onUnmount = useCallback(() => { mapRef.current = null; }, []);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !isLoaded) return;
    const bounds = map.getBounds();
    if (!bounds || !bounds.contains(center)) map.panTo(center);
  }, [center.lat, center.lng, isLoaded, center]);

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
      zoom={10}
      options={mapOptions}
      onLoad={onLoad}
      onUnmount={onUnmount}
      onClick={(e) => {
        if (e.latLng) onPick(e.latLng.lat(), e.latLng.lng());
      }}
    >
      <Circle
        center={center}
        radius={radiusMiles * 1609.344}
        options={{ strokeColor: '#6366f1', strokeOpacity: 0.8, strokeWeight: 1, fillColor: '#6366f1', fillOpacity: 0.05, clickable: false }}
      />
      <Marker position={center} title="Search pin" zIndex={1000} />
      {features.map((f) => {
        const colour = pinColour(f);
        const size = f.layer === 'deals' || f.layer === 'properties' ? 18 : 14;
        return (
          <Marker
            key={`${f.layer}:${f.uuid}`}
            position={{ lat: f.lat, lng: f.lng }}
            icon={markerIcon(colour, size)}
            title={f.title}
            onClick={() => onSelect(f)}
            onMouseOver={() => setHover(f)}
            onMouseOut={() => setHover((h) => (h?.uuid === f.uuid ? null : h))}
          />
        );
      })}
      {hover && (
        <InfoWindow position={{ lat: hover.lat, lng: hover.lng }} onCloseClick={() => setHover(null)}>
          <div className="text-sm">
            <strong>{hover.title}</strong>
            {hover.price != null ? ` · £${Number(hover.price).toLocaleString('en-GB')}` : ''}
          </div>
        </InfoWindow>
      )}
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
