package com.example.disaster_communication_app

import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "disaster_communication/mesh"

    /** The affected phone's native BLE peripheral (GATT server + advertiser). */
    private var meshGattServer: MeshGattServer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val mesh = MeshGattServer(applicationContext) { this }
        meshGattServer = mesh
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "disaster_communication/ble_peripheral"
        ).setMethodCallHandler(mesh::onMethodCall)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "disaster_communication/ble_peripheral/events"
        ).setStreamHandler(mesh)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "meshStatus" -> {
                    result.success("Mesh bridge connected")
                }

                // The user-visible device name ("OPPO A5 Pro 5G", "Redmi Note 13").
                // Sent to the Rescue Team inside the GATT HELLO/SOS packets --
                // never placed in the BLE advertisement, which is limited to
                // 31 bytes and failed with ADVERTISE_FAILED_DATA_TOO_LARGE.
                "deviceName" -> {
                    result.success(readableDeviceName())
                }

                // OEM power managers (e.g. ColorOS) freeze the app when the
                // screen turns off, which stops BLE advertising/GATT. Keeping
                // the screen on while the Affected Person screen is open avoids
                // that for the demo.
                "keepScreenOn" -> {
                    val on = call.arguments as? Boolean ?: false
                    runOnUiThread {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(on)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MeshGattServer.PERMISSION_REQUEST) {
            meshGattServer?.onPermissionResult(grantResults)
        }
    }

    @Deprecated("Activity result API is not used by the Flutter embedding here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MeshGattServer.ENABLE_BT_REQUEST) {
            meshGattServer?.onEnableResult()
        }
    }

    override fun onDestroy() {
        // The Dart relay logic dies with this activity's engine; never leave a
        // GATT server running without it.
        meshGattServer?.dispose()
        meshGattServer = null
        super.onDestroy()
    }

    private fun readableDeviceName(): String {
        val candidates = listOf(
            // Settings.Global.DEVICE_NAME (API 25+): the name shown in
            // Settings > About phone. Readable without any permission.
            safeRead { Settings.Global.getString(contentResolver, "device_name") },
            // Some OEMs only populate the Bluetooth name.
            safeRead { Settings.Secure.getString(contentResolver, "bluetooth_name") },
        )

        candidates.firstOrNull { !it.isNullOrBlank() }?.let { return it.trim() }

        val manufacturer = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
        val model = Build.MODEL.orEmpty()
        return if (model.startsWith(manufacturer, ignoreCase = true)) {
            model
        } else {
            "$manufacturer $model".trim()
        }
    }

    private fun safeRead(read: () -> String?): String? =
        try {
            read()
        } catch (e: Exception) {
            null
        }
}
