import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

class ReliefCampsScreen extends StatefulWidget {
  const ReliefCampsScreen({super.key});

  @override
  State<ReliefCampsScreen> createState() =>
      _ReliefCampsScreenState();
}

class _ReliefCampsScreenState
    extends State<ReliefCampsScreen> {
  bool isLoading = true;
  String? errorMessage;

  List<Map<String, dynamic>> camps = [];

  @override
  void initState() {
    super.initState();
    findNearbyReliefCamps();
  }

  Future<void> findNearbyReliefCamps() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
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

      Position position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final List<Map<String, dynamic>> sampleCamps = [
        {
          "name": "Disaster Relief Camp - Pondicherry",
          "latitude": 11.9416,
          "longitude": 79.8083,
          "address": "Pondicherry, Tamil Nadu",
          "capacity": 150,
          "occupied": 82,
          "food": true,
          "water": true,
          "medical": true,
        },
        {
          "name": "Emergency Shelter Camp",
          "latitude": 11.9350,
          "longitude": 79.8290,
          "address": "White Town, Puducherry",
          "capacity": 100,
          "occupied": 45,
          "food": true,
          "water": true,
          "medical": false,
        },
        {
          "name": "Community Relief Centre",
          "latitude": 11.9500,
          "longitude": 79.8100,
          "address": "Heritage Town, Puducherry",
          "capacity": 200,
          "occupied": 120,
          "food": true,
          "water": true,
          "medical": true,
        },
        {
          "name": "Emergency Relief Shelter",
          "latitude": 11.9250,
          "longitude": 79.8000,
          "address": "Ariyankuppam, Puducherry",
          "capacity": 120,
          "occupied": 60,
          "food": true,
          "water": true,
          "medical": false,
        },
      ];

      List<Map<String, dynamic>> nearbyCamps = [];

      for (final camp in sampleCamps) {
        final double latitude =
            (camp["latitude"] as num).toDouble();

        final double longitude =
            (camp["longitude"] as num).toDouble();

        final double distance =
            Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          latitude,
          longitude,
        );

        nearbyCamps.add({
          ...camp,
          "distance": distance,
        });
      }

      nearbyCamps.sort(
        (a, b) =>
            (a["distance"] as double)
                .compareTo(
          b["distance"] as double,
        ),
      );

      setState(() {
        camps = nearbyCamps;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage =
            "Unable to find nearby relief camps.";
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
        title: const Text("Nearby Relief Camps"),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: findNearbyReliefCamps,
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
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text(
              "Finding nearby relief camps...",
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
            mainAxisAlignment:
                MainAxisAlignment.center,
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
                style:
                    const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed:
                    findNearbyReliefCamps,
                icon:
                    const Icon(Icons.refresh),
                label:
                    const Text("TRY AGAIN"),
              ),
            ],
          ),
        ),
      );
    }

    if (camps.isEmpty) {
      return const Center(
        child: Text(
          "No relief camps found nearby.",
          style: TextStyle(fontSize: 17),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: findNearbyReliefCamps,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: camps.length,
        itemBuilder: (context, index) {
          final camp = camps[index];

          final int capacity =
              (camp["capacity"] as num).toInt();

          final int occupied =
              (camp["occupied"] as num).toInt();

          final int available =
              capacity - occupied;

          final double latitude =
              (camp["latitude"] as num).toDouble();

          final double longitude =
              (camp["longitude"] as num).toDouble();

          final double distance =
              (camp["distance"] as num).toDouble();

          return Card(
            margin:
                const EdgeInsets.only(bottom: 16),
            elevation: 3,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(15),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.all(16),
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
                        decoration:
                            BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(12),
                          color: Colors.green
                              .withValues(alpha: 0.1),
                        ),
                        child: const Icon(
                          Icons.cabin,
                          color: Colors.green,
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
                              camp["name"] as String,
                              style:
                                  const TextStyle(
                                fontSize: 17,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              formatDistance(distance),
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              camp["address"] as String,
                              style:
                                  const TextStyle(
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 15),

                  Row(
                    children: [
                      const Icon(
                        Icons.people,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "$available spaces available",
                        style:
                            const TextStyle(
                          fontWeight:
                              FontWeight.w600,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (camp["food"] == true)
                        _facilityChip(
                          Icons.restaurant,
                          "Food",
                        ),
                      if (camp["water"] == true)
                        _facilityChip(
                          Icons.water_drop,
                          "Water",
                        ),
                      if (camp["medical"] == true)
                        _facilityChip(
                          Icons.medical_services,
                          "Medical",
                        ),
                    ],
                  ),

                  const SizedBox(height: 15),

                  SizedBox(
                    width: double.infinity,
                    child:
                        ElevatedButton.icon(
                      onPressed: () {
                        openDirections(
                          latitude,
                          longitude,
                        );
                      },
                      icon: const Icon(
                        Icons.directions,
                      ),
                      label: const Text(
                        "GET DIRECTIONS",
                      ),
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

  Widget _facilityChip(
    IconData icon,
    String label,
  ) {
    return Chip(
      avatar: Icon(
        icon,
        size: 18,
      ),
      label: Text(label),
    );
  }
}

