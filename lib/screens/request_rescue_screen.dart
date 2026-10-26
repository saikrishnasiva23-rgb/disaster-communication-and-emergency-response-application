import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../config/backend_config.dart';

class RequestRescueScreen extends StatefulWidget {
  const RequestRescueScreen({super.key});

  @override
  State<RequestRescueScreen> createState() =>
      _RequestRescueScreenState();
}

class _RequestRescueScreenState
    extends State<RequestRescueScreen> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController nameController =
      TextEditingController();

  final TextEditingController peopleController =
      TextEditingController();

  final TextEditingController messageController =
      TextEditingController();

  String emergencyType = "Medical Emergency";
  String injured = "No";

  bool isGettingLocation = false;
  bool locationAvailable = false;
  bool isSendingRequest = false;

  double? latitude;
  double? longitude;

  @override
  void dispose() {
    nameController.dispose();
    peopleController.dispose();
    messageController.dispose();
    super.dispose();
  }

  Future<void> getCurrentLocation() async {
    setState(() {
      isGettingLocation = true;
    });

    try {
      bool serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        _showMessage(
          "Please turn ON your phone Location/GPS.",
        );

        setState(() {
          isGettingLocation = false;
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
        _showMessage(
          "Location permission was denied.",
        );

        setState(() {
          isGettingLocation = false;
        });

        return;
      }

      if (permission ==
          LocationPermission.deniedForever) {
        _showMessage(
          "Location permission is permanently denied. "
          "Enable it from phone settings.",
        );

        setState(() {
          isGettingLocation = false;
        });

        return;
      }

      Position position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        latitude = position.latitude;
        longitude = position.longitude;
        locationAvailable = true;
        isGettingLocation = false;
      });

      _showMessage(
        "Current location detected successfully.",
      );
    } catch (e) {
      setState(() {
        isGettingLocation = false;
      });

      _showMessage(
        "Unable to get your current location.",
      );
    }
  }

  Future<void> submitRescueRequest() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (!locationAvailable ||
        latitude == null ||
        longitude == null) {
      _showMessage(
        "Please get your current location first.",
      );
      return;
    }

    setState(() {
      isSendingRequest = true;
    });

    try {
      final response = await http.post(
        Uri.parse(
          BackendConfig.rescueRequestEndpoint,
        ),
        headers: {
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "name": nameController.text.trim(),
          "emergencyType": emergencyType,
          "numberOfPeople":
              int.parse(
            peopleController.text.trim(),
          ),
          "injured": injured,
          "latitude": latitude,
          "longitude": longitude,
          "message":
              messageController.text.trim(),
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data["success"] == true) {
          setState(() {
            isSendingRequest = false;
          });

          _showSuccessDialog();
          return;
        }
      }

      setState(() {
        isSendingRequest = false;
      });

      _showMessage(
        "Failed to send rescue request.",
      );
    } catch (e) {
      setState(() {
        isSendingRequest = false;
      });

      _showMessage(
        "Unable to connect to the rescue server.",
      );
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            "Rescue Request Sent",
          ),
          content: const Text(
            "Your emergency rescue request has been "
            "successfully sent to the rescue system.",
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text("OK"),
            ),
          ],
        );
      },
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration:
            const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Request Rescue"),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.emergency,
                size: 60,
                color: Colors.red,
              ),

              const SizedBox(height: 12),

              const Text(
                "Emergency Rescue Request",
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              const Text(
                "Provide your emergency details so "
                "the rescue team can assist you.",
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey,
                ),
              ),

              const SizedBox(height: 25),

              TextFormField(
                controller: nameController,
                decoration:
                    const InputDecoration(
                  labelText: "Your Name",
                  hintText: "Enter your name",
                  prefixIcon:
                      Icon(Icons.person),
                  border:
                      OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null ||
                      value.trim().isEmpty) {
                    return "Please enter your name";
                  }

                  return null;
                },
              ),

              const SizedBox(height: 18),

              DropdownButtonFormField<String>(
                initialValue: emergencyType,
                decoration:
                    const InputDecoration(
                  labelText: "Emergency Type",
                  prefixIcon:
                      Icon(Icons.warning),
                  border:
                      OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value:
                        "Medical Emergency",
                    child: Text(
                      "Medical Emergency",
                    ),
                  ),
                  DropdownMenuItem(
                    value:
                        "Trapped Person",
                    child: Text(
                      "Trapped Person",
                    ),
                  ),
                  DropdownMenuItem(
                    value: "Injury",
                    child: Text("Injury"),
                  ),
                  DropdownMenuItem(
                    value:
                        "Fire Emergency",
                    child: Text(
                      "Fire Emergency",
                    ),
                  ),
                  DropdownMenuItem(
                    value:
                        "Flood Emergency",
                    child: Text(
                      "Flood Emergency",
                    ),
                  ),
                  DropdownMenuItem(
                    value: "Other",
                    child: Text("Other"),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    emergencyType = value!;
                  });
                },
              ),

              const SizedBox(height: 18),

              TextFormField(
                controller:
                    peopleController,
                keyboardType:
                    TextInputType.number,
                decoration:
                    const InputDecoration(
                  labelText:
                      "Number of People",
                  hintText: "Example: 3",
                  prefixIcon:
                      Icon(Icons.people),
                  border:
                      OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null ||
                      value.trim().isEmpty) {
                    return "Please enter number of people";
                  }

                  final number =
                      int.tryParse(
                    value.trim(),
                  );

                  if (number == null ||
                      number <= 0) {
                    return "Enter a valid number";
                  }

                  return null;
                },
              ),

              const SizedBox(height: 18),

              const Text(
                "Is anyone injured?",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight:
                      FontWeight.w600,
                ),
              ),

              RadioGroup<String>(
                groupValue: injured,
                onChanged: (value) {
                  setState(() {
                    injured = value!;
                  });
                },
                child: Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("Yes"),
                        value: "Yes",
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("No"),
                        value: "No",
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              const Text(
                "Current Location",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight:
                      FontWeight.w600,
                ),
              ),

              const SizedBox(height: 10),

              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.all(15),
                decoration:
                    BoxDecoration(
                  border: Border.all(
                    color: Colors.grey,
                  ),
                  borderRadius:
                      BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          locationAvailable
                              ? Icons.location_on
                              : Icons.location_off,
                          color:
                              locationAvailable
                                  ? Colors.green
                                  : Colors.red,
                        ),
                        const SizedBox(
                          width: 10,
                        ),
                        Expanded(
                          child: Text(
                            locationAvailable
                                ? "Location detected"
                                : "Location not detected",
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (locationAvailable) ...[
                      const SizedBox(
                        height: 8,
                      ),
                      Text(
                        "Latitude: "
                        "${latitude!.toStringAsFixed(6)}",
                      ),
                      Text(
                        "Longitude: "
                        "${longitude!.toStringAsFixed(6)}",
                      ),
                    ],

                    const SizedBox(
                      height: 12,
                    ),

                    SizedBox(
                      width: double.infinity,
                      child:
                          OutlinedButton.icon(
                        onPressed:
                            isGettingLocation
                                ? null
                                : getCurrentLocation,
                        icon: const Icon(
                          Icons.my_location,
                        ),
                        label: Text(
                          isGettingLocation
                              ? "GETTING LOCATION..."
                              : "GET CURRENT LOCATION",
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              TextFormField(
                controller:
                    messageController,
                maxLines: 4,
                decoration:
                    const InputDecoration(
                  labelText:
                      "Additional Message",
                  hintText:
                      "Describe your situation...",
                  prefixIcon:
                      Icon(Icons.message),
                  border:
                      OutlineInputBorder(),
                  alignLabelWithHint:
                      true,
                ),
              ),

              const SizedBox(height: 25),

              SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton.icon(
                  onPressed:
                      isSendingRequest
                          ? null
                          : submitRescueRequest,
                  icon: isSendingRequest
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.send,
                          size: 27,
                        ),
                  label: Text(
                    isSendingRequest
                        ? "SENDING REQUEST..."
                        : "SEND RESCUE REQUEST",
                    style:
                        const TextStyle(
                      fontSize: 18,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  style:
                      ElevatedButton.styleFrom(
                    backgroundColor:
                        Colors.red,
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

              const SizedBox(height: 15),

              const Center(
                child: Text(
                  "Your request will be prioritized "
                  "by the emergency response system.",
                  textAlign:
                      TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}