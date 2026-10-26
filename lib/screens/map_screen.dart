import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../models/sos_packet.dart';
import '../services/ble_central_service.dart';
import '../state/ble_state.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;

  LatLng currentPosition = const LatLng(11.9416, 79.8083);

  StreamSubscription<Position>? positionStream;

  bool isLiveLocation = false;
  bool isLocationSent = false;
  bool isSendingLocation = false;

  @override
  void initState() {
    super.initState();
    startLiveLocation();
  }

  Future<void> startLiveLocation() async {
    // Check GPS
    bool serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      if (mounted) {
        _showMessage("Please turn ON your GPS/Location.");
      }
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
      if (mounted) {
        _showMessage("Location permission denied.");
      }
      return;
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        _showMessage(
          "Location permission is permanently denied. "
          "Enable it from phone settings.",
        );
      }
      return;
    }

    try {
      // Get current location
      Position position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _updateLocation(position);

      // Start continuous location tracking
      positionStream =
          Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        _updateLocation(position);
      });

      if (mounted) {
        setState(() {
          isLiveLocation = true;
        });
      }
    } catch (e) {
      if (mounted) {
        _showMessage(
          "Unable to get your current location.",
        );
      }
    }
  }

  void _updateLocation(Position position) {
    final newPosition = LatLng(
      position.latitude,
      position.longitude,
    );

    if (!mounted) return;

    setState(() {
      currentPosition = newPosition;
    });

    mapController?.animateCamera(
      CameraUpdate.newLatLng(
        currentPosition,
      ),
    );
  }

  /// Sends this device's current position as a real, low-priority BLE
  /// packet -- reusing the same SosPacket wire format, GATT write, and
  /// ack-wait already proven in sos_screen.dart, rather than a second
  /// parallel protocol just for this. Previously this only flipped a
  /// local boolean and showed a SnackBar; nothing was ever transmitted.
  Future<void> _sendLocation() async {
    final bleState = context.read<BleState>();

    if (bleState.connectedDevice == null) {
      _showMessage(
        "No BLE device connected -- connect via Nearby Devices first.",
      );
      return;
    }

    setState(() => isSendingLocation = true);

    final packet = SosPacket(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      senderId: 'affected_person',
      timestamp: DateTime.now(),
      latitude: currentPosition.latitude,
      longitude: currentPosition.longitude,
      message: 'Live location share (not an emergency)',
      emergencyType: 'Location Update',
      priority: 'INFO',
      sequence: 0,
    );

    try {
      await BleCentralService.instance.sendBytes(
        utf8.encode(packet.toWireBytes()),
      );

      var acknowledged = false;
      try {
        await BleCentralService.instance.onAckReceived
            .firstWhere((ack) => ack['id'] == packet.id)
            .timeout(const Duration(seconds: 8));
        acknowledged = true;
      } on TimeoutException {
        acknowledged = false;
      }

      if (!mounted) return;

      setState(() {
        isSendingLocation = false;
        isLocationSent = true;
      });

      _showMessage(
        acknowledged
            ? "Location sent over BLE and acknowledged by the rescue team."
            : "Location sent over BLE (no acknowledgement received yet).",
      );
    } catch (e) {
      if (!mounted) return;

      setState(() => isSendingLocation = false);
      _showMessage("Could not send location: $e");
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    positionStream?.cancel();
    mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Live Location"),
        centerTitle: true,
      ),

      body: Stack(
        children: [

          // GOOGLE MAP
          GoogleMap(
            initialCameraPosition:
                CameraPosition(
              target: currentPosition,
              zoom: 16,
            ),

            myLocationEnabled: true,
            myLocationButtonEnabled: true,

            onMapCreated: (controller) {
              mapController = controller;

              controller.animateCamera(
                CameraUpdate.newLatLngZoom(
                  currentPosition,
                  16,
                ),
              );
            },

            markers: {
              Marker(
                markerId:
                    const MarkerId(
                  "current_location",
                ),
                position: currentPosition,
                infoWindow: const InfoWindow(
                  title: "Your Live Location",
                  snippet: "Affected Person",
                ),
              ),
            },
          ),

          // LOCATION INFORMATION CARD
          Positioned(
            top: 15,
            left: 15,
            right: 15,
            child: Card(
              elevation: 5,
              child: Padding(
                padding:
                    const EdgeInsets.all(14),
                child: Row(
                  children: [

                    Icon(
                      isLiveLocation
                          ? Icons.location_on
                          : Icons.location_off,
                      color: isLiveLocation
                          ? Colors.green
                          : Colors.red,
                      size: 30,
                    ),

                    const SizedBox(width: 12),

                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [

                          Text(
                            isLiveLocation
                                ? "LIVE LOCATION ON"
                                : "LOCATION OFF",
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),

                          const SizedBox(
                            height: 4,
                          ),

                          Text(
                            "Latitude: "
                            "${currentPosition.latitude.toStringAsFixed(6)}\n"
                            "Longitude: "
                            "${currentPosition.longitude.toStringAsFixed(6)}",
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
              ),
            ),
          ),

          // SEND LOCATION BUTTON
          Positioned(
            left: 20,
            right: 20,
            bottom: 25,
            child: SizedBox(
              height: 60,
              child: ElevatedButton.icon(
                onPressed:
                    (isLiveLocation && !isSendingLocation)
                        ? _sendLocation
                        : null,

                icon: isSendingLocation
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        isLocationSent
                            ? Icons.check_circle
                            : Icons.send,
                        size: 28,
                      ),

                label: Text(
                  isSendingLocation
                      ? "SENDING..."
                      : (isLocationSent
                          ? "LOCATION SENT"
                          : "SEND LOCATION"),
                  style:
                      const TextStyle(
                    fontSize: 19,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      isLocationSent
                          ? Colors.green
                          : Colors.blue,
                  foregroundColor:
                      Colors.white,

                  shape:
                      RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(
                      15,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}