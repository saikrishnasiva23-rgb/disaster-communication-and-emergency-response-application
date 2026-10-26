"""Plain latitude/longitude geometry -- enough for radius queries without
PostGIS. A bounding box pre-filters in SQL (index-friendly), then the exact
haversine distance filters and sorts in Python."""

from __future__ import annotations

import math

EARTH_RADIUS_KM = 6371.0088


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(min(1.0, math.sqrt(a)))


def bounding_box(lat: float, lon: float, radius_km: float) -> tuple[float, float, float, float]:
    """(min_lat, max_lat, min_lon, max_lon) enclosing the radius. Longitude
    is clamped rather than wrapped at the antimeridian (fine for regional
    rescue areas; noted as a limitation)."""
    dlat = math.degrees(radius_km / EARTH_RADIUS_KM)
    cos_lat = max(math.cos(math.radians(lat)), 1e-6)
    dlon = min(180.0, math.degrees(radius_km / (EARTH_RADIUS_KM * cos_lat)))
    return (
        max(-90.0, lat - dlat),
        min(90.0, lat + dlat),
        max(-180.0, lon - dlon),
        min(180.0, lon + dlon),
    )
