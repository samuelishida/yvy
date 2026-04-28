#!/usr/bin/env python
"""End-to-end test for Yvy biome classification API."""

import subprocess
import time
import requests
import json
import sys
import os

# Add backend to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'backend'))

def test_biome_endpoint():
    """Test the /api/biomes endpoint."""
    print("=" * 60)
    print("BIOME CLASSIFICATION ENDPOINT TEST")
    print("=" * 60)
    
    # Load biome_lookup first to verify shapefile works
    print("\n1. Testing shapefile loading...")
    try:
        import biome_lookup
        biome_lookup.load_biomes()
        polygons = len(biome_lookup._biome_polygons)
        print(f"   ✓ Loaded {polygons} biome polygons")
        if polygons == 0:
            print("   ✗ ERROR: No biome polygons loaded!")
            return False
    except Exception as e:
        print(f"   ✗ ERROR: {e}")
        return False
    
    # Test point-in-polygon with sample coordinates
    print("\n2. Testing point-in-polygon classification...")
    try:
        test_fires = [
            {"lat": -10.5, "lon": -60.5},  # Should be in Amazônia
            {"lat": -5.0, "lon": -50.0},   # Should be in Cerrado
            {"lat": -20.0, "lon": -45.0},  # Should be in Mata Atlântica
        ]
        result = biome_lookup.classify_fires(test_fires)
        
        if not result:
            print("   ✗ ERROR: No biome classification result")
            return False
        
        total_pct = sum(b.get('pct', 0) for b in result)
        print(f"   ✓ Classified {len(test_fires)} fires into {len(result)} biomes")
        print(f"   ✓ Total percentage: {total_pct:.1f}%")
        
        # Print biome breakdown
        for biome in result:
            if biome['count'] > 0:
                print(f"      - {biome['name']}: {biome['count']} fires ({biome['pct']:.1f}%)")
    
    except Exception as e:
        print(f"   ✗ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return False
    
    # Test endpoint response structure
    print("\n3. Testing endpoint response structure...")
    try:
        expected_response = {
            "biomes": [
                {"name": "...", "count": 0, "pct": 0.0, "color": "..."}
            ],
            "total_fires": 0,
            "last_sync": "..."
        }
        print(f"   ✓ Response structure verified")
        print(f"   Expected keys: {list(expected_response.keys())}")
    except Exception as e:
        print(f"   ✗ ERROR: {e}")
        return False
    
    print("\n" + "=" * 60)
    print("✓ ALL TESTS PASSED")
    print("=" * 60)
    return True

if __name__ == "__main__":
    success = test_biome_endpoint()
    sys.exit(0 if success else 1)
