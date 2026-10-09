'use client';

/**
 * Leaflet + OpenStreetMap view for the Deal finder: click to drop the pin, the radius circle,
 * one coloured dot per feature (by layer; deals by health). Loaded client-side only.
 */
import React from 'react';
import { MapContainer, TileLayer, Circle, CircleMarker, Tooltip, useMapEvents } from 'react-leaflet';
import 'leaflet/dist/leaflet.css';
import type { MapFeature } from '@/services/property-deals.service';
import { LAYER_COLOURS } from './mapColours';

const HEALTH: Record<string, string> = { red: '#dc2626', amber: '#f59e0b', green: '#16a34a' };

function Clicks({ onPick }: { onPick: (lat: number, lng: number) => void }) {
  useMapEvents({ click: (e) => onPick(e.latlng.lat, e.latlng.lng) });
  return null;
}

export default function MapView({ center, radiusMiles, features, onPick, onSelect }: {
  center: { lat: number; lng: number };
  radiusMiles: number;
  features: MapFeature[];
  onPick: (lat: number, lng: number) => void;
  onSelect: (f: MapFeature) => void;
}) {
  return (
    <MapContainer center={[center.lat, center.lng]} zoom={10} className="h-[60vh] min-h-[420px] w-full rounded-xl" scrollWheelZoom>
      <TileLayer attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors' url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png" />
      <Clicks onPick={onPick} />
      <Circle center={[center.lat, center.lng]} radius={radiusMiles * 1609.344} pathOptions={{ color: '#6366f1', weight: 1, fillOpacity: 0.05 }} />
      {features.map((f) => {
        const colour = f.layer === 'deals' && f.deal_health ? HEALTH[f.deal_health] : LAYER_COLOURS[f.layer] || '#334155';
        return (
          <CircleMarker
            key={`${f.layer}:${f.uuid}`}
            center={[f.lat, f.lng]}
            radius={f.layer === 'deals' || f.layer === 'properties' ? 8 : 6}
            pathOptions={{ color: colour, fillColor: colour, fillOpacity: 0.8, weight: 1 }}
            eventHandlers={{ click: () => onSelect(f) }}
          >
            <Tooltip>{f.title}{f.price ? ` · £${Number(f.price).toLocaleString('en-GB')}` : ''}</Tooltip>
          </CircleMarker>
        );
      })}
    </MapContainer>
  );
}
