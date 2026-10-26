import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

class HospitalsScreen extends StatefulWidget {
  const HospitalsScreen({super.key});

  @override
  State<HospitalsScreen> createState() => _HospitalsScreenState();
}

class _HospitalsScreenState extends State<HospitalsScreen> {
  // Replace this with the SAME Google API key
  // that you used in AndroidManifest.xml.
  static const String googleApiKey = "AIzaSyCtWTCVP8VCqEnUMTmYDkGIydkmLuyNZ5s";

  bool isLoading = true;
  String? errorMessage;

  List<Map<String, dynamic>> hospitals = [];

  @override
  void initState() {
    super.initState();
    findNearbyHospitals();
  }

  Future<void> findNearbyHospitals() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Check GPS
      bool serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        setState(() {
          isLoading = false;
          errorMessage =
              "Please turn ON your phone Location/GPS.";
        });
        return;
      }

      // Check permission
      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission =
            await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        setState(() {
          isLoading = false;
          errorMessage =
              "Location permission was denied.";
        });
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          isLoading = false;
          errorMessage =
              "Location permission is permanently denied. "
              "Enable it from phone settings.";
        });
        return;
      }

      // Get current location
      Position position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Google Places API
      final url = Uri.parse(
        "https://places.googleapis.com/v1/places:searchNearby",
      );

      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": googleApiKey,
          "X-Goog-FieldMask":
              "places.displayName,"
              "places.formattedAddress,"
              "places.location,"
              "places.googleMapsUri",
        },
        body: jsonEncode({
          "includedTypes": ["hospital"],
          "maxResultCount": 10,
          "rankPreference": "DISTANCE",
          "locationRestriction": {
            "circle": {
              "center": {
                "latitude": position.latitude,
                "longitude": position.longitude,
              },
              "radius": 10000.0,
            },
          },
        }),
      );

      if (response.statusCode != 200) {
        setState(() {
          isLoading = false;
          errorMessage =
              "Could not find nearby hospitals.\n"
              "Error: ${response.statusCode}";
        });
        return;
      }

      final data = jsonDecode(response.body);

      final places = data["places"] as List? ?? [];

      List<Map<String, dynamic>> hospitalList = [];

      for (final place in places) {
        final location = place["location"];

        if (location == null) {
          continue;
        }

        final double latitude =
            (location["latitude"] as num).toDouble();

        final double longitude =
            (location["longitude"] as num).toDouble();

        final double distance =
            Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          latitude,
          longitude,
        );

        hospitalList.add({
          "name":
              place["displayName"]?["text"] ??
                  "Unknown Hospital",
          "address":
              place["formattedAddress"] ??
                  "Address unavailable",
          "latitude": latitude,
          "longitude": longitude,
          "distance": distance,
        });
      }

      hospitalList.sort(
        (a, b) => (a["distance"] as double)
            .compareTo(b["distance"] as double),
      );

      setState(() {
        hospitals = hospitalList;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage =
            "Something went wrong while finding hospitals.";
      });
    }
  }

  String formatDistance(double meters) {
    if (meters < 1000) {
      return "${meters.round()} m away";
    }

    return "${(meters / 1000).toStringAsFixed(1)} km away";
  }

  Future<void> openDirections(
    double latitude,
    double longitude,
  ) async {
    final Uri url = Uri.parse(
      "https://www.google.com/maps/dir/?api=1"
      "&destination=$latitude,$longitude",
    );

    if (await canLaunchUrl(url)) {
      await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Nearby Hospitals"),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: findNearbyHospitals,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text(
              "Finding nearby hospitals...",
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 70,
                color: Colors.red,
              ),

              const SizedBox(height: 20),

              Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),

              const SizedBox(height: 20),

              ElevatedButton.icon(
                onPressed: findNearbyHospitals,
                icon: const Icon(Icons.refresh),
                label: const Text("TRY AGAIN"),
              ),
            ],
          ),
        ),
      );
    }

    if (hospitals.isEmpty) {
      return const Center(
        child: Text(
          "No hospitals found nearby.",
          style: TextStyle(fontSize: 17),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: findNearbyHospitals,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: hospitals.length,
        itemBuilder: (context, index) {
          final hospital = hospitals[index];

          return Card(
            margin: const EdgeInsets.only(bottom: 14),
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding:
                            const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(12),
                          color:
                              Colors.red.withValues(alpha: 0.1),
                        ),
                        child: const Icon(
                          Icons.local_hospital,
                          color: Colors.red,
                          size: 32,
                        ),
                      ),

                      const SizedBox(width: 14),

                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              hospital["name"],
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 6),

                            Text(
                              formatDistance(
                                hospital["distance"],
                              ),
                              style: const TextStyle(
                                fontWeight:
                                    FontWeight.w600,
                              ),
                            ),

                            const SizedBox(height: 6),

                            Text(
                              hospital["address"],
                              style: const TextStyle(
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 15),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        openDirections(
                          hospital["latitude"],
                          hospital["longitude"],
                        );
                      },
                      icon: const Icon(Icons.directions),
                      label: const Text("GET DIRECTIONS"),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}