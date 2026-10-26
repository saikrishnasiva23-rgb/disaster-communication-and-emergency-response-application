package com.example.disaster_communication_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * The affected phone's BLE peripheral for the disaster mesh: a GATT server
 * with ONE service and four characteristics, plus the advertiser.
 *
 * Written natively because flutter_ble_peripheral 3.1.0 cannot serve a relay
 * node: it reports writes/subscriptions without the central's address, can
 * only notify every subscriber at once, drops disconnects whose status is
 * not GATT_SUCCESS, adds a duplicate service when start() is retried, and
 * breaks after Bluetooth is turned off and on.
 *
 * Every BLE call and every piece of state lives on the main looper; GATT
 * callbacks (binder threads) are posted there. Every event carries the
 * central's address, notifications go to ONE device through a single queue
 * that waits for onNotificationSent, and the server is rebuilt
 * automatically when Bluetooth comes back on.
 */
@SuppressLint("MissingPermission")
class MeshGattServer(
    private val context: Context,
    private val activityProvider: () -> Activity?,
) : EventChannel.StreamHandler {

    companion object {
        private const val TAG = "MeshGattServer"
        const val PERMISSION_REQUEST = 4711
        const val ENABLE_BT_REQUEST = 4712

        val SERVICE: UUID = UUID.fromString("bf27730d-860a-4e09-889c-2d8b6a9e0fe7")
        val DATA_NOTIFY: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        val DATA_WRITE: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        val ACK: UUID = UUID.fromString("bf277310-860a-4e09-889c-2d8b6a9e0fe7")
        val CONTROL: UUID = UUID.fromString("bf277311-860a-4e09-889c-2d8b6a9e0fe7")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private const val MANUFACTURER_ID = 0xFFFF
        private const val DEFAULT_MTU = 23
        private const val SERVICE_ADD_TIMEOUT_MS = 5000L
        private const val NOTIFY_TIMEOUT_MS = 2000L
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private val manager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var advertising = false
    private var wantRunning = false
    private var manufacturerData = ByteArray(0)
    private var controlValue = ByteArray(0)

    private val connected = mutableMapOf<String, BluetoothDevice>()
    private val subscriptions = mutableMapOf<String, MutableSet<String>>()
    private val cccdValues = mutableMapOf<String, ByteArray>()
    private val mtus = mutableMapOf<String, Int>()
    private val preparedWrites = mutableMapOf<String, ByteArrayOutputStream>()

    private var pendingServiceAdded: ((Boolean) -> Unit)? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingEnableResult: MethodChannel.Result? = null
    private var startResult: MethodChannel.Result? = null

    private data class Notification(
        val address: String,
        val characteristic: String,
        val value: ByteArray,
        val done: (Boolean) -> Unit,
    )

    private val queue = ArrayDeque<Notification>()
    private var inFlight: Notification? = null
    private val inFlightTimeout = Runnable {
        val n = inFlight ?: return@Runnable
        inFlight = null
        Log.w(TAG, "notification to ${short(n.address)} not confirmed in time")
        n.done(false)
        pump()
    }

    // ------------------------------------------------------------------
    // Adapter on/off
    // ------------------------------------------------------------------

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF -> {
                    emit(mapOf("event" to "adapter", "state" to "off"))
                    teardown(keepWanted = true)
                    emit(mapOf("event" to "advertising", "active" to false, "code" to "BLUETOOTH_OFF"))
                }
                BluetoothAdapter.STATE_TURNING_OFF ->
                    emit(mapOf("event" to "adapter", "state" to "turningOff"))
                BluetoothAdapter.STATE_TURNING_ON ->
                    emit(mapOf("event" to "adapter", "state" to "turningOn"))
                BluetoothAdapter.STATE_ON -> {
                    emit(mapOf("event" to "adapter", "state" to "on"))
                    if (wantRunning) {
                        // The old server and advertiser died with the radio.
                        main.postDelayed({ if (wantRunning) startInternal(null) }, 500)
                    }
                }
            }
        }
    }
    private var receiverRegistered = false

    init {
        try {
            val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(adapterReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(adapterReceiver, filter)
            }
            receiverRegistered = true
        } catch (e: Exception) {
            Log.e(TAG, "could not watch the Bluetooth adapter: $e")
        }
    }

    // ------------------------------------------------------------------
    // Flutter channels
    // ------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isSupported" -> result.success(isSupported())
                "permissionStatus" -> result.success(permissionStatus(afterRequest = false))
                "requestPermissions" -> requestPermissions(result)
                "isBluetoothOn" -> result.success(adapter?.isEnabled == true)
                "enableBluetooth" -> enableBluetooth(result)
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }
                "start" -> {
                    manufacturerData = call.argument<ByteArray>("manufacturerData") ?: ByteArray(0)
                    startInternal(result)
                }
                "stop" -> {
                    teardown(keepWanted = false)
                    result.success(null)
                }
                "notify" -> {
                    val address = call.argument<String>("address") ?: ""
                    val characteristic = call.argument<String>("characteristic") ?: "data"
                    val value = call.argument<ByteArray>("value") ?: ByteArray(0)
                    enqueueNotification(address, characteristic, value) { ok -> result.success(ok) }
                }
                "setControlValue" -> {
                    controlValue = call.argument<ByteArray>("value") ?: ByteArray(0)
                    result.success(null)
                }
                "disconnect" -> {
                    val address = call.argument<String>("address") ?: ""
                    connected[address]?.let { device ->
                        try {
                            server?.cancelConnection(device)
                        } catch (e: SecurityException) {
                            Log.w(TAG, "cancelConnection: $e")
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ------------------------------------------------------------------
    // Support / permissions / adapter
    // ------------------------------------------------------------------

    private fun isSupported(): Boolean {
        val pm = context.packageManager
        if (!pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return false
        val a = adapter ?: return false
        // With the radio off the advertiser cannot be queried; Retry checks again.
        if (!a.isEnabled) return true
        return a.isMultipleAdvertisementSupported && a.bluetoothLeAdvertiser != null
    }

    /** Permissions BLE needs on this Android version. */
    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) {
            listOf(
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
            )
        } else {
            // BLUETOOTH / BLUETOOTH_ADMIN are install-time; scanning (relay
            // mode) on <= 11 also needs location.
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    /** Asked for alongside, never required for BLE: GPS for the SOS, and
     *  the foreground-service notification. */
    private fun optionalPermissions(): List<String> {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) list.add(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) list.add(Manifest.permission.POST_NOTIFICATIONS)
        return list
    }

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun permissionStatus(afterRequest: Boolean): String {
        val missing = requiredPermissions().filterNot(::granted)
        if (missing.isEmpty()) return "granted"
        val activity = activityProvider()
        if (afterRequest && activity != null &&
            missing.none { activity.shouldShowRequestPermissionRationale(it) }
        ) {
            return "permanentlyDenied"
        }
        return "denied"
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val all = (requiredPermissions() + optionalPermissions()).filterNot(::granted)
        if (requiredPermissions().all(::granted) && all.isEmpty()) {
            result.success("granted")
            return
        }
        val activity = activityProvider()
        if (activity == null) {
            result.success(permissionStatus(afterRequest = false))
            return
        }
        pendingPermissionResult?.success(permissionStatus(afterRequest = false))
        pendingPermissionResult = result
        activity.requestPermissions(all.toTypedArray(), PERMISSION_REQUEST)
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(grantResults: IntArray) {
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        // Empty results = the request was cancelled: report the real state.
        result.success(permissionStatus(afterRequest = grantResults.isNotEmpty()))
    }

    private fun enableBluetooth(result: MethodChannel.Result) {
        val a = adapter
        if (a == null) {
            result.success(false)
            return
        }
        if (a.isEnabled) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT >= 31 && !granted(Manifest.permission.BLUETOOTH_CONNECT)) {
            result.success(false)
            return
        }
        val activity = activityProvider()
        if (activity == null) {
            result.success(false)
            return
        }
        pendingEnableResult?.success(a.isEnabled)
        pendingEnableResult = result
        activity.startActivityForResult(
            Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
            ENABLE_BT_REQUEST,
        )
    }

    /** From MainActivity.onActivityResult. */
    fun onEnableResult() {
        val result = pendingEnableResult ?: return
        pendingEnableResult = null
        result.success(adapter?.isEnabled == true)
    }

    private fun openAppSettings() {
        val activity = activityProvider() ?: return
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", context.packageName, null)),
        )
    }

    // ------------------------------------------------------------------
    // Start / stop
    // ------------------------------------------------------------------

    private fun reply(code: String?, message: String?, ok: Boolean) {
        val r = startResult ?: return
        startResult = null
        r.success(mapOf("ok" to ok, "code" to code, "message" to message))
    }

    /** [result] is null when restarting automatically after Bluetooth on. */
    private fun startInternal(result: MethodChannel.Result?) {
        startResult?.success(mapOf("ok" to false, "code" to "SUPERSEDED", "message" to "restarted"))
        startResult = result
        wantRunning = true
        teardown(keepWanted = true)

        val a = adapter
        if (a == null || !a.isEnabled) {
            reply("BLUETOOTH_OFF", "Bluetooth is off", ok = false)
            emit(mapOf("event" to "advertising", "active" to false, "code" to "BLUETOOTH_OFF"))
            return
        }
        if (requiredPermissions().any { !granted(it) }) {
            reply("PERMISSION_DENIED", "Bluetooth permission missing", ok = false)
            emit(mapOf("event" to "advertising", "active" to false, "code" to "PERMISSION_DENIED"))
            return
        }
        val adv = a.bluetoothLeAdvertiser
        if (adv == null || !a.isMultipleAdvertisementSupported) {
            reply("FEATURE_UNSUPPORTED", "This phone cannot advertise over BLE", ok = false)
            return
        }
        advertiser = adv

        try {
            val gatt = manager?.openGattServer(context, gattCallback)
            if (gatt == null) {
                reply("SERVER_FAILED", "Could not open the GATT server", ok = false)
                return
            }
            server = gatt
            val timeout = Runnable {
                if (pendingServiceAdded != null) {
                    pendingServiceAdded = null
                    teardown(keepWanted = true)
                    reply("SERVICE_ADD_FAILED", "The GATT service was not registered in time", ok = false)
                }
            }
            pendingServiceAdded = { ok ->
                main.removeCallbacks(timeout)
                if (ok) {
                    startAdvertising(withScanResponse = true)
                } else {
                    teardown(keepWanted = true)
                    reply("SERVICE_ADD_FAILED", "The GATT service could not be registered", ok = false)
                }
            }
            main.postDelayed(timeout, SERVICE_ADD_TIMEOUT_MS)
            if (!gatt.addService(buildService())) {
                pendingServiceAdded = null
                main.removeCallbacks(timeout)
                teardown(keepWanted = true)
                reply("SERVICE_ADD_FAILED", "addService was refused", ok = false)
            }
        } catch (e: SecurityException) {
            teardown(keepWanted = true)
            reply("PERMISSION_DENIED", e.message, ok = false)
        }
    }

    private fun buildService(): BluetoothGattService {
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        fun cccd() = BluetoothGattDescriptor(
            CCCD,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
        )

        val dataNotify = BluetoothGattCharacteristic(
            DATA_NOTIFY,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        dataNotify.addDescriptor(cccd())

        val dataWrite = BluetoothGattCharacteristic(
            DATA_WRITE,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )

        val ack = BluetoothGattCharacteristic(
            ACK,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE or BluetoothGattCharacteristic.PERMISSION_READ,
        )
        ack.addDescriptor(cccd())

        val control = BluetoothGattCharacteristic(
            CONTROL,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        control.addDescriptor(cccd())

        service.addCharacteristic(dataNotify)
        service.addCharacteristic(dataWrite)
        service.addCharacteristic(ack)
        service.addCharacteristic(control)
        return service
    }

    private fun startAdvertising(withScanResponse: Boolean) {
        val adv = advertiser ?: run {
            reply("FEATURE_UNSUPPORTED", "No advertiser", ok = false)
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // Flags + one 128-bit UUID = 21 of 31 bytes. No device name: it
        // caused ADVERTISE_FAILED_DATA_TOO_LARGE on the OPPO.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE))
            .build()
        val scanResponse = if (withScanResponse && manufacturerData.isNotEmpty()) {
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, manufacturerData)
                .build()
        } else {
            null
        }

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                main.post {
                    advertising = true
                    val code = if (scanResponse == null && manufacturerData.isNotEmpty()) "NO_SCAN_RESPONSE" else null
                    emit(mapOf("event" to "advertising", "active" to true, "code" to code))
                    reply(code, null, ok = true)
                    startForegroundService()
                }
            }

            override fun onStartFailure(errorCode: Int) {
                main.post {
                    if (errorCode == ADVERTISE_FAILED_ALREADY_STARTED) {
                        advertising = true
                        emit(mapOf("event" to "advertising", "active" to true))
                        reply(null, null, ok = true)
                        return@post
                    }
                    if (errorCode == ADVERTISE_FAILED_DATA_TOO_LARGE && scanResponse != null) {
                        Log.w(TAG, "scan response too large -- advertising without it")
                        advertiseCallback = null
                        startAdvertising(withScanResponse = false)
                        return@post
                    }
                    advertising = false
                    val code = when (errorCode) {
                        ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
                        ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
                        ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
                        ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
                        else -> "ADVERTISE_FAILED_$errorCode"
                    }
                    emit(mapOf("event" to "advertising", "active" to false, "code" to code))
                    reply(code, "Advertising failed ($code)", ok = false)
                }
            }
        }
        advertiseCallback = callback
        try {
            if (scanResponse != null) {
                adv.startAdvertising(settings, data, scanResponse, callback)
            } else {
                adv.startAdvertising(settings, data, callback)
            }
        } catch (e: SecurityException) {
            advertiseCallback = null
            reply("PERMISSION_DENIED", e.message, ok = false)
        } catch (e: Exception) {
            advertiseCallback = null
            reply("INTERNAL_ERROR", e.message, ok = false)
        }
    }

    /** Stops advertising, drops every link and closes the server. */
    private fun teardown(keepWanted: Boolean) {
        if (!keepWanted) wantRunning = false
        pendingServiceAdded = null
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (e: Exception) {
            Log.w(TAG, "stopAdvertising: $e")
        }
        advertiseCallback = null
        advertising = false

        val s = server
        server = null
        if (s != null) {
            for (device in connected.values.toList()) {
                try {
                    s.cancelConnection(device)
                } catch (e: Exception) {
                    Log.w(TAG, "cancelConnection: $e")
                }
            }
            try {
                s.clearServices()
                s.close()
            } catch (e: Exception) {
                Log.w(TAG, "close: $e")
            }
        }
        for (address in connected.keys.toList()) {
            emit(mapOf("event" to "connection", "address" to address, "connected" to false, "status" to -1))
        }
        connected.clear()
        subscriptions.clear()
        cccdValues.clear()
        mtus.clear()
        preparedWrites.clear()
        failAllNotifications()
        if (!keepWanted) stopForegroundService()
    }

    fun dispose() {
        teardown(keepWanted = false)
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(adapterReceiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
        pendingPermissionResult?.success(permissionStatus(afterRequest = false))
        pendingPermissionResult = null
        pendingEnableResult?.success(adapter?.isEnabled == true)
        pendingEnableResult = null
    }

    // ------------------------------------------------------------------
    // Foreground service
    // ------------------------------------------------------------------

    private fun startForegroundService() {
        try {
            val intent = Intent(context, MeshForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "foreground service not started: $e")
            emit(mapOf("event" to "warning", "message" to "Background keep-alive unavailable: ${e.javaClass.simpleName}"))
        }
    }

    private fun stopForegroundService() {
        try {
            context.stopService(Intent(context, MeshForegroundService::class.java))
        } catch (_: Exception) {
        }
    }

    // ------------------------------------------------------------------
    // Notifications (one global queue, one in flight)
    // ------------------------------------------------------------------

    private fun characteristicFor(name: String): BluetoothGattCharacteristic? {
        val uuid = when (name) {
            "data" -> DATA_NOTIFY
            "ack" -> ACK
            "control" -> CONTROL
            else -> return null
        }
        return server?.getService(SERVICE)?.getCharacteristic(uuid)
    }

    private fun enqueueNotification(address: String, characteristic: String, value: ByteArray, done: (Boolean) -> Unit) {
        queue.addLast(Notification(address, characteristic, value, done))
        pump()
    }

    private fun pump() {
        if (inFlight != null) return
        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            val device = connected[n.address]
            val ch = characteristicFor(n.characteristic)
            val s = server
            val mtu = mtus[n.address] ?: DEFAULT_MTU
            if (device == null || ch == null || s == null ||
                subscriptions[n.address]?.contains(n.characteristic) != true ||
                n.value.isEmpty() || n.value.size > mtu - 3
            ) {
                n.done(false)
                continue
            }
            val sent = try {
                if (Build.VERSION.SDK_INT >= 33) {
                    s.notifyCharacteristicChanged(device, ch, false, n.value) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    ch.value = n.value
                    @Suppress("DEPRECATION")
                    s.notifyCharacteristicChanged(device, ch, false)
                }
            } catch (e: Exception) {
                Log.w(TAG, "notify: $e")
                false
            }
            if (!sent) {
                n.done(false)
                continue
            }
            inFlight = n
            main.postDelayed(inFlightTimeout, NOTIFY_TIMEOUT_MS)
            return
        }
    }

    private fun completeInFlight(address: String, ok: Boolean) {
        val n = inFlight ?: return
        if (n.address != address) return
        main.removeCallbacks(inFlightTimeout)
        inFlight = null
        n.done(ok)
        pump()
    }

    private fun failAllNotifications() {
        main.removeCallbacks(inFlightTimeout)
        inFlight?.done(false)
        inFlight = null
        while (queue.isNotEmpty()) queue.removeFirst().done(false)
    }

    private fun dropDeviceNotifications(address: String) {
        if (inFlight?.address == address) {
            main.removeCallbacks(inFlightTimeout)
            inFlight?.done(false)
            inFlight = null
        }
        val keep = ArrayDeque<Notification>()
        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            if (n.address == address) n.done(false) else keep.addLast(n)
        }
        queue.addAll(keep)
        pump()
    }

    // ------------------------------------------------------------------
    // GATT server callbacks (binder threads -> main looper)
    // ------------------------------------------------------------------

    private fun nameOf(uuid: UUID): String? = when (uuid) {
        DATA_NOTIFY -> "data"
        DATA_WRITE -> "data"
        ACK -> "ack"
        CONTROL -> "control"
        else -> null
    }

    private fun short(address: String) = if (address.length > 5) address.takeLast(5) else address

    private val gattCallback = object : BluetoothGattServerCallback() {

        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            main.post {
                val cb = pendingServiceAdded ?: return@post
                pendingServiceAdded = null
                cb(status == BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                val address = device.address
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    connected[address] = device
                    emit(mapOf("event" to "connection", "address" to address, "connected" to true, "status" to status))
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    // Whatever the status: a disconnect is a disconnect.
                    val was = connected.remove(address) != null
                    subscriptions.remove(address)
                    cccdValues.keys.removeAll { it.startsWith("$address|") }
                    mtus.remove(address)
                    preparedWrites.keys.removeAll { it.startsWith("$address|") }
                    dropDeviceNotifications(address)
                    if (was) {
                        emit(mapOf("event" to "connection", "address" to address, "connected" to false, "status" to status))
                    }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            main.post {
                mtus[device.address] = mtu
                emit(mapOf("event" to "mtu", "address" to device.address, "mtu" to mtu))
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic,
        ) {
            main.post {
                val value = if (characteristic.uuid == CONTROL) controlValue else ByteArray(0)
                respondRead(device, requestId, offset, value)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            main.post {
                val name = when (characteristic.uuid) {
                    DATA_WRITE -> "data"
                    ACK -> "ack"
                    else -> null
                }
                if (name == null) {
                    if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, null)
                    return@post
                }
                val bytes = value ?: ByteArray(0)
                if (preparedWrite) {
                    val key = "${device.address}|$name"
                    val buffer = preparedWrites.getOrPut(key) { ByteArrayOutputStream() }
                    if (offset != buffer.size()) {
                        if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                        return@post
                    }
                    buffer.write(bytes)
                    if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes)
                    return@post
                }
                if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes)
                emit(mapOf("event" to "write", "address" to device.address, "characteristic" to name, "value" to bytes))
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            main.post {
                val address = device.address
                val keys = preparedWrites.keys.filter { it.startsWith("$address|") }
                for (key in keys) {
                    val buffer = preparedWrites.remove(key) ?: continue
                    if (execute && buffer.size() > 0) {
                        emit(mapOf(
                            "event" to "write",
                            "address" to address,
                            "characteristic" to key.substringAfter('|'),
                            "value" to buffer.toByteArray(),
                        ))
                    }
                }
                respond(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            main.post {
                val name = nameOf(descriptor.characteristic.uuid)
                if (descriptor.uuid != CCCD || name == null || descriptor.characteristic.uuid == DATA_WRITE) {
                    if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, null)
                    return@post
                }
                val bytes = value ?: ByteArray(0)
                val enabled = bytes.isNotEmpty() && (bytes[0].toInt() and 0x03) != 0
                val address = device.address
                cccdValues["$address|$name"] = bytes
                val set = subscriptions.getOrPut(address) { mutableSetOf() }
                val changed = if (enabled) set.add(name) else set.remove(name)
                if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes)
                if (!connected.containsKey(address)) connected[address] = device
                if (changed) {
                    emit(mapOf("event" to "subscription", "address" to address, "characteristic" to name, "enabled" to enabled))
                }
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor,
        ) {
            main.post {
                val name = nameOf(descriptor.characteristic.uuid)
                val value = if (descriptor.uuid == CCCD && name != null) {
                    cccdValues["${device.address}|$name"] ?: byteArrayOf(0, 0)
                } else {
                    ByteArray(0)
                }
                respondRead(device, requestId, offset, value)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post { completeInFlight(device.address, status == BluetoothGatt.GATT_SUCCESS) }
        }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, status: Int, offset: Int, value: ByteArray?) {
        try {
            server?.sendResponse(device, requestId, status, offset, value)
        } catch (e: Exception) {
            Log.w(TAG, "sendResponse: $e")
        }
    }

    private fun respondRead(device: BluetoothDevice, requestId: Int, offset: Int, value: ByteArray) {
        if (offset > value.size) {
            respond(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
        } else {
            respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
        }
    }
}
